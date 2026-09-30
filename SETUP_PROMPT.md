# セットアップ指示書（Claude Code向け）

このファイルは、別のMacに Claude Usage Meter（claude.aiの使用率をメニューバーに表示するmacOSアプリ）を導入・更新するための自己完結した指示書です。
ユーザーからこのファイル（またはこのリポジトリのURL）を渡されて「これで実装して」と言われたら、以下を上から順に実施してください。

新規導入のMacでも、旧版（ウィジェット付き・Xcodeから起動していた版）が入っているMacでも、同じ手順で最新版になります。

**想定環境**: macOS 27 / Xcode 27 / Homebrew導入済み / **Xcodeに自分のApple IDでサインイン済み**（無料のApple IDでよい。開発元と同じApple IDである必要はない）。
署名に使うTeam IDはそのMacの証明書から自動で読み取るので、`project.yml` の `DEVELOPMENT_TEAM`（開発元のTeam ID）は書き換えない。
macOS/Xcodeのバージョンが違う環境は未検証なので、違いが見つかったらその旨をユーザーに伝えたうえで進め、エラーが出たら中断して相談する。

## このアプリの前提（作業前に把握しておくこと）

- メニューバー専用アプリ。ウィジェットは廃止済み
- **プロビジョニングプロファイルなしで署名する**（`project.yml` で `CODE_SIGN_STYLE: Manual` / `CODE_SIGN_IDENTITY: "Apple Development"`）。
  無料のPersonal Teamのプロファイルは7日で失効し、失効後はアプリが起動できなくなるため。
  **App Groups / keychain-access-groups などプロファイルが必要な権限は絶対に追加しないこと。**
- 常用は `/Applications/ClaudeUsageMeter.app` から起動する。XcodeのRun（Cmd+R）で起動するとデバッガ配下になり、Xcodeを閉じると一緒に終了してしまう
- 以下のコマンドは、特に断りがなければリポジトリのルート（`~/claude-usage-meter`）で実行する

## 手順

### 1. 環境の確認

```bash
sw_vers -productVersion        # 27.x
xcodebuild -version            # Xcode 27.x
brew --version
security find-identity -v -p codesigning | grep "Apple Development"   # 1件以上あること
```

- Homebrewが無い、またはApple Development証明書が無い場合は、ここで中断してユーザーに状況を伝える。
  証明書が無いのは、XcodeにApple IDでサインインしていないのが原因のことが多い。ユーザーに
  Xcode → Settings → Accounts →「+」でApple IDを追加し、チームを選んで「Manage Certificates…」→「+」→「Apple Development」を作成してもらう。
- macOS/Xcodeのバージョンが27でない場合は、未検証である旨をユーザーに伝えてから進める。

### 1.5. 署名に使うTeam IDの確認

リポジトリ取得後（手順3の後）に使うスクリプトと同じ処理なので、ここでは読み取れるかだけ確認する:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/withfox-fox1/claude-usage-meter/main/scripts/detect-team.sh); echo "exit=$?"
```

- `exit=0` で英数字10桁のTeam IDが1行出ればOK（開発元の `2Y64BNQ29J` と違っていてよい）。
- `exit=1`（証明書なし）: 手順1の証明書の案内をする。
- `exit=2`（複数チームの証明書がある）: 表示されたTeam IDのどれを使うかユーザーに選んでもらい、以降の手順の
  `DEVELOPMENT_TEAM="$(bash scripts/detect-team.sh)"` をすべて `DEVELOPMENT_TEAM=選ばれたID` に置き換えて実行する。
- 証明書名の括弧内（例: `Apple Development: foo@example.com (2DV3KFXZ93)`）はTeam IDではないので、目視で読み取って使わないこと。

### 2. xcodegen の導入

```bash
brew list xcodegen || brew install xcodegen
```

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

- テストが失敗した場合は中断し、出力をユーザーに見せて相談する。

### 6. Release版のビルド

署名はXcodeにサインイン済みのApple IDの「Apple Development」証明書で、プロファイルなしで行う。Team IDだけは `scripts/detect-team.sh` で読み取った値をコマンドラインで渡す（`project.yml` は書き換えない。書き換えると今後の `git pull` で衝突するため）。

```bash
xcodebuild -project ClaudeUsageMeter.xcodeproj -scheme ClaudeUsageMeter \
  -configuration Release -derivedDataPath build \
  DEVELOPMENT_TEAM="$(bash scripts/detect-team.sh)" build
```

- `DEVELOPMENT_TEAM` を付け忘れると、開発元のTeam IDの証明書を探して
  `No "Mac Development" signing certificate matching team ID "2Y64BNQ29J"` で失敗する（開発元のMac以外では必ず付ける）。

- `-allowProvisioningUpdates` は付けない（プロファイルを使わないため不要）。
- 最後に `** BUILD SUCCEEDED **` が出れば成功。`AppIcon has 2 unassigned children` の警告は既知で無害。
- 失敗した場合は `error:` の行をユーザーに見せて相談する。署名関連（`No signing certificate` など）なら手順1の証明書を確認する。

### 7. ビルド結果の検証

```bash
APP=build/Build/Products/Release/ClaudeUsageMeter.app
find "$APP" -name "*.provisionprofile" | wc -l          # 0 であること（1以上なら7日で起動不能になる）
codesign -d --entitlements - --xml "$APP" | plutil -p -  # app-sandbox / network.client / get-task-allow の3つだけであること
codesign --verify --deep --strict "$APP" && echo VERIFY_OK
```

どれか満たさない場合はインストールせず中断し、ユーザーに報告する。

### 8. /Applications へのインストールと起動

```bash
pkill -x ClaudeUsageMeter || true
rm -rf /Applications/ClaudeUsageMeter.app
ditto build/Build/Products/Release/ClaudeUsageMeter.app /Applications/ClaudeUsageMeter.app
open /Applications/ClaudeUsageMeter.app
sleep 3
ps -axo pid,ppid,comm | grep '/Applications/ClaudeUsageMeter.app' | grep -v grep   # 親PIDが 1 なら正常（Xcode配下ではない）
```

### 9. ログイン項目に登録（Mac起動時に自動で立ち上げる）

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

### 10. ユーザーに引き継ぐ（ここはユーザー自身の操作）

以下を伝える:

1. メニューバーにメーターのアイコンが出ていることを確認してください
2. ログイン画面が表示された場合は claude.ai にログインしてください（旧版で同じMacにログイン済みなら、そのまま使える）
3. 組織が複数ある場合、表示中の組織が違えばメニューから選び直してください（旧版から更新した場合、組織の選択・通知設定・グラフ履歴はリセットされています）

## 今後コードを更新したとき

```bash
cd ~/claude-usage-meter && git pull --ff-only && xcodegen generate
```

のあと、手順6〜8（ビルド → 検証 → /Applications に上書き）を繰り返す。ログイン項目の登録はやり直さなくてよい。

## 完了報告

以下をまとめてユーザーに報告する（「動いた」と言う場合は、実際のコマンド出力を添える）:

- macOS / Xcode のバージョン
- 旧版の後片付けで何を消したか（無ければ「旧版なし」）
- テスト結果
- ビルド結果
- 手順7の検証結果（プロファイル数・権限・VERIFY_OK）
- 起動状態（PIDと親PID）とログイン項目への登録結果
- 発生したエラーとその対処、ユーザーに残っている作業
