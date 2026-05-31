# 引継書: Xcode セットアップ & プロジェクト作成

**この作業は人間 (あなた) が行う必要があります。** 終わったら `./tools/integrate.sh` を実行してチャットに戻ってください。

作業時間の目安: **30〜60 分** (大半は Xcode のダウンロード待ち)

---

## 状況サマリ

- リポジトリ: `/Users/sinoda/dev/ScreenStore/`
- すでに git 初期化済み、5 コミット入っている (`git log` で確認可能)
- Sprint 1 のソースコードは `staged-sources/ScreenStore/` に全て配置済み
- **Xcode 本体が未インストール** のため、Xcode プロジェクトファイル (`ScreenStore.xcodeproj`) はまだ存在しない
- このギャップを埋めるのが今回の作業

---

## やること (上から順番に)

### 1. Xcode をインストール (待ち時間 30〜60 分)

```text
1. App Store を開く
2. 検索バーで "Xcode" を検索
3. "Xcode" (Apple 公式・無料) を選び、「入手」→「インストール」
4. 認証要求があれば Apple ID パスワードを入力
5. ダウンロード (約 10 GB) → インストール完了まで放置
```

ダウンロード中は他の作業をして OK。終わると `/Applications/Xcode.app` が出来ている。

### 2. コマンドラインの紐付け (1 分)

ターミナルで:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

確認:

```bash
xcode-select -p
# => /Applications/Xcode.app/Contents/Developer  と出れば OK

xcodebuild -version
# => Xcode 16.x ... のように表示される
```

### 3. Xcode を 1 度起動して追加コンポーネントを入れる (5 分)

```text
1. Launchpad もしくは /Applications/Xcode.app をダブルクリックで起動
2. 初回起動で "Install additional required components?" のダイアログ → "Install" を押す
3. 管理者パスワード入力
4. インストール完了を待つ
5. Welcome 画面が出たら準備 OK (このまま画面は閉じてよい)
```

### 4. 新規 Xcode プロジェクトを作成 (3 分)

Xcode のメニューから:

```text
File > New > Project...
```

ウィザードで以下を選択:

#### 画面 1: テンプレート選択

- 上のタブ: **macOS**
- カード: **App** を選択
- "Next" を押す

#### 画面 2: オプション設定

| 項目 | 入力値 |
|---|---|
| Product Name | `ScreenStore` |
| Team | (任意) None または Personal Team |
| Organization Identifier | `com.sinoda` |
| Bundle Identifier | `com.sinoda.screenstore` (自動入力) |
| Interface | **SwiftUI** |
| Language | **Swift** |
| Storage | **None** |
| Include Tests | **OFF (チェック外す)** |

"Next" を押す。

#### 画面 3: 保存先

- **`/Users/sinoda/dev/ScreenStore`** を選択
- **"Create Git repository on my Mac" のチェックは必ず外す** (重要: 既に git init 済みのため)
- "Create" を押す

#### 確認

ターミナルで:

```bash
ls /Users/sinoda/dev/ScreenStore/
```

下記が見えれば成功:

```text
.git              ScreenStore.xcodeproj   tools
.gitignore        SETUP.md                staged-sources
HANDOVER.md       README.md
ScreenStore       (★新規)
```

`ScreenStore` フォルダ (Xcode 自動生成) と `ScreenStore.xcodeproj` (プロジェクトファイル) が増えていれば OK。

### 5. integrate.sh を実行してソースを統合 (10 秒)

ターミナルで:

```bash
cd /Users/sinoda/dev/ScreenStore
./tools/integrate.sh
```

下記のような出力が出て成功するはず:

```text
==> ScreenStore staging integrator
    repo:   /Users/sinoda/dev/ScreenStore
    src:    /Users/sinoda/dev/ScreenStore/staged-sources/ScreenStore
    dest:   /Users/sinoda/dev/ScreenStore/ScreenStore

==> Swift ソースを上書きコピー
ScreenStoreApp.swift -> ScreenStore/ScreenStoreApp.swift
ContentView.swift    -> ScreenStore/ContentView.swift

==> サブフォルダをコピー
... (Models, Views, Services, Utils が転写される)

==> 統合完了。
```

