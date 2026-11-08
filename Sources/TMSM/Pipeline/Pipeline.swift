import Foundation

/// What a run reports: the path on stdout, or all of it with `--json`.
public struct RunResult: Codable, Sendable, Equatable {
  public var output: String
  public var input: String
  public var preset: String
  public var transcriptionModel: String
  public var speakerModel: String?
  public var language: String
  public var speakers: Int
  public var durationSeconds: Double
  public var words: Int

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

  public init(
    home: TMSMHome, catalogue: Catalogue = .shared,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  ) {
    self.home = home
    self.catalogue = catalogue
    self.environment = environment
    self.cwd = cwd
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
    let configured = try Config.load(from: home.configFile).preset
    return try catalogue.preset(named: options.preset ?? configured ?? Catalogue.defaultPreset)
  }

  public func run(_ options: RunOptions, progress: Progress) async throws -> RunResult {
    let input = URL(
      fileURLWithPath: (options.file as NSString).expandingTildeInPath, relativeTo: cwd
    )
    .standardizedFileURL
    let preset = try resolvePreset(options)
    // An unsupported --language fails before any decoding.
    if let language = options.languageCode {
      _ = try PresetRouting.route(preset, language: language, catalogue: catalogue)
    }

    progress.activity("Decoding audio")
    let audio = try AudioDecoder.decode(input, environment: environment)

    // The language (given or detected once) picks the entry and strategy (see PresetRouting).
    let choice = try await PresetRouting.resolve(
      preset, language: options.languageCode, audio: audio, home: home, catalogue: catalogue,
      progress: progress)
    let asrEntry = choice.entry
    let language = choice.language
    guard case .transcription(let makeASR) = asrEntry.factory else {
      throw TMSMError.unknownModel(asrEntry.id)
    }

    let limit = options.speakers.limit
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
    if choice.strategy == .turnwise && limit > 1 {
      // Speakers first, then one decode per speaker turn (see TurnwiseDecoding).
      try await labelSpeakers()
      let pieces = TurnwiseDecoding.plan(
        segments: track.segments, sampleCount: audio.samples.count, maxSpeakers: limit
      ) { Chunking.meanSquare(audio.samples, $0) }
      let decoded = try await TurnwiseDecoding.decode(
        audio, pieces: pieces, engine: makeASR(home), language: language, progress: progress)
      words = decoded.words
      speakers = SpeakerAssignment.renumber(decoded.speakers)
    } else {
      words = try await makeASR(home).transcribe(audio, language: language, progress: progress)
      if limit > 1 && !words.isEmpty { try await labelSpeakers() }
      speakers = SpeakerAssignment.assign(
        words: words, segments: track.segments, activity: track.activity, maxSpeakers: limit)
    }

    if environment["TMSM_DEBUG"] == "1" {
      dumpDebug(input: input, preset: preset.name, words: words, track: track)
    }
    let transcript = Transcript(title: input.lastPathComponent, words: words, speakers: speakers)

    progress.activity("Writing")
    let target = OutputFile.target(
      input: input, output: options.output, desktop: desktop, cwd: cwd)
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let written = try OutputFile.write(transcript.markdown, to: target)

    return RunResult(
      output: written.path, input: input.path, preset: preset.name,
      transcriptionModel: asrEntry.id, speakerModel: speakerEntry?.id,
      language: language ?? "auto", speakers: transcript.speakerCount,
      durationSeconds: (audio.duration * 10).rounded() / 10, words: words.count)
  }

  /// `TMSM_DEBUG=1`: the raw words and segments go to `<home>/cache/debug/<name>.json`.
  private func dumpDebug(input: URL, preset: String, words: [Word], track: SpeakerTrack) {
    struct Dump: Encodable {
      var words: [Word]
      var segments: [SpeakerSegment]
      var activitySpeakers: Int?
      var activity: [Float]?
    }
    let dir = home.cache.appendingPathComponent("debug", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent(
      input.deletingPathExtension().lastPathComponent + "-\(preset).json")
    let dump = Dump(
      words: words, segments: track.segments, activitySpeakers: track.activity?.speakers,
      activity: track.activity?.values)
    try? JSONEncoder().encode(dump).write(to: file)
  }
}
