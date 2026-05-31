# ScreenStore

Mac 専用の Screenpresso 風スクリーンショット / 画面録画 / 注釈アプリ。自分用。

## 必要環境

- macOS 14 (Sonoma) 以降 / Apple Silicon Mac 推奨
- Xcode 15 以降
- Swift 5.9 以降

## 機能 (Phase 1 MVP)

- 全画面キャプチャ ✅
- ウィンドウ指定キャプチャ ✅ (Sprint 2 / `Cmd+Shift+3` のメニュー → アプリごとにウィンドウを選択)
- 自由範囲指定キャプチャ ✅ (Sprint 2 / `Cmd+Shift+4` → ドラッグで矩形選択 / ESC でキャンセル)
- 履歴一覧 + プレビュー
- 注釈（矢印 / 四角 / テキスト / モザイク、Phase 1 後半）
- PNG 保存 / クリップボードコピー

Phase 2 以降で OCR・画面録画・スクロールキャプチャを追加予定。

## ビルド手順

1. Xcode で `ScreenStore.xcodeproj` を開く
2. Run スキームを `ScreenStore` に設定し、`Cmd+R`
3. 初回起動時に「画面収録」の許可を求められるので、システム設定で ScreenStore を許可してから再起動

## 保存先

```
~/Pictures/ScreenStore/
├─ images/    # スクリーンショット PNG
└─ videos/    # 画面録画 MP4 (Phase 2)
```

## デバッグ用 CLI フラグ

`ScreenStore.app/Contents/MacOS/ScreenStore` に直接渡すと GUI なしで動作確認できる:

| フラグ | 説明 |
|---|---|
| `--register-tcc` | 新しい cdhash を TCC db に登録 (再ビルド後の権限再認可前に実行) |
| `--smoke-capture` | 全画面キャプチャを 1 回実行してログ出力 → 終了 |
| `--smoke-window` | 共有可能ウィンドウ一覧の先頭をキャプチャ → 終了 |
| `--smoke-region <x>,<y>,<w>,<h>` | メイン画面の左下原点 / point 座標で範囲キャプチャ → 終了 |

例:

```bash
APP="$(xcodebuild -showBuildSettings -scheme ScreenStore -configuration Debug | awk '/BUILT_PRODUCTS_DIR/{print $3}')/ScreenStore.app/Contents/MacOS/ScreenStore"
"$APP" --smoke-region "100,100,400,300"
log show --predicate 'subsystem == "com.sinoda.ScreenStore"' --last 1m --info --style syslog | tail -20
```

## セットアップ手順 (まっさらな環境から)

[SETUP.md](SETUP.md) を参照。
