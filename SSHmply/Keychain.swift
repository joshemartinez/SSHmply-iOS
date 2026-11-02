import Foundation
import Security

/// Secrets storage: the iOS Keychain when it is available, with a protected-file fallback.
/// Unsigned / re-signed installs (LiveContainer, some sideloaders) have no keychain entitlement,
/// so every write is verified and falls back to a file that only this app can read.
enum Keychain {
    private static let service = "com.sshmply.app"
    private static let lock = NSLock()

    // MARK: Public API

    static func set(_ value: String, for account: String) {
        if value.isEmpty {
            remove(account)
            return
        }
        if keychainSet(value, account), keychainGet(account) == value {
            fileRemove(account)
        } else {
            fileSet(value, account)
        }
    }

    static func get(_ account: String) -> String {
        let v = keychainGet(account)
        if !v.isEmpty { return v }
        return fileGet(account)
    }

    static func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        fileRemove(account)
    }

    // MARK: Keychain

    @discardableResult
    private static func keychainSet(_ value: String, _ account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = query
            add.merge(attrs) { _, new in new }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    private static func keychainGet(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8)
        else { return "" }
        return str
    }

    // MARK: File fallback

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SSHmply", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("secrets.json")
    }

    private static func fileLoad() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    private static func fileSave(_ dict: [String: String]) {
        if dict.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static func fileSet(_ value: String, _ account: String) {
        lock.lock(); defer { lock.unlock() }
        var d = fileLoad()
        d[account] = value
        fileSave(d)
    }

    private static func fileGet(_ account: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return fileLoad()[account] ?? ""
    }

    private static func fileRemove(_ account: String) {
        lock.lock(); defer { lock.unlock() }
        var d = fileLoad()
        if d.removeValue(forKey: account) != nil { fileSave(d) }
    }
}
