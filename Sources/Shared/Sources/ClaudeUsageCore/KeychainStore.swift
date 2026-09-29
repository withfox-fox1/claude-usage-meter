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

    /// `accessGroup` defaults to nil (the app's own keychain items). A shared group
    /// would require the `keychain-access-groups` entitlement, which in turn needs a
    /// provisioning profile — and Personal-Team profiles expire after 7 days, after
    /// which the app can no longer launch. Only pass a group if the signed
    /// entitlements actually contain it.
    public init(
        service: String = "dev.local.claudeusagemeter.cookie",
        account: String = "sessionCookie",
        accessGroup: String? = nil
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
