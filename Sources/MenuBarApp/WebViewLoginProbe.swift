import Foundation
import WebKit

/// `LoginWebView.Coordinator`(ログイン画面)と `CookieRefreshService.RefreshCoordinator`
/// (バックグラウンドでのCookie再取得)の両方が必要とする、
/// 「`/api/organizations` を叩いてログイン状態を確認し、成功していればclaude.aiドメインの
/// Cookieを1本のヘッダー文字列にまとめて取り出す」という手順を共通化した小さなヘルパー。
///
/// ライフサイクル管理(ウィンドウの表示/非表示、タイムアウト、コールバックの意味づけ)は
/// 呼び出し側ごとに異なるため、そこは各Coordinatorに残し、ここには純粋なWebView操作だけを置く。
enum WebViewLoginProbe {
    /// `/api/organizations` にfetchし、レスポンスのHTTPステータスコードを返す。
    /// JS実行自体が失敗した場合は `nil` を返す。
    @MainActor
    static func fetchOrganizationsStatus(webView: WKWebView) async -> Int? {
        let body = """
        return await fetch('/api/organizations', { credentials: 'include' })
            .then((r) => r.status)
            .catch(() => -1);
        """
        guard let value = try? await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page) else {
            return nil
        }
        return intValue(from: value)
    }

    /// `webView` が保持しているclaude.aiドメインのCookieを全て集め、
    /// `"name=value; name2=value2"` 形式のヘッダー文字列にして返す。無ければ `nil`。
    @MainActor
    static func extractCookieHeader(from webView: WKWebView, completion: @escaping (String?) -> Void) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let claudeCookies = cookies.filter { $0.domain.contains("claude.ai") }
            let cookieHeader = claudeCookies
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            completion(cookieHeader.isEmpty ? nil : cookieHeader)
        }
    }

    private static func intValue(from any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
