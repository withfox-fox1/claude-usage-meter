import Foundation

/// Persists the latest `UsageSnapshot` and a bounded history of usage
/// samples, shared between the menu bar app and the Widget via an App
/// Group. If the App Group container isn't available (e.g. entitlements not
/// configured yet, or running in a plain `swift test` environment),
/// transparently falls back to `UserDefaults.standard` so callers still work.
public final class UsageStore {
    public static let appGroupID = "group.dev.local.claudeusagemeter"

    private static let snapshotKey = "ClaudeUsageCore.snapshot"
    private static let historyKey = "ClaudeUsageCore.history"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {
        self.defaults = UserDefaults(suiteName: Self.appGroupID) ?? .standard
    }

    public func save(snapshot: UsageSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: Self.snapshotKey)
    }

    public func loadSnapshot() -> UsageSnapshot? {
        guard let data = defaults.data(forKey: Self.snapshotKey) else { return nil }
        return try? decoder.decode(UsageSnapshot.self, from: data)
    }

    /// Appends `point`, keeps history sorted oldest-first, and trims from the
    /// front once it exceeds `maxPoints`.
    public func appendHistory(_ point: HistoryPoint, maxPoints: Int) {
        var history = loadHistory()
        history.append(point)
        history.sort { $0.timestamp < $1.timestamp }
        if maxPoints >= 0, history.count > maxPoints {
            history.removeFirst(history.count - maxPoints)
        }
        guard let data = try? encoder.encode(history) else { return }
        defaults.set(data, forKey: Self.historyKey)
    }

    public func loadHistory() -> [HistoryPoint] {
        guard let data = defaults.data(forKey: Self.historyKey) else { return [] }
        return (try? decoder.decode([HistoryPoint].self, from: data)) ?? []
    }
}
