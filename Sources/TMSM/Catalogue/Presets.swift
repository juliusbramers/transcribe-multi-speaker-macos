import Foundation

/// A named pair of catalogue entries: one for speech to text, one for speakers.
public struct Preset: Sendable, Equatable {
  public var name: String
  /// Catalogue id of the transcription entry. For a routed preset this is the router's entry,
  /// whose choices per language are in `routing`.
  public var transcription: String
  public var speakers: String
  /// One line for the wizard and `--help`, without the RAM figure (that is `ramGB`).
  public var summary: String
  /// Measured peak memory of a whole run, in GB; nil until measured.
  public var ramGB: ClosedRange<Double>?
  /// Per-language choice of transcription entry, for presets that route.
  public var routing: LanguageRouting?

  public init(
    name: String, transcription: String, speakers: String, summary: String,
    ramGB: ClosedRange<Double>?, routing: LanguageRouting? = nil
  ) {
    self.name = name
    self.transcription = transcription
    self.speakers = speakers
    self.summary = summary
    self.ramGB = ramGB
    self.routing = routing
  }
}

/// Which transcription entry runs for which language. Languages are ISO 639-1 codes.
public struct LanguageRouting: Sendable, Equatable {
  public var byLanguage: [String: String]
  /// The entry for every language not in `byLanguage`, and for detecting the language.
  public var fallback: String

  public init(byLanguage: [String: String], fallback: String) {
    self.byLanguage = byLanguage
    self.fallback = fallback
  }

  public func entry(for language: String) -> String {
    byLanguage[language] ?? fallback
  }

  /// Every entry this routing may run, fallback first.
  public var entries: [String] {
    [fallback] + Array(Set(byLanguage.values).subtracting([fallback])).sorted()
  }
}

/// The preset table: the one place that maps presets to models. Remapping a preset is an edit
/// here and nowhere else.
public enum Presets {
  /// The router entry that runs `extreme.routing`.
  public static let extremeRouter = "extreme-routed"

  public static let fast = Preset(
    name: "fast", transcription: "parakeet-v3", speakers: "nemotron3-c128-split-w8a8",
    summary: "Parakeet v3 + Nemotron-3 c128-split-w8a8, 25 languages",
    ramGB: 0.4...0.4)

  public static let `default` = Preset(
    name: "default", transcription: "parakeet-ultra", speakers: "nemotron3-offline",
    summary: "Parakeet Ultra + Nemotron-3 offline, 25 languages",
    ramGB: 0.4...0.4)

  public static let accurate = Preset(
    name: "accurate", transcription: "qwen3-asr-1.7b-8bit", speakers: "nemotron3-offline",
    summary: "Qwen3-ASR 1.7B 8-bit + Qwen3 aligner + Nemotron-3 offline, 30 languages",
    ramGB: nil)

  /// Routing is a stub until the bake-off settles it: everything goes to the fallback.
  public static let extreme = Preset(
    name: "extreme", transcription: extremeRouter, speakers: "nemotron3-offline",
    summary: "Best measured model per language + Qwen3 aligner + Nemotron-3 offline",
    ramGB: nil,
    routing: LanguageRouting(byLanguage: [:], fallback: "qwen3-asr-1.7b-8bit"))

  public static let all: [Preset] = [fast, `default`, accurate, extreme]
}
