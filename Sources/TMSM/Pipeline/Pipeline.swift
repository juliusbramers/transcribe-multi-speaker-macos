import Foundation

/// What a run reports: the path on stdout, or all of it with `--json`. With `--output -`
/// there is no file: `output` is nil and `markdown` holds the transcript.
public struct RunResult: Codable, Sendable, Equatable {
  public var output: String?
  public var markdown: String?
  public var input: String
  public var preset: String
  public var transcriptionModel: String
  public var speakerModel: String?
  public var language: String
  public var speakers: Int
  public var durationSeconds: Double
  public var words: Int
  /// Set when a joint model gave up on the file and the preset's next model ran instead.
  public var fallback: String?

  public init(
    output: String?, markdown: String?, input: String, preset: String,
    transcriptionModel: String, speakerModel: String?, language: String, speakers: Int,
    durationSeconds: Double, words: Int, fallback: String? = nil
  ) {
    self.output = output
    self.markdown = markdown
    self.input = input
    self.preset = preset
    self.transcriptionModel = transcriptionModel
    self.speakerModel = speakerModel
    self.language = language
    self.speakers = speakers
    self.durationSeconds = durationSeconds
    self.words = words
    self.fallback = fallback
  }

  public var json: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "{}"
  }
}

/// decode → transcribe → label speakers → assign → write. Each engine loads its model, runs
/// and releases it before the next one starts.
public struct Pipeline: Sendable {
  public var home: TMSMHome
  public var catalogue: Catalogue
  public var environment: [String: String]
  public var cwd: URL
  /// Where `tmsm -` copies stdin: the run's own temp folder (removed with it).
  public var scratch: URL?
  public var stdin: FileHandle

  public init(
    home: TMSMHome, catalogue: Catalogue = .shared,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
    scratch: URL? = nil, stdin: FileHandle = .standardInput
  ) {
    self.home = home
    self.catalogue = catalogue
    self.environment = environment
    self.cwd = cwd
    self.scratch = scratch
    self.stdin = stdin
  }

  /// The Desktop of `$HOME` (so a temp-HOME test stays inside its HOME).
  public var desktop: URL {
    let home =
      environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("Desktop", isDirectory: true)
  }

  /// `--preset`, else the configured one, else `default`.
  public func resolvePreset(_ options: RunOptions) throws -> Preset {
    try Config.load(from: home.configFile).resolvePreset(options.preset, catalogue: catalogue)
  }

