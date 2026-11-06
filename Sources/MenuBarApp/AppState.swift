import Foundation
import Combine
import ClaudeUsageCore

/// メニューバーアプリ全体の状態を保持し、Core層(ClaudeUsageCore)とUIをつなぐオーケストレーター。
///
/// 責務:
/// - 起動時に Keychain の Cookie を確認し、組織一覧 -> 使用量取得までの初期フローを実行する
/// - PollingScheduler による5分おきの定期更新
/// - 通知ON/OFF・選択中組織の永続化(UserDefaults.standard)
/// - ログイン切れ検知時の状態遷移(loggedIn -> loggedOut)
/// - 複数アカウントの切り替え・追加・削除(使用量を取得するのは選択中のアカウントだけ)
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
    @Published private(set) var accounts: [Account]
    @Published private(set) var activeAccountID: String

    // 以下4つは選択中アカウント専用のインスタンス。切り替え時に作り直す。
    private var store: UsageStore
    private var keychain: KeychainStore
    private var notificationManager: NotificationManager
    private var apiClient: ClaudeAPIClient?

    private let scheduler: PollingScheduler
    private let cookieRefreshService: CookieRefreshService
    private let defaults: UserDefaults
    private let registry: AccountRegistry
    private var didStart = false
    /// アカウントを切り替えるたびに増やす。通信の完了時に値が変わっていたら、
    /// その結果は切り替え前のアカウントのものなので破棄する。
    private var accountGeneration = 0

    init(scheduler: PollingScheduler = PollingScheduler(interval: 300)) {
        let registry = AccountRegistry()
        let accounts = registry.loadAccounts()
        let active = accounts.first(where: { $0.id == registry.activeAccountID }) ?? accounts[0]
        registry.activeAccountID = active.id

        self.registry = registry
        self.accounts = accounts
        self.activeAccountID = active.id
        self.store = UsageStore(namespace: active.storageNamespace)
        self.keychain = active.makeKeychain()
        self.notificationManager = NotificationManager(namespace: active.storageNamespace)
        self.scheduler = scheduler
        self.defaults = .standard
        self.notificationsEnabled = (self.defaults.object(forKey: Keys.notificationsEnabled) as? Bool) ?? true
        self.selectedOrganizationID = self.defaults.string(forKey: Self.selectedOrganizationKey(for: active))
        // 直近のキャッシュ値を即座に表示できるよう、ネットワーク疎通前にロードしておく。
        self.snapshot = store.loadSnapshot()
        self.history = store.loadHistory()
        self.cookieRefreshService = CookieRefreshService(keychain: keychain, dataStore: active.dataStore)

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

    /// アプリ起動時に一度だけ呼ぶ(2回目以降は何もしない)。
    func start() async {
        guard !didStart else { return }
        didStart = true
        cookieRefreshService.start()
        await WebsiteDataStores.removeOrphans(keeping: accounts)
        await bootstrap()
    }

    // MARK: - Accounts

    var activeAccount: Account? { accounts.first(where: { $0.id == activeAccountID }) }

    func displayName(of account: Account) -> String {
        account.displayName(index: accounts.firstIndex(of: account) ?? 0)
    }

    /// メニューで別のアカウントを選んだときに呼ぶ。
    func switchAccount(to id: String) {
        guard id != activeAccountID, let account = accounts.first(where: { $0.id == id }) else { return }
        activate(account)
        Task { await bootstrap() }
    }

    /// 新しいアカウント用の(空の)保存領域でログインウィンドウを開き、ログインできたら一覧に加えて切り替える。
    func beginAddAccount() {
        let pending = Account.makeNew()
        let dataStore = pending.dataStore
        LoginWindowController.shared.present(
            dataStore: dataStore,
            onLoginDetected: { [weak self] cookieHeader in
                Task { await self?.completeAddAccount(pending, cookieHeader: cookieHeader) }
            },
            onCancel: {
                Task { await WebsiteDataStores.remove(pending.dataStoreIdentifier) }
            }
        )
    }

    /// 選択中アカウントのログインウィンドウを開く(ログイン切れからの再ログイン用)。
    func beginLoginForActiveAccount() {
        guard let account = activeAccount else { return }
        LoginWindowController.shared.present(dataStore: account.dataStore) { [weak self] cookieHeader in
            guard let self, self.activeAccountID == account.id else { return }
            self.handleLoginSucceeded(cookieHeader: cookieHeader)
        }
    }

    /// アカウントを一覧から削除し、保存していたCookie・使用量・WebViewのログイン情報も消す。
    /// 最後の1件は削除できない(削除するとログイン先が無くなるため)。
    func removeAccount(id: String) {
        guard accounts.count > 1, let account = accounts.first(where: { $0.id == id }) else { return }
        if account.id == activeAccountID, let next = accounts.first(where: { $0.id != id }) {
            activate(next)
            Task { await bootstrap() }
        }
        accounts.removeAll { $0.id == id }
        registry.save(accounts: accounts)
        Task { await purgeData(of: account) }
    }

    private func completeAddAccount(_ pending: Account, cookieHeader: String) async {
        let pendingKeychain = pending.makeKeychain()
        do {
            try pendingKeychain.saveCookie(cookieHeader)
        } catch {
            lastErrorMessage = "Cookieの保存に失敗しました: \(error)"
            await WebsiteDataStores.remove(pending.dataStoreIdentifier)
            return
        }

        let client = ClaudeAPIClient(cookieProvider: { cookieHeader })
        let email = await client.fetchAccountEmail()
        var added = pending
        added.email = email
        if let email {
            added.label = email
        } else {
            added.label = (try? await client.fetchOrganizations().first?.name) ?? ""
        }

        // 同じアカウント(メールアドレスが一致)にもう一度ログインした場合は、既存のアカウントを残して
        // ログイン情報とWebViewの保存領域だけを新しいものに差し替える(使用量の履歴を消さないため)。
        if let email = added.email, let index = accounts.firstIndex(where: { $0.email == email }) {
            var existing = accounts[index]
            let oldDataStoreID = existing.dataStoreIdentifier
            try? existing.makeKeychain().saveCookie(cookieHeader)
            pending.makeKeychain().clearCookie()
            existing.dataStoreID = pending.dataStoreID
            existing.label = added.label
            accounts[index] = existing
            registry.save(accounts: accounts)
            activate(existing)
            if let oldDataStoreID {
                await WebsiteDataStores.remove(oldDataStoreID)
            } else {
                await WebsiteDataStores.clearDefaultStore()
            }
        } else {
            accounts.append(added)
            registry.save(accounts: accounts)
            activate(added)
        }
        await bootstrap()
    }

    /// 選択中アカウントを切り替え、そのアカウント用のKeychain・保存先・通知状態に付け替える。
    private func activate(_ account: Account) {
        accountGeneration += 1
        scheduler.stop()
        isRefreshing = false
        apiClient = nil
        organizations = []
        lastErrorMessage = nil

        activeAccountID = account.id
        registry.activeAccountID = account.id
        keychain = account.makeKeychain()
        store = UsageStore(namespace: account.storageNamespace)
        notificationManager = NotificationManager(namespace: account.storageNamespace)
        cookieRefreshService.setAccount(keychain: keychain, dataStore: account.dataStore)
        selectedOrganizationID = defaults.string(forKey: Self.selectedOrganizationKey(for: account))
        snapshot = store.loadSnapshot()
        history = store.loadHistory()
        loginState = .checking
    }

    private func purgeData(of account: Account) async {
        account.makeKeychain().clearCookie()
        UsageStore(namespace: account.storageNamespace).clear()
        NotificationManager(namespace: account.storageNamespace).clear()
        defaults.removeObject(forKey: Self.selectedOrganizationKey(for: account))
        if let identifier = account.dataStoreIdentifier {
            await WebsiteDataStores.remove(identifier)
        } else {
            // 従来アカウントは既定の保存領域を使っているので、その中身(ログインCookie等)を消す。
            await WebsiteDataStores.clearDefaultStore()
        }
    }

    /// メールアドレス未取得のアカウント(従来アカウント等)に、メールアドレスと表示名を付ける。
    /// メールが取れない場合でも、表示名が空なら組織名を表示名にする(重複判定には使わない)。
    private func updateLabelIfNeeded(client: ClaudeAPIClient, generation: Int) async {
        guard let index = accounts.firstIndex(where: { $0.id == activeAccountID }),
              accounts[index].email == nil else { return }
        let email = await client.fetchAccountEmail()
        guard generation == accountGeneration,
              let current = accounts.firstIndex(where: { $0.id == activeAccountID }) else { return }
        if let email {
            accounts[current].email = email
            accounts[current].label = email
        } else if accounts[current].label.isEmpty, let orgName = organizations.first?.name {
            accounts[current].label = orgName
        } else {
            return
        }
        registry.save(accounts: accounts)
    }

    private static func selectedOrganizationKey(for account: Account) -> String {
        account.isLegacy ? Keys.selectedOrganizationUUID : "\(Keys.selectedOrganizationUUID).\(account.id)"
    }

    /// Cookie の有無を確認し、あれば組織一覧 -> 使用量取得 -> 定期更新開始まで行う。
    /// 無ければ `.loggedOut` にして呼び出し側でログイン画面を出せるようにする。
    func bootstrap() async {
        guard let cookie = keychain.loadCookie(), !cookie.isEmpty else {
            // 古い数字ではなく「要ログイン」を表示できるよう、キャッシュがあれば
            // needsLogin: true に付け替えて保存し直す。
            if snapshot != nil {
                markNeedsLoginSnapshot()
            }
            loginState = .loggedOut
            return
        }

        let accountKeychain = keychain
        let client = ClaudeAPIClient(cookieProvider: { accountKeychain.loadCookie() })
        self.apiClient = client
        let generation = accountGeneration

        do {
            let orgs = try await client.fetchOrganizations().map(Organization.init)
            guard generation == accountGeneration else { return }
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
            guard generation == accountGeneration else { return }

            scheduler.start { [weak self] in
                await self?.refreshCurrentOrganization()
            }
            await updateLabelIfNeeded(client: client, generation: generation)
        } catch {
            // 切り替え前のアカウントの結果、または通信のキャンセル(-999)は状態に反映しない。
            guard generation == accountGeneration, !Self.isCancellation(error) else { return }
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
        if let account = activeAccount {
            defaults.set(uuid, forKey: Self.selectedOrganizationKey(for: account))
        }
    }

    /// URLSession のキャンセル(NSURLErrorCancelled = -999)や Task のキャンセルかどうか。
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case ClaudeAPIError.network(let underlying) = error {
            return (underlying as? URLError)?.code == .cancelled || underlying is CancellationError
        }
        return (error as? URLError)?.code == .cancelled
    }

    private func refresh(orgUUID: String) async {
        guard !isRefreshing else { return }
        guard let client = apiClient else { return }
        let generation = accountGeneration
        isRefreshing = true
        defer {
            // 切り替え後は activate() がリセット済みなので、新しいアカウントの更新中フラグを消さない。
            if generation == accountGeneration { isRefreshing = false }
        }

        do {
            let newSnapshot = try await client.fetchUsage(orgUUID: orgUUID)
            guard generation == accountGeneration else { return }
            let previous = self.snapshot
            self.snapshot = newSnapshot
            store.save(snapshot: newSnapshot)
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
            guard generation == accountGeneration, !Self.isCancellation(error) else { return }
            handleFetchError(error, fallbackMessage: "使用量の取得に失敗しました")
        }
    }

    /// `refresh(orgUUID:)` の失敗時ハンドラ。
    /// - 認証エラー(notLoggedIn/401/403): ログアウト状態にし、直前のsnapshotがあれば
    ///   `needsLogin: true` に付け替えて保存し直す(「要ログイン」を表示できるように)。
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
    }
}
