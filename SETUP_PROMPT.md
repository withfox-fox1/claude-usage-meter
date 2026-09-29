# セットアップ指示書（Claude Code向け）

このファイルは、別のMacに Claude Usage Meter（claude.aiの使用率をメニューバーに表示するmacOSアプリ）を導入・更新するための自己完結した指示書です。
ユーザーからこのファイル（またはこのリポジトリのURL）を渡されて「これで実装して」と言われたら、以下を上から順に実施してください。

新規導入のMacでも、旧版（ウィジェット付き・Xcodeから起動していた版）が入っているMacでも、同じ手順で最新版になります。

## このアプリの前提（作業前に把握しておくこと）

- 対応OS: **macOS 14 Sonoma 以降**（`project.yml` の `deploymentTarget: "14.0"`）
- メニューバー専用アプリ。ウィジェットは廃止済み
- **プロビジョニングプロファイルなしで署名する**（`project.yml` で `CODE_SIGN_STYLE: Manual` / `CODE_SIGN_IDENTITY: "Apple Development"`）。
  無料のPersonal Teamのプロファイルは7日で失効し、失効後はアプリが起動できなくなるため。
  **App Groups / keychain-access-groups などプロファイルが必要な権限は絶対に追加しないこと。**
- 常用は `/Applications/ClaudeUsageMeter.app` から起動する。XcodeのRun（Cmd+R）で起動するとデバッガ配下になり、Xcodeを閉じると一緒に終了してしまう
- 以下のコマンドは、特に断りがなければリポジトリのルート（`~/claude-usage-meter`）で実行する

## 手順

### 1. macOSとXcodeの確認

```bash
sw_vers -productVersion
xcode-select -p
xcodebuild -version
```

- macOSが **14.0未満** なら、ここで中断してユーザーに「このMacのmacOSでは動かない（Sonoma以降が必要）」と伝える。
- Xcodeが入っていない場合は、App Storeからのインストールをユーザーに依頼して中断する。App Storeで入らない古いOSでは、https://developer.apple.com/download/all/ から次のバージョンを入れてもらう:
  - macOS 14.5以降: Xcode 16.x（macOS 14 で使える最新は 16.2）
  - macOS 14.0〜14.4: Xcode 15.4（この場合、手順5のテストは実行できないのでスキップする）
- `xcode-select -p` が `/Library/Developer/CommandLineTools` を指している場合、ユーザーに次を実行してもらう（sudoが必要なのでユーザー自身で）:
  `! sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
- Xcodeを入れた直後でライセンス未同意のエラーが出る場合は、ユーザーに `! sudo xcodebuild -license accept` を実行してもらい、続けて `xcodebuild -runFirstLaunch` を実行する。

### 2. xcodegen の導入

```bash
brew list xcodegen || brew install xcodegen
```

Homebrew自体が無い場合は https://brew.sh の手順での導入をユーザーに依頼する。

### 3. ソースの取得

リポジトリは公開（public）なのでログイン不要。

- `~/claude-usage-meter` が**無い**場合:
  ```bash
  git clone https://github.com/withfox-fox1/claude-usage-meter.git ~/claude-usage-meter
  ```
- **既にある**場合（旧版を導入済み）: `git status --short` で未コミットの変更が無いことを確認してから `git pull --ff-only`。
  変更がある場合は勝手に捨てず、ユーザーに確認する。

### 4. 旧版の後片付け（旧版が無ければ何も起きないので、そのまま実行してよい）

旧版はXcodeや `build/Build/Products/Debug` から起動し、ウィジェットを登録していた。新版と同じバンドルID（`dev.local.claudeusagemeter`）なので、残っていると取り違えの原因になる。

zshでは一致するファイルが無いと `no matches found` で止まるため、**必ず `bash` で実行する**:

```bash
bash <<'EOF'
# 起動中のメーターを終了
pkill -x ClaudeUsageMeter || true

# 旧版のウィジェット登録を解除
pluginkit -m -v -i dev.local.claudeusagemeter.widget 2>/dev/null \
  | awk -F'\t' '{print $NF}' | grep '\.appex$' | while read -r p; do pluginkit -r "$p"; done

# 旧版のビルド成果物を削除（どれもビルドのキャッシュで、再ビルドで作り直せる）
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
for app in ~/Library/Developer/Xcode/DerivedData/ClaudeUsageMeter-*/Build/Products/*/ClaudeUsageMeter.app \
           ~/claude-usage-meter/build/Build/Products/*/ClaudeUsageMeter.app; do
  [ -d "$app" ] && "$LSREG" -u "$app"
done
rm -rf ~/Library/Developer/Xcode/DerivedData/ClaudeUsageMeter-* ~/claude-usage-meter/build
EOF

