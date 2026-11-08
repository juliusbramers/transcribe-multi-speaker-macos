import Darwin
import Foundation
import Security

/// The Hugging Face token for gated models: `HF_TOKEN` first (scripts, agents), else the
/// Keychain item that `tmsm setup` stores (service "tmsm"). It never goes to disk or the config.
public enum Credentials {
  public static let service = "tmsm"
  public static let account = "huggingface"

  /// `HF_TOKEN` when set, else the stored token.
  public static func token(environment: [String: String]) -> String? {
    if let token = environment["HF_TOKEN"], !token.isEmpty { return token }
    return stored()
  }

  /// Makes the token visible to the engines' Hugging Face clients, which read `HF_TOKEN`.
  public static func exportToken(for model: String, environment: [String: String]) throws {
    if let token = environment["HF_TOKEN"], !token.isEmpty { return }
    guard let token = stored() else { throw SetupError.tokenMissing(model) }
    setenv("HF_TOKEN", token, 1)
  }

  public static func stored() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public static func store(_ token: String) throws {
    let match: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let data = Data(token.utf8)
    var status = SecItemUpdate(
      match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var add = match
      add[kSecValueData as String] = data
      add[kSecAttrLabel as String] = "tmsm Hugging Face token"
      status = SecItemAdd(add as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw SetupError.keychain(status) }
  }

  /// Removes every item of service "tmsm". Returns how many went.
  @discardableResult
  public static func removeAll() throws -> Int {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    var removed = 0
    while true {
      let status = SecItemDelete(query as CFDictionary)
      if status == errSecItemNotFound { return removed }
      guard status == errSecSuccess else { throw SetupError.keychain(status) }
      removed += 1
    }
  }

  /// A Hugging Face access token: `hf_` and at least 8 more letters or digits.
  public static func looksValid(_ token: String) -> Bool {
    let body = token.dropFirst(3)
    return token.hasPrefix("hf_") && body.count >= 8
      && body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
  }
}
