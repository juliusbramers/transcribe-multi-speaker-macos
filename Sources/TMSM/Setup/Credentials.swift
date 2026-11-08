import Darwin
import Foundation
import Security

/// The Hugging Face token for gated models: `HF_TOKEN` first (scripts, agents), else the
/// Keychain item that `tmsm setup` stores (service "tmsm", account "huggingface"). It never
/// goes to disk or the config.
///
/// The login Keychain may show a dialog (locked keychain, or an unsigned tmsm that changed
/// since it stored the item), and macOS offers no way to suppress that for such items. So an
/// unattended process (no terminal on stdin and stderr) never touches the Keychain: it needs
/// HF_TOKEN.
public enum Credentials {
  public static let service = "tmsm"
  public static let account = "huggingface"

  /// A person is at a terminal and could answer a Keychain dialog.
  public static var attended: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDERR_FILENO) == 1 }

  /// `HF_TOKEN` when set, else (only when attended) the stored token.
  public static func token(environment: [String: String], attended: Bool) throws -> String? {
    if let token = environment["HF_TOKEN"], !token.isEmpty { return token }
    return attended ? try stored() : nil
  }

  /// Makes the token visible to the engines' Hugging Face clients, which read `HF_TOKEN`.
  public static func exportToken(
    for model: String, environment: [String: String], attended: Bool = Credentials.attended
  ) throws {
    guard let token = try token(environment: environment, attended: attended) else {
      throw SetupError.tokenMissing(model)
    }
    setenv("HF_TOKEN", token, 1)
  }

  /// The stored token; nil if there is none. Other Keychain failures throw.
  public static func stored() throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw SetupError.keychainLocked(status)
    }
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

  /// Removes tmsm's own item (service "tmsm", account "huggingface"), and nothing another
  /// program may have stored under the same service. Returns how many went.
  @discardableResult
  public static func removeAll() throws -> Int {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
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