# 確認（何も表示されなければOK）
pluginkit -m -i dev.local.claudeusagemeter.widget
```

- ユーザーのデスクトップ/通知センターに旧ウィジェットが置かれていた場合、壊れた表示が残ることがある。完了報告で「右クリック →ウィジェットを削除 で消してください」と伝える。

### 5. プロジェクト生成とテスト

```bash
xcodegen generate
cd Sources/Shared && swift test; cd ../..
```

- `swift test` は Swift Testing（`import Testing`）を使うため **Xcode 16以上が必要**。Xcode 15.4の環境ではスキップしてよい（アプリのビルドには不要）。
- テストが失敗した場合は中断し、出力をユーザーに見せて相談する。

### 6. 署名方法を決める

```bash
security find-identity -v -p codesigning | grep "Apple Development"
```

**A. `Apple Development` 証明書が見つかった場合（推奨ルート）**

証明書のTeam IDを取り出す（`project.yml` の `2Y64BNQ29J` と違うApple IDでも、これで上書きすれば動く）:

```bash
TEAM=$(security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')
echo "$TEAM"
```

証明書が複数あってTEAMが意図と違う場合は、ユーザーにどのApple IDを使うか確認する。

**B. 証明書が無い場合**

ユーザーに次のどちらかを選んでもらう:

1. **Apple IDでサインインして証明書を作る（おすすめ）**: Xcode → Settings → Accounts でApple ID（無料でよい）を追加 → そのアカウントを選んで「Manage Certificates…」→ 左下の「+」→「Apple Development」。完了したら手順6をやり直す。
2. **Apple IDを使わない（アドホック署名）**: 手順7で `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` を指定してビルドする。
   動作に問題はないが、**ビルドし直すたびに初回起動時に「キーチェーンへのアクセスを許可しますか」と聞かれる**（「常に許可」を押せば次のビルドまで出ない）。

### 7. Release版のビルド

A（証明書あり）の場合:

```bash
xcodebuild -project ClaudeUsageMeter.xcodeproj -scheme ClaudeUsageMeter \
  -configuration Release -derivedDataPath build \
  DEVELOPMENT_TEAM="$TEAM" build
```

B-2（アドホック）の場合:

```bash
xcodebuild -project ClaudeUsageMeter.xcodeproj -scheme ClaudeUsageMeter \
  -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

- `-allowProvisioningUpdates` は付けない（プロファイルを使わないため不要）。
- 最後に `** BUILD SUCCEEDED **` が出れば成功。`AppIcon has 2 unassigned children` の警告は既知で無害。
- 失敗した場合は `error:` の行を読んで切り分ける。署名関連（`No signing certificate` など）なら手順6に戻る。
  Swiftのコンパイルエラーの場合、このリポジトリは Xcode 27 でビルド確認しているため、古いXcode固有の非互換の可能性がある。
  エラー内容をユーザーに見せ、修正してよいか確認してから直す（直したら手順5のテストも通すこと）。

### 8. ビルド結果の検証

```bash
APP=build/Build/Products/Release/ClaudeUsageMeter.app
find "$APP" -name "*.provisionprofile" | wc -l          # 0 であること（1以上なら7日で起動不能になる）
codesign -d --entitlements - --xml "$APP" | plutil -p -  # app-sandbox / network.client / get-task-allow の3つだけであること
codesign --verify --deep --strict "$APP" && echo VERIFY_OK
```

どれか満たさない場合はインストールせず中断し、ユーザーに報告する。

### 9. /Applications へのインストールと起動

```bash
pkill -x ClaudeUsageMeter || true
rm -rf /Applications/ClaudeUsageMeter.app
ditto build/Build/Products/Release/ClaudeUsageMeter.app /Applications/ClaudeUsageMeter.app
open /Applications/ClaudeUsageMeter.app
sleep 3
ps -axo pid,ppid,comm | grep '/Applications/ClaudeUsageMeter.app' | grep -v grep   # 親PIDが 1 なら正常（Xcode配下ではない）
```

### 10. ログイン項目に登録（Mac起動時に自動で立ち上げる）

```bash
osascript -e 'tell application "System Events" to get the name of every login item'
```

一覧に `ClaudeUsageMeter` が無ければ追加する（既にあれば追加しない。重複登録になるため）:

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/ClaudeUsageMeter.app", hidden:false}'
osascript -e 'tell application "System Events" to get path of login item "ClaudeUsageMeter"'   # /Applications/ClaudeUsageMeter.app と出ればOK
```

- 初回は「“ターミナル”（または実行中のアプリ）が“System Events”を制御しようとしています」という確認が出る。ユーザーに「OK」を押してもらう。
- 拒否されて失敗した場合は、ユーザーに手動で登録してもらう: システム設定 → 一般 → ログイン項目 → 「+」→ `/Applications/ClaudeUsageMeter.app`。

### 11. ユーザーに引き継ぐ（ここはユーザー自身の操作）

以下を伝える:

1. メニューバーにメーターのアイコンが出ていることを確認してください
2. ログイン画面が表示された場合は claude.ai にログインしてください（旧版で同じMacにログイン済みなら、そのまま使えることが多い）
3. 組織が複数ある場合、表示中の組織が違えばメニューから選び直してください（旧版から更新した場合、組織の選択・通知設定・グラフ履歴はリセットされています）
4. アドホック署名（B-2）の場合、キーチェーンの確認が出たら「常に許可」を押してください

## 今後コードを更新したとき

```bash
cd ~/claude-usage-meter && git pull --ff-only && xcodegen generate
```

のあと、手順7〜9（ビルド → 検証 → /Applications に上書き）を繰り返す。ログイン項目の登録はやり直さなくてよい。

## 完了報告

以下をまとめてユーザーに報告する（「動いた」と言う場合は、実際のコマンド出力を添える）:

- macOS / Xcode のバージョン
- 旧版の後片付けで何を消したか（無ければ「旧版なし」）
- テスト結果（スキップした場合はその理由）
- 署名方法（A: Apple Development / B-2: アドホック）とビルド結果
- 手順8の検証結果（プロファイル数・権限・VERIFY_OK）
- 起動状態（PIDと親PID）とログイン項目への登録結果
- 発生したエラーとその対処、ユーザーに残っている作業