エラーが出たら出力をそのままチャットに貼り付けてください。

### 6. チャットに戻る

ここまで終わったら、Cursor のチャットに戻って以下のいずれかを送ってください:

```text
Xcode プロジェクト作ったよ
```

または

```text
integrate.sh まで完了
```

そこから先は私 (エージェント) が以下を案内します:

- Xcode で `Models/`・`Views/`・`Services/`・`Utils/` をターゲットに追加する手順
- App Sandbox capability を削除する手順
- `Info.plist` への `NSScreenCaptureUsageDescription` 追加
- Min Deployments を macOS 14.0 に変更
- ビルド・実行・権限許可・動作確認

---

## 詰まったときのトラブルシュート

### Q. App Store で Xcode のダウンロードが進まない

- macOS のバージョンが古いと最新 Xcode が DL できない場合あり
- 一旦 `システム設定 > 一般 > ソフトウェアアップデート` で macOS を最新化
- それでもダメなら https://developer.apple.com/xcode/ から直接 .xip を DL (Apple ID 必要)

### Q. `sudo xcodebuild -license accept` で SUDO パスワードを聞かれる

- Mac のログインパスワードを入力 (画面には表示されない)

### Q. Xcode を起動したら "Command Line Tools のパスを変更しますか" と聞かれる

- "Use Xcode-bundled" 等を選ぶ
- 既に手順 2 で `xcode-select -s` してあるので問題なし

### Q. プロジェクト作成時に "ScreenStore already exists" と出る

- Xcode が既存ディレクトリに被せようとしている可能性
- 保存先を `/Users/sinoda/dev` に設定し、Product Name を `ScreenStore` にすると Xcode は `/Users/sinoda/dev/ScreenStore` を作成しようとする
- 既に同名フォルダ (リポジトリ) があるため、Xcode が拒否する場合あり
- その場合は **保存ダイアログで `/Users/sinoda/dev/ScreenStore` を選択 (中に作る)** に変更
- それでも拒否されたら、一旦 `staged-sources/`, `tools/`, `.gitignore`, `README.md`, `SETUP.md`, `HANDOVER.md`, `.git/` を残したまま空きフォルダのフリをさせる必要があるかも → このときはチャットに戻って相談

### Q. integrate.sh で `ScreenStore.xcodeproj が見つかりません` と WARN が出る

- これは警告であってエラーではない (続行する)
- ただし `ScreenStore/ が見つかりません` で **ERROR** 終了するなら Xcode プロジェクトの作成位置がおかしい
  - 期待: `/Users/sinoda/dev/ScreenStore/ScreenStore.xcodeproj` と `/Users/sinoda/dev/ScreenStore/ScreenStore/`
  - 例えば `/Users/sinoda/dev/ScreenStore/ScreenStore/ScreenStore.xcodeproj` のように 1 階層深くなってないか確認

### Q. その他のエラー

そのままチャットにエラーメッセージを貼ってください。

---

## チェックリスト (完了したら ✓)

- [ ] App Store から Xcode インストール完了
- [ ] `sudo xcode-select -s ...` 実行済み
- [ ] `sudo xcodebuild -license accept` 実行済み
- [ ] Xcode 起動・追加コンポーネントインストール済み
- [ ] Xcode で macOS App テンプレートからプロジェクト作成済み
- [ ] `/Users/sinoda/dev/ScreenStore/ScreenStore.xcodeproj` が存在する
- [ ] `/Users/sinoda/dev/ScreenStore/ScreenStore/` (Xcode 自動生成のソースフォルダ) が存在する
- [ ] `./tools/integrate.sh` を実行して "統合完了" メッセージが出た
- [ ] チャットに「Xcode プロジェクト作ったよ」と報告した
