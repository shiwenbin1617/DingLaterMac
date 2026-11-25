import CryptoKit
import Foundation
import Security

enum Secrets {
    static func loadKey(allowCreation: Bool) throws -> SymmetricKey {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.dinglater.mac.inbox",
            kSecAttrAccount as String: "inbox-key-v1"
        ]
        var request = item
        request[kSecReturnData as String] = true
        var found: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &found)
        if status == errSecSuccess, let data = found as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound, allowCreation else {
            throw InboxError("无法取得回复箱的钥匙串密钥（\(status)）。请检查钥匙串后重试。")
        }
        let key = SymmetricKey(size: .bits256)
        var new = item
        new[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        new[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let add = SecItemAdd(new as CFDictionary, nil)
        if add == errSecDuplicateItem { return try loadKey(allowCreation: false) }
        guard add == errSecSuccess else { throw InboxError("无法写入钥匙串（\(add)）。") }
        return key
    }
}

