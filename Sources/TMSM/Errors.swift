import Foundation

public enum TMSMError: Error, LocalizedError, Equatable {
  case inputNotFound(String)
  case undecodableAudio(String, String)
  case emptyAudio(String)
  case unknownPreset(String)
  case unknownModel(String)
  case unsupportedLanguage(String, String)
  case invalidConfig(String, String)
  case outputExists(String)
  case outputFailed(String, String)
  case engine(String)

  public var errorDescription: String? {
    switch self {
    case .inputNotFound(let path):
      return "No such file: \(path)"
    case .undecodableAudio(let path, let reason):
      return "Can't read audio from \(path): \(reason)"
    case .emptyAudio(let path):
      return "No audio in \(path)"
    case .unknownPreset(let name):
      return
        "Unknown preset '\(name)'. Choose one of: \(Catalogue.shared.presetNames.joined(separator: ", "))"
    case .unknownModel(let id):
      return "Model '\(id)' is not in the catalogue"
    case .unsupportedLanguage(let code, let model):
      return "\(model) does not support language '\(code)'"
    case .invalidConfig(let path, let reason):
      return "Can't read \(path): \(reason)"
    case .outputExists(let path):
      return "\(path) already exists and is never overwritten"
    case .outputFailed(let path, let reason):
      return "Can't write \(path): \(reason)"
    case .engine(let message):
      return message
    }
  }
}
