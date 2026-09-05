import WidgetKit
import SwiftUI
import ClaudeUsageCore

// MARK: - Entry

struct ClaudeUsageWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
    let history: [HistoryPoint]
}

// MARK: - Provider
//
// 無料のPersonal Team署名ではApp Groupsが使えず、メインアプリとWidgetでUserDefaultsを
// 共有できない(サンドボックスに拒否される)。そのためWidgetは自律的に動く:
// Keychain(keychain-access-groupsで共有)からセッションCookieを読み、自分でclaude.aiの
// APIを叩いてデータを取得する。取得履歴もWidgetプロセス内だけのローカルUserDefaultsに
// 保存する(他プロセスとは共有しない、Widget自身のスパークライン用)。

struct ClaudeUsageTimelineProvider: TimelineProvider {
    private let keychain = KeychainStore()
    private let localHistory = WidgetLocalHistoryStore()

    func placeholder(in context: Context) -> ClaudeUsageWidgetEntry {
        ClaudeUsageWidgetEntry(date: Date(), snapshot: nil, history: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (ClaudeUsageWidgetEntry) -> Void) {
        Task {
            completion(await fetchEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudeUsageWidgetEntry>) -> Void) {
        Task {
            let entry = await fetchEntry()
            // WidgetKitのシステム予算により実際の再描画頻度はこれより間引かれることがある。
            let nextRefresh = Date().addingTimeInterval(30 * 60)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }

    private func fetchEntry() async -> ClaudeUsageWidgetEntry {
        guard let cookie = keychain.loadCookie(), !cookie.isEmpty else {
            return ClaudeUsageWidgetEntry(date: Date(), snapshot: needsLoginSnapshot(), history: localHistory.load())
        }

        let client = ClaudeAPIClient(cookieProvider: { cookie })
        do {
            guard let org = try await client.fetchOrganizations().first else {
                return ClaudeUsageWidgetEntry(date: Date(), snapshot: needsLoginSnapshot(), history: localHistory.load())
            }
            let snapshot = try await client.fetchUsage(orgUUID: org.uuid)
            localHistory.append(
                HistoryPoint(
                    timestamp: snapshot.fetchedAt,
                    sessionPercent: snapshot.session?.percent,
                    weeklyPercent: snapshot.weekly?.percent
                )
            )
            localHistory.saveLastSnapshot(snapshot)
            return ClaudeUsageWidgetEntry(date: Date(), snapshot: snapshot, history: localHistory.load())
        } catch ClaudeAPIError.notLoggedIn {
            return ClaudeUsageWidgetEntry(date: Date(), snapshot: needsLoginSnapshot(), history: localHistory.load())
        } catch ClaudeAPIError.httpError(let code) where code == 401 || code == 403 {
            return ClaudeUsageWidgetEntry(date: Date(), snapshot: needsLoginSnapshot(), history: localHistory.load())
        } catch {
            // ネットワーク一時障害等: 直前のスナップショットをisStale扱いで見せ続ける。
            if let cached = localHistory.loadLastSnapshot() {
                let stale = UsageSnapshot(
                    session: cached.session,
                    weekly: cached.weekly,
                    fetchedAt: cached.fetchedAt,
                    isStale: true,
                    needsLogin: false
                )
                return ClaudeUsageWidgetEntry(date: Date(), snapshot: stale, history: localHistory.load())
            }
            return ClaudeUsageWidgetEntry(date: Date(), snapshot: nil, history: localHistory.load())
        }
    }

    private func needsLoginSnapshot() -> UsageSnapshot {
        UsageSnapshot(session: nil, weekly: nil, fetchedAt: Date(), isStale: false, needsLogin: true)
    }
}

/// Widgetプロセス自身のローカル(他プロセスと非共有)な履歴/直近スナップショットのキャッシュ。
/// `UserDefaults.standard`はプロセスごとにサンドボックスされたコンテナ内で完結するため、
/// App Groups無しでもWidget単体としては問題なく読み書きできる。
final class WidgetLocalHistoryStore {
    private let defaults = UserDefaults.standard
    private let historyKey = "widget.local.history"
    private let lastSnapshotKey = "widget.local.lastSnapshot"
    private let maxPoints = 96

    func load() -> [HistoryPoint] {
        guard let data = defaults.data(forKey: historyKey) else { return [] }
        return (try? JSONDecoder().decode([HistoryPoint].self, from: data)) ?? []
    }

    func append(_ point: HistoryPoint) {
        var points = load()
        points.append(point)
        if points.count > maxPoints {
            points.removeFirst(points.count - maxPoints)
        }
        if let data = try? JSONEncoder().encode(points) {
            defaults.set(data, forKey: historyKey)
        }
    }

    func loadLastSnapshot() -> UsageSnapshot? {
        guard let data = defaults.data(forKey: lastSnapshotKey) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    func saveLastSnapshot(_ snapshot: UsageSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: lastSnapshotKey)
        }
    }
}

// MARK: - Widget定義

struct ClaudeUsageWidget: Widget {
    let kind: String = "ClaudeUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClaudeUsageTimelineProvider()) { entry in
            ClaudeUsageWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Claude使用量メーター")
        .description("claude.ai の現在の利用制限(5時間セッション/週間)を表示します。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - EntryView(サイズごとの出し分け)

struct ClaudeUsageWidgetEntryView: View {
    var entry: ClaudeUsageWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, !snapshot.needsLogin {
                switch family {
                case .systemSmall:
                    SmallWidgetView(snapshot: snapshot)
                case .systemLarge:
                    LargeWidgetView(snapshot: snapshot, history: entry.history)
                default:
                    MediumWidgetView(snapshot: snapshot)
                }
            } else {
                PlaceholderView()
            }
        }
        .containerBackground(for: .widget) {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

// MARK: - データなし / 要ログイン プレースホルダー

struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("メニューバーアプリで\nログインしてください")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Small: よりきびしい方をリング表示

struct SmallWidgetView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        if let dominant = dominantLimit(of: snapshot) {
            let sev = severity(of: dominant.limit)
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0, min(100, dominant.limit.percent))) / 100)
                        .stroke(sev.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 1) {
                        Text("\(dominant.limit.percent)%")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text(dominant.label)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(4)

                Label(sev.label, systemImage: sev.symbolName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(sev.accentColor)
                    .labelStyle(.titleAndIcon)
            }
        } else {
            PlaceholderView()
        }
    }
}

// MARK: - Medium: セッション+週間バー、リセット時刻、最終更新

struct MediumWidgetView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude使用量")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            WidgetUsageRow(
                title: "セッション",
                limit: snapshot.session,
                resetText: snapshot.session.map { UsageFormatting.relativeResetString($0.resetsAt) }
            )
            WidgetUsageRow(
                title: "週間",
                limit: snapshot.weekly,
                resetText: snapshot.weekly.map { UsageFormatting.absoluteResetString($0.resetsAt) }
            )

            Spacer(minLength: 0)

            Text("最終更新: \(UsageFormatting.relativeUpdateString(snapshot.fetchedAt))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Large: Medium + スパークライン

struct LargeWidgetView: View {
    let snapshot: UsageSnapshot
    let history: [HistoryPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MediumWidgetView(snapshot: snapshot)
            Divider()
            SparklineView(history: history)
        }
    }
}

