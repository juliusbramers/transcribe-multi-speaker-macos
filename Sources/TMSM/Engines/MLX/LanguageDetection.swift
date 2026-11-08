import Foundation
import NaturalLanguage

/// Language codes and names, and detection from transcribed text.
enum LanguageDetection {
  /// English name of an ISO 639-1 code ("de" → "German"), the form Qwen3 models expect.
  static func name(_ code: String) -> String? {
    Locale(identifier: "en_US").localizedString(forLanguageCode: code)
  }

  /// Speech used to detect a file's language, in seconds (at most three windows).
  static let sampleSeconds = 60.0
  /// The language used when detection is unsure.
  static let fallback = "en"
  /// Below this probability the dominant language counts as unsure.
  static let minimumConfidence = 0.5

  /// The dominant language of `text` among `candidates` (ISO 639-1), with its probability;
  /// nil when the text is empty or no candidate reaches `minimumConfidence`.
  static func detect(_ text: String, among candidates: [String]) -> (code: String, p: Double)? {
    let recognizer = NLLanguageRecognizer()
    recognizer.languageConstraints = candidates.map { NLLanguage(rawValue: $0) }
    recognizer.processString(text)
    var best: (code: String, p: Double)?
    for (language, p) in recognizer.languageHypotheses(withMaximum: candidates.count) {
      let code = language.rawValue.split(separator: "-").first.map(String.init) ?? ""
      guard candidates.contains(code), p > (best?.p ?? 0) else { continue }
      best = (code, p)
    }
    guard let best, best.p >= minimumConfidence else { return nil }
    return best
  }

  /// The dominant language of `text`, or nil when unsure.
  static func language(of text: String, among candidates: [String] = MLXEngine.qwen3Languages)
    -> String?
  {
    detect(text, among: candidates)?.code
  }

  /// A one-line note on stderr, unless the run is quiet.
  static func warn(_ message: String, progress: Progress) {
    guard progress.mode != .quiet else { return }
    FileHandle.standardError.write(Data("\rtmsm: \(message)\u{1B}[K\n".utf8))
  }
}
