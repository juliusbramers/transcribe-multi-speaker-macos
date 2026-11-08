import Foundation
import NaturalLanguage

/// Language codes and names, and detection from transcribed text.
enum LanguageDetection {
  /// English name of an ISO 639-1 code ("de" → "German"), the form Qwen3 models expect.
  static func name(_ code: String) -> String? {
    Locale(identifier: "en_US").localizedString(forLanguageCode: code)
  }

  /// The dominant language of `text` as an ISO 639-1 code, limited to `candidates`; nil when the
  /// text is too short or unclear to tell.
  static func language(of text: String, among candidates: [String] = MLXEngine.qwen3Languages)
    -> String?
  {
    let recognizer = NLLanguageRecognizer()
    recognizer.languageConstraints = candidates.map { NLLanguage(rawValue: $0) }
    recognizer.processString(text)
    guard let top = recognizer.dominantLanguage else { return nil }
    let code = top.rawValue.split(separator: "-").first.map(String.init) ?? top.rawValue
    return candidates.contains(code) ? code : nil
  }
}

/// Runs the transcription entry the preset table names for the file's language.
///
/// With `--language`, that language picks the entry. Without, the routing's fallback entry
/// transcribes the first minute, the language is read from that text, and the chosen entry then
/// transcribes the whole file with the language set.
struct RoutedTranscriber: TranscriptionEngine {
  /// Audio used to detect the language, in seconds.
  static let detectionSeconds = 60.0

  let routing: LanguageRouting
  let home: TMSMHome

  func transcribe(_ audio: Audio, language: String?, progress: Progress) async throws -> [Word] {
    let catalogue = Catalogue.shared
    var detected = language
    var fallbackWords: [Word]?
    if detected == nil {
      let fallback = try engine(routing.fallback, catalogue)
      let prefix = Self.detectionPrefix(audio)
      let words = try await fallback.transcribe(prefix, language: nil, progress: progress)
      detected = LanguageDetection.language(
        of: words.map(\.text).joined(separator: " "),
        among: try catalogue.entry(routing.fallback).languages)
      // The prefix was the whole file: no need to transcribe it twice with the same model.
      if prefix.samples.count == audio.samples.count { fallbackWords = words }
    }
    let chosen = detected.map(routing.entry(for:)) ?? routing.fallback
    if chosen == routing.fallback, let fallbackWords { return fallbackWords }
    return try await engine(chosen, catalogue).transcribe(
      audio, language: detected, progress: progress)
  }

  /// The first `detectionSeconds`, cut at a quiet point like any window.
  static func detectionPrefix(_ audio: Audio) -> Audio {
    let limit = Int(detectionSeconds) * Audio.sampleRate
    let span = limit + Int(Chunking.searchSeconds) * Audio.sampleRate
    guard audio.samples.count > span else { return audio }
    let windows = Chunking.plan(sampleCount: span, targetSeconds: detectionSeconds) {
      Chunking.meanSquare(audio.samples, $0)
    }
    let end = windows.first?.upperBound ?? limit
    return Audio(samples: Array(audio.samples[0..<end]))
  }

  private func engine(_ id: String, _ catalogue: Catalogue) throws -> any TranscriptionEngine {
    guard id != Presets.extremeRouter,
      case .transcription(let make) = try catalogue.entry(id).factory
    else { throw TMSMError.unknownModel(id) }
    return make(home)
  }
}
