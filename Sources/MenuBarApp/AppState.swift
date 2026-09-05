import Foundation
import Combine
import WidgetKit
import ClaudeUsageCore

/// メニューバーアプリ全体の状態を保持し、Core層(ClaudeUsageCore)とUIをつなぐオーケストレーター。
///
/// 責務:
/// - 起動時に Keychain の Cookie を確認し、組織一覧 -> 使用量取得までの初期フローを実行する
/// - PollingScheduler による5分おきの定期更新
/// - 通知ON/OFF・選択中組織の永続化(App Group UserDefaults)
/// - ログイン切れ検知時の状態遷移(loggedIn -> loggedOut)
@MainActor
final class AppState: ObservableObject {
    private enum Keys {
        static let selectedOrganizationUUID = "selectedOrganizationUUID"
        static let notificationsEnabled = "notificationsEnabled"
    }

    @Published private(set) var loginState: LoginState = .checking
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var history: [HistoryPoint] = []
    @Published private(set) var organizations: [Organization] = []
    @Published private(set) var selectedOrganizationID: String?
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }
    @Published private(set) var isRefreshing: Bool = false
    @Published var lastErrorMessage: String?

    private let store: UsageStore
    private let keychain: KeychainStore
    private let scheduler: PollingScheduler
    private let notificationManager: NotificationManager
    private let cookieRefreshService: CookieRefreshService
    private let defaults: UserDefaults
    private var apiClient: ClaudeAPIClient?

    init(
        store: UsageStore = UsageStore(),
        keychain: KeychainStore = KeychainStore(),
        scheduler: PollingScheduler = PollingScheduler(interval: 300),
        notificationManager: NotificationManager = NotificationManager(),
        cookieRefreshService: CookieRefreshService? = nil
    ) {
        self.store = store
        self.keychain = keychain
        self.scheduler = scheduler
        self.notificationManager = notificationManager
        self.defaults = UserDefaults(suiteName: UsageStore.appGroupID) ?? .standard
        self.notificationsEnabled = (self.defaults.object(forKey: Keys.notificationsEnabled) as? Bool) ?? true
        self.selectedOrganizationID = self.defaults.string(forKey: Keys.selectedOrganizationUUID)
        // 直近のキャッシュ値を即座に表示できるよう、ネットワーク疎通前にロードしておく。
        self.snapshot = store.loadSnapshot()
        self.history = store.loadHistory()
        self.cookieRefreshService = cookieRefreshService ?? CookieRefreshService(keychain: keychain)

        self.cookieRefreshService.onLoginExpired = { [weak self] in
            Task { @MainActor in
                self?.loginState = .loggedOut
            }
        }
        self.cookieRefreshService.onCookieRefreshed = { [weak self] in
            Task { @MainActor in
                await self?.refreshCurrentOrganization()
            }
        }
    }

    /// アプリ起動時に一度だけ呼ぶ。
    func start() async {
        cookieRefreshService.start()
        await bootstrap()
    }

    /// Cookie の有無を確認し、あれば組織一覧 -> 使用量取得 -> 定期更新開始まで行う。
    /// 無ければ `.loggedOut` にして呼び出し側でログイン画面を出せるようにする。
    func bootstrap() async {
        guard let cookie = keychain.loadCookie(), !cookie.isEmpty else {
            // Widgetが古い数字ではなく「要ログイン」を表示できるよう、キャッシュがあれば
            // needsLogin: true に付け替えて保存し直す。
            if snapshot != nil {
                markNeedsLoginSnapshot()
            }
            loginState = .loggedOut
            return
        }

        let client = ClaudeAPIClient(cookieProvider: { [weak self] in self?.keychain.loadCookie() })
        self.apiClient = client

        do {
            let orgs = try await client.fetchOrganizations().map(Organization.init)
            self.organizations = orgs

            guard let firstOrg = orgs.first else {
                loginState = .loggedOut
                lastErrorMessage = "利用可能な組織が見つかりませんでした"
                return
            }

            let targetID: String
            if let selected = selectedOrganizationID, orgs.contains(where: { $0.uuid == selected }) {
                targetID = selected
            } else {
                targetID = firstOrg.uuid
                persistSelectedOrganization(targetID)
            }

            loginState = .loggedIn
            lastErrorMessage = nil
            await refresh(orgUUID: targetID)

            scheduler.start { [weak self] in
                await self?.refreshCurrentOrganization()
            }
        } catch {
            switch error {
            case ClaudeAPIError.notLoggedIn:
                loginState = .loggedOut
            case ClaudeAPIError.httpError(let code) where code == 401 || code == 403:
                loginState = .loggedOut
            default:
                // 401/403以外(タイムアウト等の一時障害)では「確認しています…」のまま固まらせず、
                // メッセージ+再試行ボタンを出せる状態に落とす。
                loginState = .error("組織情報の取得に失敗しました: \(error)")
            }
        }
    }

    /// ユーザーが組織切り替えメニューで別組織を選んだときに呼ぶ。
    func selectOrganization(_ organization: Organization) {
        persistSelectedOrganization(organization.uuid)
        Task { await refresh(orgUUID: organization.uuid) }
    }

    /// 「今すぐ更新」ボタンから呼ぶ。
    func refreshNow() {
        scheduler.refreshNow()
        Task { await refreshCurrentOrganization() }
    }

    func refreshCurrentOrganization() async {
        guard let orgID = selectedOrganizationID else { return }
        await refresh(orgUUID: orgID)
    }

    /// 現在の session / weekly のうち、より厳しい(percentが高い)方。どちらも無ければ nil。
    var dominantLimit: (label: String, limit: UsageLimit)? {
        guard let snapshot else { return nil }
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

    /// ログインウィンドウでの成功検知後に呼ぶ。Cookieを保存し、初回データ取得をトリガーする。
    func handleLoginSucceeded(cookieHeader: String) {
        do {
            try keychain.saveCookie(cookieHeader)
        } catch {
            lastErrorMessage = "Cookieの保存に失敗しました: \(error)"
            return
        }
        loginState = .checking
        Task { await bootstrap() }
    }

    /// ログアウト操作(将来UIから呼べるように用意)。
    func logout() {
        scheduler.stop()
        keychain.clearCookie()
        apiClient = nil
        organizations = []
        loginState = .loggedOut
    }

    // MARK: - Private

    private func persistSelectedOrganization(_ uuid: String) {
        selectedOrganizationID = uuid
        defaults.set(uuid, forKey: Keys.selectedOrganizationUUID)
    }

    private func refresh(orgUUID: String) async {
        guard !isRefreshing else { return }
        guard let client = apiClient else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let newSnapshot = try await client.fetchUsage(orgUUID: orgUUID)
            let previous = self.snapshot
            self.snapshot = newSnapshot
            store.save(snapshot: newSnapshot)
            reloadWidgets()
            store.appendHistory(
                HistoryPoint(
                    timestamp: newSnapshot.fetchedAt,
                    sessionPercent: newSnapshot.session?.percent,
                    weeklyPercent: newSnapshot.weekly?.percent
                ),
                maxPoints: 288
            )
            self.history = store.loadHistory()

            if notificationsEnabled {
                notificationManager.evaluate(previous: previous, current: newSnapshot)
            }

            if newSnapshot.needsLogin {
                loginState = .loggedOut
            } else {
                loginState = .loggedIn
                lastErrorMessage = nil
            }
        } catch {
            handleFetchError(error, fallbackMessage: "使用量の取得に失敗しました")
        }
    }

    /// `refresh(orgUUID:)` の失敗時ハンドラ。
    /// - 認証エラー(notLoggedIn/401/403): ログアウト状態にし、直前のsnapshotがあれば
    ///   `needsLogin: true` に付け替えて保存し直す(Widgetが「要ログイン」を表示できるように)。
    /// - それ以外(ネットワーク一時障害等): ログイン画面には落とさず、直前のsnapshotがあれば
    ///   `isStale: true` に付け替えて保存し直す(値はそのまま維持しつつ「古い可能性」を表せるように)。
    private func handleFetchError(_ error: Error, fallbackMessage: String) {
        switch error {
        case ClaudeAPIError.notLoggedIn:
            markNeedsLoginSnapshot()
            loginState = .loggedOut
        case ClaudeAPIError.httpError(let code) where code == 401 || code == 403:
            markNeedsLoginSnapshot()
            loginState = .loggedOut
        default:
            // ネットワーク一時障害等ではログイン画面に落とさず、キャッシュ済みスナップショットを見せ続ける。
            markStaleSnapshot()
            lastErrorMessage = "\(fallbackMessage): \(error)"
        }
    }

    /// 直前のsnapshotの session/weekly をそのまま(無ければnilのまま)引き継ぎつつ、
    /// `needsLogin: true` のsnapshotを組み立てて反映・永続化する。
    /// 直前のsnapshotが無い場合でも(要ログインを示すために)新規に組み立てる。
    private func markNeedsLoginSnapshot() {
        let previous = snapshot
        let updated = UsageSnapshot(
            session: previous?.session,
            weekly: previous?.weekly,
            fetchedAt: previous?.fetchedAt ?? Date(),
            isStale: false,
            needsLogin: true
        )
        snapshot = updated
        store.save(snapshot: updated)
        reloadWidgets()
    }

    /// 直前のsnapshotがあれば、値は変えずに `isStale: true` へ付け替えて反映・永続化する。
    /// 直前のsnapshotが無ければ何もしない(表示すべきデータ自体が無いため)。
    private func markStaleSnapshot() {
        guard let previous = snapshot else { return }
        let updated = UsageSnapshot(
            session: previous.session,
            weekly: previous.weekly,
            fetchedAt: previous.fetchedAt,
            isStale: true,
            needsLogin: false
        )
        snapshot = updated
        store.save(snapshot: updated)
        reloadWidgets()
    }

    /// デスクトップ/通知センターのWidgetにデータ更新を伝え、即座に再描画させる。
    /// これを呼ばないと、WidgetKitのタイムライン更新間隔(最大15分)までWidget側の表示が古いままになる。
    private func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
