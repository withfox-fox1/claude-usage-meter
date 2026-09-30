# Claude Usage Meter

Claude.aiのプラン使用率をmacOSのメニューバーに常時表示するアプリです。現在のセッション/週間制限の使用状況を、メニューバーアイコン（オレンジの太陽＋使用率%。50%以上で黄、80%以上で赤）と通知で確認できます。

> 別のMacへの導入・旧版からの更新は、[SETUP_PROMPT.md](SETUP_PROMPT.md) を Claude Code に渡せば自動で行えます。

## 前提条件

このプロジェクトをビルド・実行するには、以下がインストール済みである必要があります：

- **Xcode** (App Storeからインストール)
- **xcodegen** (Homebrewからインストール)

インストール済みの確認方法：
```bash
brew list xcodegen
```

xcodegen がない場合は以下でインストール：
```bash
brew install xcodegen
```

## ビルド手順

### 1. Xcodeプロジェクトを生成

```bash
cd /Users/agents/claude-usage-meter
xcodegen generate
```

これにより `ClaudeUsageMeter.xcodeproj` が生成されます。

### 2. Xcodeで開く

```bash
open ClaudeUsageMeter.xcodeproj
```

### 3. 署名について

`project.yml` で「Apple Development」証明書による**プロビジョニングプロファイルなし**の署名を設定済みです（`CODE_SIGN_STYLE: Manual`）。
Xcodeに自分のApple ID（無料のPersonal Teamで可）でサインインしていれば、どのApple IDでもビルドできます。
`project.yml` の `DEVELOPMENT_TEAM` は開発元のTeam IDなので、コマンドラインでビルドするときは
`DEVELOPMENT_TEAM="$(bash scripts/detect-team.sh)"` を付けて自分のTeam IDを渡してください（下の手順4に含めています）。
Xcodeの画面からビルドする場合は、Signing & Capabilities の Team を自分のチームに変えてください。

> 無料のPersonal Teamのプロファイルは7日で失効し、失効後はアプリが起動できなくなります。
> そのためプロファイルが必要な権限（App Groups / keychain-access-groups）は使わず、ウィジェットも廃止しています。
> プロジェクトにこれらの権限を足すと、また7日ごとの再ビルドが必要になるので注意してください。

### 4. 常用のためにインストール

XcodeのRun（Cmd+R）で起動したアプリはデバッガ配下で動くため、**Xcodeを閉じると一緒に終了します**。
普段使いにはRelease版を `/Applications` に置いて起動してください。

```bash
xcodebuild -project ClaudeUsageMeter.xcodeproj -scheme ClaudeUsageMeter \
  -configuration Release -derivedDataPath build \
  DEVELOPMENT_TEAM="$(bash scripts/detect-team.sh)" build
pkill -x ClaudeUsageMeter; rm -rf /Applications/ClaudeUsageMeter.app
ditto build/Build/Products/Release/ClaudeUsageMeter.app /Applications/ClaudeUsageMeter.app
open /Applications/ClaudeUsageMeter.app
```

初回起動時はログイン画面（WKWebView）が表示されるので claude.ai にログインしてください。
Mac起動時に自動で立ち上げたい場合は、システム設定 → 一般 → ログイン項目 に `/Applications/ClaudeUsageMeter.app` を追加します。

## 既知の制限事項

- このアプリはclaude.aiの**非公開の内部API**を利用しています
- Anthropic側の仕様変更により、予告なく動作しなくなる可能性があります
- API仕様変更時は、本プロジェクトを更新する必要があります

## ライセンス

Copyright © 2024. All rights reserved.
