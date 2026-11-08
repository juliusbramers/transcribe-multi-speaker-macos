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
    let asrEntry = try catalogue.entry(preset.transcription)
    let language = options.languageCode
    if let language, !asrEntry.languages.contains(language) {
      throw TMSMError.unsupportedLanguage(language, asrEntry.name)
    }
    guard case .transcription(let makeASR) = asrEntry.factory else {
      throw TMSMError.unknownModel(preset.transcription)
    }

    progress.activity("Decoding audio")
    let audio = try AudioDecoder.decode(input, environment: environment)

    let words = try await makeASR(home).transcribe(audio, language: language, progress: progress)

    let limit = options.speakers.limit
    var speakerEntry: CatalogueEntry?
    var track = SpeakerTrack(segments: [])
    if limit > 1 && !words.isEmpty {
      let entry = try catalogue.entry(preset.speakers)
      guard case .speakers(let makeLabeller) = entry.factory else {
        throw TMSMError.unknownModel(preset.speakers)
      }
      speakerEntry = entry
      track = try await makeLabeller(home).label(audio, maxSpeakers: limit, progress: progress)
    }

    if environment["TMSM_DEBUG"] == "1" {
      dumpDebug(input: input, preset: preset.name, words: words, track: track)
    }
    let speakers = SpeakerAssignment.assign(
      words: words, segments: track.segments, activity: track.activity, maxSpeakers: limit)
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
