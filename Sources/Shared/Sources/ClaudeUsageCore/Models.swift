import Foundation

/// A single usage limit window as reported by claude.ai (either the current
/// 5-hour session limit, or the current 7-day weekly limit).
public struct UsageLimit: Codable, Equatable, Sendable {
    /// "session" or "weekly_all" (the raw `kind` value from the claude.ai API).
    public let kind: String
    /// 0-100.
    public let percent: Int
    public let resetsAt: Date
    public let isActive: Bool

    public init(kind: String, percent: Int, resetsAt: Date, isActive: Bool) {
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
        self.isActive = isActive
    }
}

public enum UsageSeverity: String, Codable, Sendable {
    case normal
    case warning
    case critical
}

/// 50%未満: normal, 50〜80%未満: warning, 80%以上: critical
public func severity(forPercent percent: Int) -> UsageSeverity {
    switch percent {
    case ..<50:
        return .normal
    case 50..<80:
        return .warning
    default:
        return .critical
    }
}

/// A point-in-time picture of both usage limits, as displayed by the UI.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let session: UsageLimit?
    public let weekly: UsageLimit?
    public let fetchedAt: Date
    /// true = network fetch failed and this is a reused previous value.
    public let isStale: Bool
    /// true = the API reported the user is not authenticated (e.g. HTTP 401).
    public let needsLogin: Bool

    public init(session: UsageLimit?, weekly: UsageLimit?, fetchedAt: Date, isStale: Bool, needsLogin: Bool) {
        self.session = session
        self.weekly = weekly
        self.fetchedAt = fetchedAt
        self.isStale = isStale
        self.needsLogin = needsLogin
    }
}

/// A single sample used to render usage-over-time history/sparkline charts.
public struct HistoryPoint: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let sessionPercent: Int?
    public let weeklyPercent: Int?

    public init(timestamp: Date, sessionPercent: Int?, weeklyPercent: Int?) {
        self.timestamp = timestamp
        self.sessionPercent = sessionPercent
        self.weeklyPercent = weeklyPercent
    }
}
