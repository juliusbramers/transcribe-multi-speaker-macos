import Foundation

/// How speech and speakers are combined.
public enum Strategy: String, Sendable, Equatable {
  /// Transcribe the whole file in windows, label speakers, give each word the speaker whose
  /// segments overlap it most.
  case windows
  /// Label speakers first, then transcribe each speaker turn on its own; every word takes its
  /// turn's speaker.
  case turnwise
}

/// A named combination of models: one speaker entry, and the transcription entry (with its
/// strategy) chosen by the file's language.
public struct Preset: Sendable, Equatable {
  public var name: String
  /// The main transcription entry (the first route's), for display.
  public var transcription: String
  public var speakers: String
  /// One line for the wizard and `--help`, without the RAM figure (that is `ramGB`).
  public var summary: String
  /// Measured peak memory footprint of a whole run (short clip to 30 min, with and without
  /// language detection), in GB; nil until measured.
  public var ramGB: ClosedRange<Double>?
  /// Which transcription entry and strategy run for which language. nil: always
  /// `transcription` with `strategy`.
  public var routing: LanguageRouting?
  /// The strategy when there is no routing.
  public var strategy: Strategy

  public init(
    name: String, transcription: String, speakers: String, summary: String,
    ramGB: ClosedRange<Double>?, routing: LanguageRouting? = nil, strategy: Strategy = .windows
  ) {
    self.name = name
    self.transcription = transcription
    self.speakers = speakers
    self.summary = summary
    self.ramGB = ramGB
    self.routing = routing
    self.strategy = strategy
  }

  /// Every catalogue entry a run of this preset may use (routes, detectors, speakers): what
  /// setup downloads for it.
  public var entries: [String] {
    var all = routing?.entries ?? [transcription]
    if !all.contains(transcription) { all.insert(transcription, at: 0) }
    if !all.contains(speakers) { all.append(speakers) }
    return all
  }

  /// A routed preset: `transcription` and `strategy` are the first route's.
  public init(
    name: String, speakers: String, summary: String, ramGB: ClosedRange<Double>?,
    routing: LanguageRouting
  ) {
    self.init(
      name: name, transcription: routing.routes.first?.entry ?? "", speakers: speakers,
      summary: summary, ramGB: ramGB, routing: routing,
      strategy: routing.routes.first?.strategy ?? .windows)
  }
}

/// Routes, in order of preference: the first whose languages include the file's language runs.
public struct LanguageRouting: Sendable, Equatable {
  public struct Route: Sendable, Equatable {
    public var entry: String
    public var strategy: Strategy
    /// Only these languages (ISO 639-1); nil: every language the entry supports.
    public var only: [String]?
    /// Shown on stderr (unless --quiet) when this route runs.
    public var note: String?

    public init(
      _ entry: String, _ strategy: Strategy, only: [String]? = nil, note: String? = nil
    ) {
      self.entry = entry
      self.strategy = strategy
      self.only = only
      self.note = note
    }
  }

  public var routes: [Route]
  /// Entries that detect the language when none is given, tried in order until one is sure.
  public var detectors: [String]

  public init(routes: [Route], detectors: [String]) {
    self.routes = routes
    self.detectors = detectors
  }

  /// Every entry this routing may run, in route order, without repeats.
  public var entries: [String] {
    var seen: [String] = []
    for id in routes.map(\.entry) + detectors where !seen.contains(id) { seen.append(id) }
    return seen
  }
}

/// The preset table: the one place that maps presets to models. Remapping a preset is an edit
/// here and nowhere else.
public enum Presets {
  static let ultra = "parakeet-ultra"
  static let qwen3 = "qwen3-asr-1.7b-8bit"
  static let speakers = "nemotron3-offline"

  static let qwen3Note =
    "this language needs Qwen3-ASR 1.7B instead of Parakeet Ultra: slower, and about 6 GB of RAM"

  public static let fast = Preset(
    name: "fast", speakers: speakers,
    summary: "Parakeet Ultra + Nemotron-3 offline, speakers by overlap",
    ramGB: 0.4...0.4,
    routing: LanguageRouting(
      routes: [.init(ultra, .windows), .init(qwen3, .turnwise, note: qwen3Note)],
      detectors: [ultra, qwen3]))

  public static let `default` = Preset(
    name: "default", speakers: speakers,
    summary: "Parakeet Ultra + Nemotron-3 offline, decoded speaker turn by speaker turn",
    ramGB: 0.4...0.4,
    routing: LanguageRouting(
      routes: [.init(ultra, .turnwise), .init(qwen3, .turnwise, note: qwen3Note)],
      detectors: [ultra, qwen3]))

  /// English and German go to Parakeet Ultra (best measured), other Qwen3-ASR languages to
  /// Qwen3-ASR 1.7B 8-bit, the rest of Ultra's to Ultra.
  static let accurateRouting = LanguageRouting(
    routes: [
      .init(ultra, .turnwise, only: ["de", "en"]), .init(qwen3, .turnwise),
      .init(ultra, .turnwise),
    ],
    detectors: [qwen3])

  public static let accurate = Preset(
    name: "accurate", speakers: speakers,
    summary: "Parakeet Ultra for en/de, Qwen3-ASR 1.7B 8-bit for other languages, turn by turn",
    ramGB: 0.4...6.2, routing: accurateRouting)

  public static let extreme = Preset(
    name: "extreme", speakers: speakers,
    summary:
      "Currently identical to accurate: no larger pipeline measured better with v0.1.0 engines",
    ramGB: 0.4...6.2, routing: accurateRouting)

  public static let all: [Preset] = [fast, `default`, accurate, extreme]
}