  public func run(_ options: RunOptions, progress: Progress) async throws -> RunResult {
    let preset = try resolvePreset(options)
    // An unsupported --language fails before any decoding.
    if let language = options.languageCode {
      _ = try PresetRouting.route(preset, language: language, catalogue: catalogue)
    }
    // A gated model needs a Hugging Face token: HF_TOKEN, else the one `tmsm setup` stored.
    let gated = try preset.entries.map(catalogue.entry).filter(\.gated)
    if let first = gated.first {
      try Credentials.exportToken(for: first.name, environment: environment)
    }

    let input: URL
    if options.readsStdin {
      progress.activity("Reading stdin")
      input = try AudioInput.copy(from: stdin, into: scratch ?? home.temporary)
    } else {
      input =
        URL(
          fileURLWithPath: (options.file as NSString).expandingTildeInPath, relativeTo: cwd
        ).standardizedFileURL
    }
    progress.activity("Decoding audio")
    let audio: Audio
    do {
      audio = try AudioDecoder.decode(input, environment: environment)
    } catch {
      guard options.readsStdin else { throw error }
      try? FileManager.default.removeItem(at: input)
      // The temp copy's path means nothing to the caller.
      if case TMSMError.undecodableAudio(_, let reason) = error {
        throw TMSMError.undecodableAudio(
          "stdin", reason.replacingOccurrences(of: input.path, with: "stdin"))
      }
      if case TMSMError.emptyAudio = error { throw TMSMError.emptyAudio("stdin") }
      throw error
    }
    if options.readsStdin { try? FileManager.default.removeItem(at: input) }
    let title = Pipeline.title(options)

    // The language (given or detected once) picks the entry and strategy (see PresetRouting).
    let choice = try await PresetRouting.resolve(
      preset, language: options.languageCode, audio: audio, home: home, catalogue: catalogue,
      progress: progress)
    var asrEntry = choice.entry
    var strategy = choice.strategy
    let language = choice.language
    // 0 (`--speakers none`, the fast preset's default): no speaker model runs and the
    // transcript has no labels.
    let limit = (options.speakers ?? (preset.labelsByDefault ? .auto : .none)).limit

    // A joint model (words and speakers from one decoder) runs first. If it does not get to
    // the end of the file, the next route of the preset takes over, with a note.
    var joint: JointResult?
    var fallback: String?
    if strategy == .joint, case .joint(let makeJoint) = asrEntry.factory {
      let result = try await makeJoint(home).transcribe(
        audio, language: language, maxSpeakers: limit, progress: progress)
      if result.complete {
        joint = result
      } else {
        let reason = "\(asrEntry.name) did not finish this recording"
        fallback = reason
        LanguageDetection.warn("\(reason); using the next model of the preset", progress: progress)
        let (route, entry) = try PresetRouting.route(
          preset, language: language ?? LanguageDetection.silence, catalogue: catalogue,
          after: choice.route)
        asrEntry = entry
        strategy = route?.strategy ?? preset.strategy
      }
    }
    if joint == nil, case .joint = asrEntry.factory {
      // An unrouted joint entry (`individual`) with nothing to fall back to.
      throw TMSMError.engine(
        "\(asrEntry.name) did not finish this recording and no other model is configured")
    }

    var speakerEntry: CatalogueEntry?
    var track = SpeakerTrack(segments: [])
    func labelSpeakers() async throws {
      let entry = try catalogue.entry(preset.speakers)
      guard case .speakers(let makeLabeller) = entry.factory else {
        throw TMSMError.unknownModel(preset.speakers)
      }
      speakerEntry = entry
      track = try await makeLabeller(home).label(audio, maxSpeakers: limit, progress: progress)
    }

    let words: [Word]
    let speakers: [Int]
    if let joint, let redecode = choice.route?.redecode {
      // The joint model's turns, decoded again by a speech model that spells better.
      let entry = try catalogue.entry(redecode)
      guard case .transcription(let makeASR) = entry.factory else {
        throw TMSMError.unknownModel(redecode)
      }
      asrEntry = entry
      track = SpeakerTrack(segments: joint.segments)
      let pieces = TurnwiseDecoding.plan(
        segments: track.segments, sampleCount: audio.samples.count,
        maxSpeakers: max(1, limit)
      ) { Chunking.meanSquare(audio.samples, $0) }
      let decoded = try await TurnwiseDecoding.decode(
        audio, pieces: pieces, engine: makeASR(home), language: language, progress: progress)
      words = decoded.words
      speakers = SpeakerAssignment.renumber(decoded.speakers)
    } else if let joint {
      words = joint.words
      speakers = SpeakerAssignment.renumber(SpeakerAssignment.cap(joint.speakers, limit))
    } else if strategy == .turnwise {
      guard case .transcription(let makeASR) = asrEntry.factory else {
        throw TMSMError.unknownModel(asrEntry.id)
      }
      // Speakers first, then one decode per speaker turn (see TurnwiseDecoding). With one
      // speaker there is nothing to label: the whole file is one speaker-0 turn, split at
      // quiet points like any long turn, and decoded the same way.
      if limit > 1 {
        try await labelSpeakers()
      } else {
        track = SpeakerTrack(segments: [SpeakerSegment(0, 0, audio.duration)])
      }
      let pieces = TurnwiseDecoding.plan(
        segments: track.segments, sampleCount: audio.samples.count, maxSpeakers: limit
      ) { Chunking.meanSquare(audio.samples, $0) }
      let decoded = try await TurnwiseDecoding.decode(
        audio, pieces: pieces, engine: makeASR(home), language: language, progress: progress)
      words = decoded.words
      speakers = SpeakerAssignment.renumber(decoded.speakers)
    } else {
      guard case .transcription(let makeASR) = asrEntry.factory else {
        throw TMSMError.unknownModel(asrEntry.id)
      }
      words = try await makeASR(home).transcribe(audio, language: language, progress: progress)
      if limit > 1 && !words.isEmpty { try await labelSpeakers() }
      speakers = SpeakerAssignment.assign(
        words: words, segments: SpeakerSegments.clean(track.segments), activity: track.activity,
        maxSpeakers: limit)
    }

    if environment["TMSM_DEBUG"] == "1" {
      dumpDebug(name: title, preset: preset.name, words: words, track: track)
    }
    let transcript = Transcript(
      title: title, words: words, speakers: speakers, labelled: limit > 0)

    var written: URL?
    if !options.writesStdout {
      progress.activity("Writing")
      let target = OutputFile.target(
        input: Pipeline.nameSource(options, input: input), output: options.output,
        desktop: desktop, cwd: cwd)
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      written = try OutputFile.write(transcript.markdown, to: target)
    }

    return RunResult(
      output: written?.path, markdown: options.writesStdout ? transcript.markdown : nil,
      input: options.readsStdin ? AudioInput.stdinName : input.path, preset: preset.name,
      transcriptionModel: asrEntry.id,
      speakerModel: speakerEntry?.id ?? (joint != nil && limit > 0 ? choice.entry.id : nil),
      language: language ?? "auto", speakers: transcript.speakerCount,
      durationSeconds: (audio.duration * 10).rounded() / 10, words: words.count,
      fallback: fallback)
  }

  /// The heading: `--name`, else the input's file name, else `stdin`.
  public static func title(_ options: RunOptions) -> String {
    if let name = options.name, !name.isEmpty { return name }
    if options.readsStdin { return "stdin" }
    return URL(fileURLWithPath: options.file).lastPathComponent
  }

  /// The URL whose name the output file takes: `<name>.md` with `--name` or for stdin.
  public static func nameSource(_ options: RunOptions, input: URL) -> URL {
    guard options.name?.isEmpty == false || options.readsStdin else { return input }
    let safe = title(options).replacingOccurrences(of: "/", with: "-")
    return URL(fileURLWithPath: "/").appendingPathComponent(safe + ".audio")
  }

  /// `TMSM_DEBUG=1`: the raw words and segments go to `<home>/cache/debug/<name>.json`.
  private func dumpDebug(name: String, preset: String, words: [Word], track: SpeakerTrack) {
    struct Dump: Encodable {
      var words: [Word]
      var segments: [SpeakerSegment]
      var activitySpeakers: Int?
      var activity: [Float]?
    }
    let dir = home.cache.appendingPathComponent("debug", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stem = URL(fileURLWithPath: "/" + name.replacingOccurrences(of: "/", with: "-"))
      .deletingPathExtension().lastPathComponent
    let file = dir.appendingPathComponent(stem + "-\(preset).json")
    let dump = Dump(
      words: words, segments: track.segments, activitySpeakers: track.activity?.speakers,
      activity: track.activity?.values)
    try? JSONEncoder().encode(dump).write(to: file)
  }
}
