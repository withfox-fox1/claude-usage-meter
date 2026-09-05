import Foundation
import AppKit
import WebKit
import ClaudeUsageCore

/// 1日1回、非表示(オフスクリーン)のWKWebViewで claude.ai へアクセスし、Cookieを再取得して
/// Keychainに上書き保存する。`PollingScheduler`(使用量の定期取得)とは独立した、シンプルな
/// `DispatchSourceTimer` ベースの仕組み。
///
/// 再取得したCookieで `/api/organizations` を叩いて失敗する(=ログイン切れ)場合は
/// `onLoginExpired` を呼び出し、呼び出し側(AppState)でメニューバー表示を「要ログイン」へ
/// 切り替えられるようにする。
@MainActor
final class CookieRefreshService {
    private let keychain: KeychainStore
    private let refreshInterval: TimeInterval
    private var timer: DispatchSourceTimer?
    private var hiddenWindow: NSWindow?
    private var webView: WKWebView?
    private var coordinator: RefreshCoordinator?
    private var timeoutWorkItem: DispatchWorkItem?

    /// Cookieの再取得に成功した(=ログインはまだ有効)ときに呼ばれる。
    var onCookieRefreshed: (() -> Void)?
    /// 再取得を試みたがログインが切れていた(401等・ネットワークエラー含む)ときに呼ばれる。
    var onLoginExpired: (() -> Void)?

    init(keychain: KeychainStore, refreshInterval: TimeInterval = 60 * 60 * 24) {
        self.keychain = keychain
        self.refreshInterval = refreshInterval
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + refreshInterval, repeating: refreshInterval)
        t.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 即時実行(起動直後のテストや手動トリガー用にも使える)。
    func refreshNow() {
        guard keychain.loadCookie() != nil else { return } // 未ログインなら何もしない
        guard hiddenWindow == nil else { return } // 実行中は多重起動しない
        guard let url = URL(string: "https://claude.ai/new") else { return }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let newWebView = WKWebView(frame: .zero, configuration: configuration)

        let newCoordinator = RefreshCoordinator(
            onSuccess: { [weak self] cookieHeader in
                guard let self else { return }
                try? self.keychain.saveCookie(cookieHeader)
                self.onCookieRefreshed?()
                self.teardownOffscreenWebView()
            },
            onFailure: { [weak self] in
                guard let self else { return }
                self.onLoginExpired?()
                self.teardownOffscreenWebView()
            }
        )
        newWebView.navigationDelegate = newCoordinator
        self.webView = newWebView
        self.coordinator = newCoordinator

        // WKWebView は完全にウィンドウの外にあると読み込みが不安定になることがあるため、
        // 画面外に配置した非表示ウィンドウにぶら下げておく(表示はしない = orderBack のみ)。
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = newWebView
        window.orderBack(nil)
        self.hiddenWindow = window

        newWebView.load(URLRequest(url: url))

        // 一定時間内に成否が判定できなければ諦めて後片付けする(ネットワーク断など)。
        // タイムアウトはネットワーク不調等の可能性もあるためログイン切れ扱いにはせず、
        // 単に後片付けだけ行う(次回の定期実行に委ねる)。
        let timeout = DispatchWorkItem { [weak self] in
            self?.teardownOffscreenWebView()
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    }

    private func teardownOffscreenWebView() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        hiddenWindow?.contentView = nil
        hiddenWindow?.close()
        hiddenWindow = nil
        webView?.navigationDelegate = nil
        webView = nil
        coordinator = nil
    }
}

/// オフスクリーンWebViewのナビゲーション監視 + ログイン確認用コーディネータ。
/// ログイン確認・Cookie抽出の実処理自体は `WebViewLoginProbe` に共通化しており、
/// `LoginWebView.Coordinator` とはライフサイクル(ウィンドウ表示の有無、
/// 呼び出し元へのコールバックの意味)が異なるためコーディネータとしては専用に実装している。
private final class RefreshCoordinator: NSObject, WKNavigationDelegate {
    private let onSuccess: (String) -> Void
    private let onFailure: () -> Void
    private var didFinishOnce = false

    init(onSuccess: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
        self.onSuccess = onSuccess
        self.onFailure = onFailure
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !didFinishOnce else { return }
        didFinishOnce = true
        checkLoginStatus(webView: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !didFinishOnce else { return }
        didFinishOnce = true
        onFailure()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !didFinishOnce else { return }
        didFinishOnce = true
        onFailure()
    }

    private func checkLoginStatus(webView: WKWebView) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let status = await WebViewLoginProbe.fetchOrganizationsStatus(webView: webView), status == 200 else {
                self.onFailure()
                return
            }
            WebViewLoginProbe.extractCookieHeader(from: webView) { [weak self] cookieHeader in
                guard let self else { return }
                guard let cookieHeader else {
                    self.onFailure()
                    return
                }
                DispatchQueue.main.async {
                    self.onSuccess(cookieHeader)
                }
            }
        }
    }
}
