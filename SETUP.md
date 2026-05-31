# ScreenStore セットアップ手順

このドキュメントは、まっさらな macOS 環境から ScreenStore を最初にビルドできる状態に持っていくための手順書です。

---

## 1. Xcode をインストール

App Store で **Xcode** を検索してインストール。サイズが大きい (約 10 GB) ため安定した回線で。

インストール後、ターミナルで:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

Xcode を 1 回起動して、追加コンポーネントのインストールを完了させる。

---

## 2. Xcode プロジェクトを作成

Xcode の `File > New > Project` で次のとおり作成:

| 項目 | 値 |
|---|---|
| Template | macOS > **App** |
| Product Name | `ScreenStore` |
| Team | 任意（自分用なら Personal Team または None） |
| Organization Identifier | `com.sinoda` |
| Bundle Identifier | `com.sinoda.screenstore` (自動生成される) |
| Interface | **SwiftUI** |
| Language | **Swift** |
| Storage | **None** (Core Data は次スプリントで導入) |
| Include Tests | **OFF** |
| 保存先 | `/Users/sinoda/dev/ScreenStore` |

**重要**: 保存先ダイアログで `/Users/sinoda/dev/ScreenStore` を選び、「**Create Git repository on my Mac**」のチェックは **外す** こと（既に git init 済みのため）。

作成後、ディレクトリは下記の状態になる:

```
/Users/sinoda/dev/ScreenStore/
├─ .git/
├─ .gitignore
├─ README.md
├─ SETUP.md
├─ staged-sources/                # ← Sprint 1 用のソースコード雛形 (こちらが事前配置)
├─ tools/
│  └─ integrate.sh                # ← staged-sources を ScreenStore/ に統合するスクリプト
├─ ScreenStore.xcodeproj/         # ← Xcode が新規作成
└─ ScreenStore/                   # ← Xcode が新規作成 (空に近い雛形)
   ├─ ScreenStoreApp.swift
   ├─ ContentView.swift
   ├─ Assets.xcassets/
   └─ ScreenStore.entitlements (もし生成されれば)
```

---

## 3. 事前配置されたソースを統合

```bash
cd /Users/sinoda/dev/ScreenStore
./tools/integrate.sh
```

このスクリプトは:

1. `staged-sources/ScreenStore/` 配下の全ファイルを `ScreenStore/` にコピー
2. Xcode 自動生成の `ContentView.swift` と `ScreenStoreApp.swift` を上書き
3. 結果を表示

---

## 4. Xcode プロジェクトに新規ファイルを認識させる

Xcode は `ScreenStore/` フォルダに置かれただけのファイルを **自動では認識しない**。下記いずれかの方法で取り込む:

### 方法 A (推奨): フォルダごとドラッグ

1. Finder で `/Users/sinoda/dev/ScreenStore/ScreenStore/` を開く
2. `Views`, `Models`, `Services`, `Utils` の 4 フォルダを Xcode のプロジェクトナビゲータの `ScreenStore` グループにドラッグ
3. ダイアログで:
   - "Copy items if needed": **チェック外す**（すでに正しい場所にある）
   - "Create groups": **選択**
   - "Add to targets": **`ScreenStore` にチェック**

### 方法 B: 個別追加

`File > Add Files to "ScreenStore"...` で `ScreenStore/Views`, `ScreenStore/Models` など 4 フォルダを順に追加。

---

## 5. Build Settings を整える

Xcode プロジェクトを開き、Project navigator で `ScreenStore` プロジェクトを選択 → Target `ScreenStore` を選択:

### General タブ

- **Minimum Deployments**: macOS **14.0**
- **App Category**: `Productivity` (任意)

### Signing & Capabilities タブ

- **App Sandbox**: **削除** (デフォルトで有効になっていれば、capability の `-` ボタンで外す)
  - 自分用かつ `~/Pictures/ScreenStore` 直書きのため
- Team: 任意（None でもローカル実行は可。Personal Team を使うとアドホックに署名される）

### Info タブ (もしくは Info.plist 直編集)

`Info` タブの "Custom macOS Application Target Properties" に下記を追加:

| Key | Type | Value |
|---|---|---|
| `NSScreenCaptureUsageDescription` | String | `ScreenStore は画面のスクリーンショット取得のために画面収録の許可を必要とします。` |

> **補足**: macOS では `NSScreenCaptureUsageDescription` は厳密には ScreenCaptureKit の許諾文言として表示されないが、将来 TCC が拡張された場合に備えて設定しておく。実質的な許諾は「システム設定 > プライバシーとセキュリティ > 画面収録」で行われる。

---

## 6. ビルド & 実行

1. Xcode で `Cmd + R`
2. 初回起動: アプリが画面収録権限を要求 → システム設定が開かれるのでチェックを入れる → アプリ再起動
3. 「全画面」ボタンを押す → `~/Pictures/ScreenStore/images/` に PNG が出力され、左サイドバーに反映される

---

## 7. 動作確認チェックリスト

- [ ] アプリ起動時にウィンドウが表示される
- [ ] `~/Pictures/ScreenStore/{images,videos}` フォルダが自動作成されている
- [ ] 「全画面」ボタンが押せる (権限未許諾時は警告バナーが出る)
- [ ] 権限許諾後、「全画面」ボタンで PNG が保存される
- [ ] ファイル名が `2026-05-31_103512.png` 形式
- [ ] 履歴サイドバーに即時反映される
- [ ] サイドバーの項目をクリックするとプレビューに大きく表示される
- [ ] アプリを再起動しても既存の PNG が履歴に並ぶ

---

## トラブルシュート

### `error: 'SCScreenshotManager' is only available in macOS 14.0 or newer`

Target の Minimum Deployments が古い。`14.0` に変更。

### 画面収録の許可ダイアログが出ない / 許可しても黒い画像になる

1. システム設定 > プライバシーとセキュリティ > 画面収録 で ScreenStore のチェックを外し、再度入れる
2. アプリを完全に終了して再起動
3. それでもダメなら ScreenStore を一度リストから削除し、再度キャプチャ実行で許可ダイアログを出させる

### 「サンドボックスエラーで `~/Pictures/ScreenStore` に書けない」

Signing & Capabilities で **App Sandbox capability を削除**。
