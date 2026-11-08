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
  /// The language passed on when nothing was heard: the transcript is empty either way.
  static let silence = "en"
  /// Below this probability the dominant language counts as unsure.
  static let minimumConfidence = 0.5

  /// ISO 639-1 code of an `NLLanguage` ("zh-Hans" → "zh", "nb" → "no").
  static func code(_ language: NLLanguage) -> String {
    let code = language.rawValue.split(separator: "-").first.map(String.init) ?? ""
    return code == "nb" ? "no" : code
  }

  /// The dominant language of `text` among every language the recogniser knows, with its
  /// probability; nil when the text is empty or the top hypothesis is below
  /// `minimumConfidence`. Not limited to the languages a preset covers: an unsupported language
  /// must come out as itself, not as the nearest supported one.
  static func identify(_ text: String) -> (code: String, p: Double)? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    var best: (code: String, p: Double)?
    for (language, p) in recognizer.languageHypotheses(withMaximum: 5) {
      let code = code(language)
      // Higher probability wins; equal ones go to the lower code, whatever the order.
      if let b = best, p < b.p || (p == b.p && code >= b.code) { continue }
      best = (code, p)
    }
    guard let best, best.p >= minimumConfidence else { return nil }
    return best
  }

  /// The dominant language of `text`, or nil when unsure.
  static func language(of text: String) -> String? { identify(text)?.code }

  /// A one-line note on stderr, unless the run is quiet.
  static func warn(_ message: String, progress: Progress) {
    guard progress.mode != .quiet else { return }
    FileHandle.standardError.write(Data("\rtmsm: \(message)\u{1B}[K\n".utf8))
  }
}
