import Foundation
import Security

public enum KeychainStoreError: Error {
    case invalidData
    case unhandledError(status: OSStatus)
}

/// Stores the claude.ai session cookie header string in the Keychain, scoped
/// to this device only (no iCloud Keychain sync), so it survives app
/// relaunches without living in UserDefaults/plist.
public final class KeychainStore {
    private let service: String
    private let account: String
    private let accessGroup: String?

    /// `accessGroup` must match a literal entry in both the app's and the widget's
    /// signed `keychain-access-groups` entitlement (e.g. "$(TeamID).dev.local.claudeusagemeter")
    /// for the cookie saved by the app to be readable from the widget extension process.
    /// Free/Personal-Team accounts cannot use App Groups, so this keychain access group
    /// is the only supported way to share the session cookie across the two processes.
    public init(
        service: String = "dev.local.claudeusagemeter.cookie",
        account: String = "sessionCookie",
        accessGroup: String? = "2Y64BNQ29J.dev.local.claudeusagemeter"
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func saveCookie(_ cookieHeader: String) throws {
        guard let data = cookieHeader.data(using: .utf8) else {
            throw KeychainStoreError.invalidData
        }

        // Remove any existing item first so this behaves as an upsert.
        SecItemDelete(baseQuery() as CFDictionary)

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unhandledError(status: status)
        }
    }

    public func loadCookie() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func clearCookie() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
