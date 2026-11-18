import Foundation
import Security

public enum KeychainStore {
    private static func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrAccount as String: key,
         kSecAttrService as String: "pi-mobile"]
    }

    public static func read(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func write(_ value: String, key: String) -> Bool {
        let data = Data(value.utf8)
        var query = baseQuery(key)
        query[kSecValueData as String] = data
        let added = SecItemAdd(query as CFDictionary, nil)
        if added == errSecSuccess { return true }
        guard added == errSecDuplicateItem else { return false }
        return SecItemUpdate(baseQuery(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess
    }

    @discardableResult
    public static func delete(_ key: String) -> Bool {
        SecItemDelete(baseQuery(key) as CFDictionary) == errSecSuccess
    }
}
