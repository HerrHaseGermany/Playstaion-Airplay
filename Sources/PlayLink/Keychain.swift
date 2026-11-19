import Foundation
import Security

enum TokenStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "de.raudzis.playlink",
        kSecAttrAccount as String: "discord-bot-token"
    ]

    static func load() -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }

    static func delete() { SecItemDelete(query as CFDictionary) }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw PlayLinkError.message("Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
        }
    }
}
