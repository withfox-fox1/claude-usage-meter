import Foundation
import ClaudeUsageCore

/// ClaudeAPIClient.fetchOrganizations() が返すタプルを SwiftUI で扱いやすくするラッパー。
struct Organization: Identifiable, Hashable, Codable {
    let uuid: String
    let name: String
    var id: String { uuid }

    init(uuid: String, name: String) {
        self.uuid = uuid
        self.name = name
    }

    init(_ tuple: (uuid: String, name: String)) {
        self.uuid = tuple.uuid
        self.name = tuple.name
    }
}

/// アプリ全体のログイン状態。
enum LoginState: Equatable {
    /// 起動直後、Keychainの確認やAPI疎通がまだ済んでいない状態。
    case checking
    /// Cookie が無い、または失効している(要ログイン)。
    case loggedOut
    /// ログイン済みで通常運用中。
    case loggedIn
    /// 認証エラー以外の理由(ネットワーク一時障害等)で初期化に失敗した状態。
    /// ユーザーに見せるメッセージを保持し、再試行できるようにする。
    case error(String)
}
