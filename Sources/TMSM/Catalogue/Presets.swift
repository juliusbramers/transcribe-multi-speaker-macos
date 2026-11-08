import Foundation

/// How speech and speakers are combined.
public enum Strategy: String, Sendable, Equatable {
  /// Transcribe the whole file in windows, label speakers, give each word the speaker whose
  /// segments overlap it most.
  case windows
  /// Label speakers first, then transcribe each speaker turn on its own; every word takes its
  /// turn's speaker.
  case turnwise
  /// One model hears the whole file and writes words and speaker labels together. No separate
  /// speaker model runs.
  case joint
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
  /// What `--speakers` means when it is not given: `auto` (label speakers) or `none` (plain
  /// paragraphs, no speaker model runs).
  public var labelsByDefault: Bool = true
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

extension Preset {
  /// The languages `tmsm setup` prepares a preset for: a run in these, without `--language`,
  /// needs nothing else. Other languages may fetch more models on first use.
  public static let setupLanguages = ["en", "de"]

  /// What `tmsm setup` downloads: the routes for `setupLanguages`, the first language detector
  /// and the speaker model. Fallback routes and later detectors download when a run needs them.
  public func setupEntries(in catalogue: Catalogue) -> [String] {
    var ids: [String] = []
    func add(_ id: String) { if !ids.contains(id) { ids.append(id) } }
    if routing == nil {
      add(transcription)
    } else {
      for language in Preset.setupLanguages {
        if let (route, entry) = try? PresetRouting.route(
          self, language: language, catalogue: catalogue)
        {
          add(entry.id)
          if let redecode = route?.redecode { add(redecode) }
        }
      }
      if let detector = routing?.detectors.first { add(detector) }
    }
    add(speakers)
    return ids
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
    /// For a `joint` route: a speech-to-text entry that decodes the joint model's speaker
    /// turns again (turn-wise), keeping the turns and speakers but taking the words from a
    /// model that spells better. nil: the joint model's words are used.
    public var redecode: String?

    public init(
      _ entry: String, _ strategy: Strategy, only: [String]? = nil, note: String? = nil,
      redecode: String? = nil
    ) {
      self.entry = entry
      self.strategy = strategy
      self.only = only
      self.note = note
      self.redecode = redecode
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
    let ids = routes.flatMap { [$0.entry] + ($0.redecode.map { [$0] } ?? []) } + detectors
    for id in ids where !seen.contains(id) { seen.append(id) }
    return seen
  }
}

/// The preset table: the one place that maps presets to models. Remapping a preset is an edit
/// here and nowhere else.
///
/// Measured on a 38-minute German two-speaker recording and the held-out AMI excerpts (see
/// docs/models.md): Parakeet Ultra writes the most accurate words of every model tried;
/// MOSS-Transcribe-Diarize, hearing the whole file at once, cuts the best speaker turns. So the
/// top preset takes its turns from MOSS and its words from Ultra.
public enum Presets {
  static let ultra = "parakeet-ultra"
  static let qwen3 = "qwen3-asr-1.7b-8bit"
  static let moss = "moss-transcribe-diarize-0.9b-8bit"
  static let speakers = "nemotron3-offline"

  static let qwen3Note =
    "this language needs Qwen3-ASR 1.7B instead of Parakeet Ultra: slower, and about 6 GB of RAM"

  /// Parakeet Ultra on the whole file in windows; no speaker model unless `--speakers` asks.
  public static let fast: Preset = {
    var p = Preset(
      name: "fast", speakers: speakers,
      summary: "Parakeet Ultra alone, plain paragraphs (--speakers auto adds Nemotron-3)",
      ramGB: 0.4...0.4,
      routing: LanguageRouting(
        routes: [.init(ultra, .windows), .init(qwen3, .turnwise, note: qwen3Note)],
        detectors: [ultra, qwen3]))
    p.labelsByDefault = false
    return p
  }()

  /// Ultra in windows, Nemotron-3 segments cleaned, words assigned by overlap.
  public static let `default` = Preset(
    name: "default", speakers: speakers,
    summary: "Parakeet Ultra + Nemotron-3 offline, speakers by overlap",
    ramGB: 0.4...0.4,
    routing: LanguageRouting(
      routes: [.init(ultra, .windows), .init(qwen3, .turnwise, note: qwen3Note)],
      detectors: [ultra, qwen3]))

  /// Nemotron-3 first, then each speaker turn decoded on its own with a little context: Ultra
  /// for its languages, Qwen3-ASR for the rest.
  public static let accurate = Preset(
    name: "accurate", speakers: speakers,
    summary: "Nemotron-3 turns, each decoded by Parakeet Ultra (Qwen3-ASR for other languages)",
    ramGB: 0.4...6.2,
    routing: LanguageRouting(
      routes: [
        .init(ultra, .turnwise), .init(qwen3, .turnwise, note: qwen3Note),
      ],
      detectors: [ultra, qwen3]))

  /// MOSS-Transcribe-Diarize hears the whole file and cuts the speaker turns; Ultra decodes
  /// each turn. Languages Ultra lacks keep MOSS's own words. If MOSS cannot finish a file
  /// (over 90 minutes, or its decoder stops early), the accurate routes take over.
  public static let extreme = Preset(
    name: "extreme", speakers: speakers,
    summary:
      "MOSS-Transcribe-Diarize cuts the speaker turns over the whole file, Parakeet Ultra decodes them",
    ramGB: 0.4...9.6,
    routing: LanguageRouting(
      routes: [
        .init(moss, .joint, only: FluidAudioEngine.parakeetLanguages, redecode: ultra),
        .init(moss, .joint),
        .init(ultra, .turnwise), .init(qwen3, .turnwise, note: qwen3Note),
      ],
      detectors: [ultra, qwen3]))

  public static let all: [Preset] = [fast, `default`, accurate, extreme]
}
