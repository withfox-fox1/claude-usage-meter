# Claude Usage Meter

Claude.aiのプラン使用率をmacOSのメニューバーに常時表示するアプリです。現在のセッション/週間制限の使用状況を、メニューバーアイコン、通知センター、デスクトップウィジェットで確認できます。

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

### 3. チーム署名を設定

Xcode内で以下を設定してください：

1. **ClaudeUsageMeter** ターゲット → 「Signing & Capabilities」タブ
   - **Team** を自分のApple ID（またはPersonal Team）に設定

2. **ClaudeUsageWidget** ターゲット → 「Signing & Capabilities」タブ
   - **Team** を同じTeamに設定
   - App Groups ケイパビリティがエラーになる場合は、「+ Capability」からApp Groupsを改めて追加してください

### 4. アプリを実行

1. **ClaudeUsageMeter** スキームが選択されていることを確認
2. Cmd+R を押すか、Product → Run をクリック
3. 初回実行時は、ログイン画面（WKWebView）が表示されるので claude.ai にログインしてください

### 5. ウィジェットを追加

ウィジェットをデスクトップまたは通知センターに追加するには：

1. macOSの通知センター/ウィジェット追加画面を開く（通常、ウィジェット+ ボタンをクリック）
2. 「Claude Usage Widget」を検索・選択
3. ウィジェットを追加

## ⚠️ Personal Team署名での重要な注意

**無料のPersonal Team署名でビルドした場合、プロビジョニングプロファイルが7日で失効します。**

このため、**週に1回程度、Xcodeから ClaudeUsageMeter を再実行（Cmd+R）してプロビジョニングプロファイルを更新する必要があります。** 更新しないと、ウィジェットが古い表示のまま停止します。

**解決策**：
- Apple Developer Program（年間99ドル）に登録すると、プロビジョニングプロファイルの有効期限が1年になり、週1更新の手間が不要になります

## 既知の制限事項

- このアプリはclaude.aiの**非公開の内部API**を利用しています
- Anthropic側の仕様変更により、予告なく動作しなくなる可能性があります
- API仕様変更時は、本プロジェクトを更新する必要があります

## ライセンス

Copyright © 2024. All rights reserved.