// MARK: - 共通の1行バー(Widget専用の簡易版。MenuBarApp側の UsageProgressBar とは
// ターゲットが分かれているため独立実装)

private struct WidgetUsageRow: View {
    let title: String
    let limit: UsageLimit?
    let resetText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption.weight(.medium))
                Spacer()
                if let limit {
                    let sev = severity(of: limit)
                    Label("\(limit.percent)%", systemImage: sev.symbolName)
                        .font(.caption)
                        .foregroundStyle(sev.accentColor)
                } else {
                    Text("--").font(.caption).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                    if let limit {
                        let fraction = CGFloat(max(0, min(100, limit.percent))) / 100.0
                        RoundedRectangle(cornerRadius: 3)
                            .fill(severity(of: limit).accentColor)
                            .frame(width: max(3, geo.size.width * fraction))
                    }
                }
            }
            .frame(height: 6)
            if let resetText {
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// session/weekly のうち percent が高い(より厳しい)方を返す。
/// AppState.dominantLimit と同じロジックだが、ターゲットが異なるため独立実装している。
func dominantLimit(of snapshot: UsageSnapshot) -> (label: String, limit: UsageLimit)? {
    switch (snapshot.session, snapshot.weekly) {
    case let (s?, w?):
        return s.percent >= w.percent ? ("セッション", s) : ("週間", w)
    case let (s?, nil):
        return ("セッション", s)
    case let (nil, w?):
        return ("週間", w)
    case (nil, nil):
        return nil
    }
}
