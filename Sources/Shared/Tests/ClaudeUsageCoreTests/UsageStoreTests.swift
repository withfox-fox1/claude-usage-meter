import Testing
import Foundation
@testable import ClaudeUsageCore

// UsageStore always resolves UserDefaults(suiteName: UsageStore.appGroupID)
// which is not available in a plain `swift test` / SPM sandbox, so this also
// exercises the standard-UserDefaults fallback path. Serialized because all
// tests share the same UserDefaults keys.
@Suite(.serialized)
struct UsageStoreTests {
    init() {
        // UsageStore() resolves UserDefaults(suiteName: UsageStore.appGroupID),
        // which (unlike a real App Group container) succeeds even without
        // entitlements in a plain `swift test` run, so clear that suite
        // specifically rather than assuming the `.standard` fallback is used.
        let suite = UserDefaults(suiteName: UsageStore.appGroupID) ?? .standard
        suite.removeObject(forKey: "ClaudeUsageCore.snapshot")
        suite.removeObject(forKey: "ClaudeUsageCore.history")
        UserDefaults.standard.removeObject(forKey: "ClaudeUsageCore.snapshot")
        UserDefaults.standard.removeObject(forKey: "ClaudeUsageCore.history")
    }

    @Test func saveAndLoadSnapshotRoundTrips() {
        let store = UsageStore()
        let snapshot = UsageSnapshot(
            session: UsageLimit(kind: "session", percent: 42, resetsAt: Date(), isActive: true),
            weekly: nil,
            fetchedAt: Date(),
            isStale: false,
            needsLogin: false
        )

        store.save(snapshot: snapshot)
        let loaded = store.loadSnapshot()

        #expect(loaded == snapshot)
    }

    @Test func loadSnapshotReturnsNilWhenNothingSaved() {
        let store = UsageStore()
        #expect(store.loadSnapshot() == nil)
    }

    @Test func appendHistoryKeepsOldestFirstAndTrims() {
        let store = UsageStore()
        let base = Date()

        for i in 0..<5 {
            let point = HistoryPoint(timestamp: base.addingTimeInterval(TimeInterval(i)), sessionPercent: i, weeklyPercent: nil)
            store.appendHistory(point, maxPoints: 3)
        }

        let history = store.loadHistory()
        #expect(history.count == 3)
        #expect(history.map { $0.sessionPercent } == [2, 3, 4])
        // Oldest first.
        #expect(history[0].timestamp < history[1].timestamp)
        #expect(history[1].timestamp < history[2].timestamp)
    }
}
