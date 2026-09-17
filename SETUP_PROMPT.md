# セットアップ指示書（Claude Code向け）

このファイルは、別のMacでこのプロジェクト（Claude Usage Meter: claude.aiの使用率をメニューバー/ウィジェットに表示するmacOSアプリ）をセットアップするための自己完結した指示書です。ユーザーからこのファイルを実行するよう指示されたら、以下を順番に実施してください。

## 前提

- macOS、Xcode（App Storeからインストール済みであること）
- Homebrew
- `gh` CLIでGitHubにログイン済みであること（未ログインなら `gh auth login` をユーザーに実行してもらう）

## 手順

### 1. Xcodeの導入確認

```bash
xcode-select -p
xcodebuild -version
```

Xcodeがインストールされていなければ、App Storeからのインストールをユーザーに依頼して中断する。

### 2. リポジトリをclone

ユーザーの作業ディレクトリ配下（例: `~/`）に以下でclone する。

```bash
git clone https://github.com/withfox-fox1/claude-usage-meter.git
cd claude-usage-meter
```

### 3. xcodegen の導入

```bash
brew list xcodegen || brew install xcodegen
```

### 4. Xcodeプロジェクト生成

```bash
xcodegen generate
```

### 5. 署名チーム（DEVELOPMENT_TEAM）の確認

`project.yml` には `DEVELOPMENT_TEAM: "2Y64BNQ29J"` が設定済み。これは開発元のApple ID（Personal Team）のTeam IDで、**同じApple IDでXcodeにログインしていればそのまま流用できる**。

- このMacのXcodeに同じApple IDでサインイン済みかユーザーに確認する。
- 未サインインなら、Xcode → Settings → Accounts でApple IDを追加するようユーザーに依頼する。
- 別のApple IDを使う場合は、Xcodeの Settings → Accounts でそのアカウントのTeam IDを確認し、`project.yml` の2箇所（トップレベル settings と、必要なら各ターゲット）の `DEVELOPMENT_TEAM` を書き換えてから再度 `xcodegen generate` を実行する。

### 6. ビルド（CLIで検証）

```bash
xcodebuild -project ClaudeUsageMeter.xcodeproj \
  -scheme ClaudeUsageMeter \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -allowProvisioningUpdates \
  build
```

エラーが出た場合はログを読んで原因を切り分ける（署名エラーが最も起きやすい。手順5を再確認する）。

### 7. アプリを起動（ここから先はユーザー操作が必要）

```bash
open build/Build/Products/Debug/ClaudeUsageMeter.app
```

起動すると初回はログイン画面（WKWebView）が表示される。**ここはユーザー自身の操作が必要**なので、以下をユーザーに伝えて引き継ぐこと：

1. 表示されたログイン画面で claude.ai にログインしてください
2. ログイン後、メニューバーにアイコンが表示されることを確認してください
3. デスクトップ/通知センターにウィジェットを追加する場合は、ウィジェットギャラリーから「Claude Usage Widget」を検索して追加してください（GUI操作のためこちらもユーザー自身で行う）

### 8. Personal Team署名の注意点をユーザーに伝える

無料のPersonal Team署名の場合、プロビジョニングプロファイルは7日で失効する。週1回程度、XcodeからCmd+Rで再実行してプロファイルを更新する必要がある（詳細は README.md 参照）。

## 完了報告

上記を完了したら、以下をまとめてユーザーに報告する：
- ビルドが成功したか
- アプリが起動したか（ログイン画面が出た時点で成功とみなしてよい。ログイン自体はユーザー任せ）
- 発生したエラーとその対処
