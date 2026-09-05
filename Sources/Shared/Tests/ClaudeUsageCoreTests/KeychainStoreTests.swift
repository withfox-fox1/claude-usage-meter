import Testing
import Foundation
@testable import ClaudeUsageCore

struct KeychainStoreTests {
    @Test func saveLoadAndClearRoundTrip() throws {
        // accessGroup: nil — the test binary isn't signed with the shared keychain-access-group
        // entitlement, so it must use the default (unshared) group to run outside Xcode.
        let store = KeychainStore(service: "test.claudeusagemeter.\(UUID().uuidString)", account: "sessionCookie", accessGroup: nil)
        defer { store.clearCookie() }

        #expect(store.loadCookie() == nil)

        try store.saveCookie("sessionKey=abc123; other=xyz")
        #expect(store.loadCookie() == "sessionKey=abc123; other=xyz")

        // Saving again should overwrite (upsert), not throw a duplicate-item error.
        try store.saveCookie("sessionKey=newvalue")
        #expect(store.loadCookie() == "sessionKey=newvalue")

        store.clearCookie()
        #expect(store.loadCookie() == nil)
    }
}
