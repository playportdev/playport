// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

struct ActivatorFailure: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

enum PairingStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.playport.jit.pairing",
        kSecAttrAccount as String: "remote-pairing"
    ]

    static func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return data
    }

    static func save(_ data: Data) throws {
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }

    private static func failure(_ status: OSStatus) -> ActivatorFailure {
        ActivatorFailure(detail: "Не удалось открыть связку ключей (\(status)). Разблокируйте iPhone и попробуйте снова.")
    }

    static func withFile<T>(_ data: Data, _ body: (URL) throws -> T) throws -> T {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-\(UUID().uuidString).plist")
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: file) }
        return try body(file)
    }
}
