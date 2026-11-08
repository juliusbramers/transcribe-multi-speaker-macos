import Foundation

/// Picks the transcription entry and strategy for one run from the preset's routing and the
/// file's language. `--language` wins; otherwise the language is detected once per file and
/// then used for every window or turn.
public enum PresetRouting {
  public struct Choice: Sendable {
    public var entry: CatalogueEntry
    public var strategy: Strategy
    /// The language every decode gets; nil only for unrouted presets left on automatic.
    public var language: String?
  }

  /// Speech used to detect the language, in seconds (at most `detectionWindows` windows).
  static let detectionSeconds = 60.0
  static let detectionWindows = 3

  /// Every language some route of the preset supports, sorted.
  public static func languages(_ preset: Preset, catalogue: Catalogue) -> [String] {
    guard let routing = preset.routing else {
      return (try? catalogue.entry(preset.transcription).languages) ?? []
    }
    var all = Set<String>()
    for route in routing.routes {
      all.formUnion(route.only ?? (try? catalogue.entry(route.entry).languages) ?? [])
    }
    return all.sorted()
  }

  /// The route for a known language; an error naming `--language` and the supported languages
  /// when no route has it (never a silent substitute).
  public static func route(_ preset: Preset, language: String, catalogue: Catalogue) throws
    -> (LanguageRouting.Route?, CatalogueEntry)
  {
    guard let routing = preset.routing else {
      let entry = try catalogue.entry(preset.transcription)
      guard entry.languages.contains(language) else {
        throw TMSMError.unsupportedLanguage(language, entry.name)
      }
      return (nil, entry)
    }
    for route in routing.routes {
      let entry = try catalogue.entry(route.entry)
      if (route.only ?? entry.languages).contains(language), entry.languages.contains(language) {
        return (route, entry)
      }
    }
    throw TMSMError.engine(
      "Preset \(preset.name) has no model for language '\(language)'. Pass --language with one of: "
        + languages(preset, catalogue: catalogue).joined(separator: ", "))
  }

  /// The entry, strategy and language for this file.
  public static func resolve(
    _ preset: Preset, language: String?, audio: Audio, home: TMSMHome, catalogue: Catalogue,
    progress: Progress
  ) async throws -> Choice {
    let candidates = languages(preset, catalogue: catalogue)
    guard let routing = preset.routing else {
      let entry = try catalogue.entry(preset.transcription)
      var code = language
      if let language {
        _ = try route(preset, language: language, catalogue: catalogue)
      } else if !entry.languages.isEmpty {
        code = try await detect(
          audio, detectors: [entry.id], candidates: candidates, home: home,
          catalogue: catalogue, progress: progress)
      }
      return Choice(entry: entry, strategy: preset.strategy, language: code)
    }
    var code = language ?? ""
    if language == nil {
      code = try await detect(
        audio, detectors: routing.detectors, candidates: candidates, home: home,
        catalogue: catalogue, progress: progress)
    }
    let (route, entry) = try self.route(preset, language: code, catalogue: catalogue)
    if let note = route?.note { LanguageDetection.warn(note, progress: progress) }
    return Choice(entry: entry, strategy: route?.strategy ?? preset.strategy, language: code)
  }

  /// Each detector transcribes up to a minute of speech, unconditioned, and the language is
  /// read from its text among every language there is, not only the preset's.
  ///
  /// - A detector that is sure, of a language it can transcribe itself, decides: that language
  ///   if the preset covers it, otherwise an error naming it.
  /// - Unsure, or a language the detector can't write (its text is unreliable then): the next
  ///   detector tries (fast/default: Parakeet Ultra, then Qwen3-ASR).
  /// - After the last detector: its sure answer decides as above; unsure is an error asking for
  ///   `--language`. Never a silent fallback to some language.
  /// - No speech, or nothing heard: `LanguageDetection.silence`; the transcript is empty.
  static func detect(
    _ audio: Audio, detectors: [String], candidates: [String], home: TMSMHome,
    catalogue: Catalogue, progress: Progress
  ) async throws -> String {
    guard let sample = speechSample(audio) else { return LanguageDetection.silence }
    var heard = false
    var last: (code: String, p: Double)?
    for id in detectors {
      let entry = try catalogue.entry(id)
      guard case .transcription(let make) = entry.factory else { continue }
      progress.activity("Detecting the language")
      let words = try await make(home).transcribe(
        segments: [sample], language: nil, progress: progress
      ).flatMap { $0 }
      heard = heard || !words.isEmpty
      last = LanguageDetection.identify(words.map(\.text).joined(separator: " "))
      guard let found = last, entry.languages.contains(found.code) else { continue }
      guard candidates.contains(found.code) else {
        throw unsupported(found.code, candidates: candidates)
      }
      return found.code
    }
    guard heard else { return LanguageDetection.silence }
    guard let found = last else {
      throw TMSMError.engine(
        "Can't tell which language this recording is in. Pass --language with one of: "
          + candidates.joined(separator: ", "))
    }
    guard candidates.contains(found.code) else {
      throw unsupported(found.code, candidates: candidates)
    }
    return found.code
  }

  static func unsupported(_ code: String, candidates: [String]) -> TMSMError {
    let name = LanguageDetection.name(code).map { "\($0) (\(code))" } ?? "'\(code)'"
    return TMSMError.engine(
      "This recording sounds like \(name), which this preset doesn't cover. If that's wrong, "
        + "pass --language with one of: \(candidates.joined(separator: ", "))")
  }

  /// Up to `detectionWindows` windows that hold speech, about `detectionSeconds` in total,
  /// padded to at least one second; nil when the file has no speech.
  static func speechSample(_ audio: Audio) -> Audio? {
    var samples: [Float] = []
    var taken = 0
    for range in Chunking.plan(audio.samples) where !Chunking.isSilent(audio.samples, range) {
      samples += audio.samples[range]
      taken += 1
      if taken >= detectionWindows
        || Double(samples.count) >= detectionSeconds * Double(Audio.sampleRate)
      {
        break
      }
    }
    guard !samples.isEmpty else { return nil }
    if samples.count < Audio.sampleRate {
      samples += [Float](repeating: 0, count: Audio.sampleRate - samples.count)
    }
    return Audio(samples: samples)
  }
}
