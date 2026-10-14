import Foundation
import Security
import GitDeskCore

enum HostingCredentials {
  static func token(for key: String) throws -> String {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dev.gitdesk.hosting", kSecAttrAccount as String: key,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return "" }
    guard status == errSecSuccess, let data = result as? Data else {
      throw GitFailure("Could not read the account token from Keychain (\(status)).")
    }
    return String(decoding: data, as: UTF8.self)
  }
  static func save(_ token: String, for key: String) throws {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dev.gitdesk.hosting", kSecAttrAccount as String: key]
    let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
    let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw GitFailure("Could not update the Keychain account (\(update)).") }
    var insertion = query.merging(attributes) { _, new in new }
    insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(insertion as CFDictionary, nil)
    guard status == errSecSuccess else { throw GitFailure("Could not save the account in Keychain (\(status)).") }
  }
  static func remove(_ key: String) throws {
    let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dev.gitdesk.hosting", kSecAttrAccount as String: key] as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw GitFailure("Could not remove the account (\(status)).") }
  }
}
