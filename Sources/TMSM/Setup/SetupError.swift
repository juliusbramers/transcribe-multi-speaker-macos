import Foundation
import Security

public enum SetupError: Error, LocalizedError, Equatable {
  case noIndividualModels
  case wrongKind(String, CatalogueEntry.Kind)
  case tokenMissing(String)
  case keychain(Int32)
  case needsTerminal(String)
  case notAProgramFolder(String)
  case foreignFiles(String, [String])
  case notTMSMHome(String)
  case notOwned(String)
  case keychainLocked(Int32)
  case download(String)
  case checksum(String)
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .noIndividualModels:
      return "The individual preset has no models yet. Run `tmsm setup` to pick them."
    case .wrongKind(let id, let kind):
      return "'\(id)' is not a \(kind == .transcription ? "speech-to-text" : "speaker") model"
    case .tokenMissing(let model):
      return
        "\(model) is gated on Hugging Face and needs a token: set HF_TOKEN (runs without a terminal read only that), or store one with `tmsm setup` in a terminal."
    case .keychain(let status):
      let text = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
      return "Keychain: \(text)"
    case .needsTerminal(let hint):
      return "This needs a terminal to ask. \(hint)"
    case .notAProgramFolder(let path):
      return "\(path) is not a tmsm program folder (no tmsm executable in it)"
    case .foreignFiles(let path, let names):
      return
        "\(path) holds files tmsm did not create (\(names.joined(separator: ", "))), so it was left alone"
    case .notTMSMHome(let path):
      return
        "\(path) was not created by tmsm (TMSM_HOME points to an existing folder), so it was left alone; delete its models/ and cache/ yourself"
    case .notOwned(let path):
      return
        "\(path) has no tmsm manifest, so tmsm can't tell it is its own; it was left alone. Remove it yourself if it is."
    case .keychainLocked(let status):
      let text = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
      return
        "The Keychain did not hand over the Hugging Face token without asking (\(text)). Unattended runs never show a Keychain dialog: set HF_TOKEN, or run `tmsm setup` in a terminal."
    case .download(let message):
      return "Download failed: \(message)"
    case .checksum(let file):
      return "\(file) does not match SHA256SUMS; nothing was installed"
    case .cancelled:
      return "Cancelled; nothing was changed"
    }
  }
}
