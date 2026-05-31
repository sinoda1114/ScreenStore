# ScreenStore

Mac 専用の Screenpresso 風スクリーンショット / 画面録画 / 注釈アプリ。自分用。

## 必要環境

- macOS 14 (Sonoma) 以降 / Apple Silicon Mac 推奨
- Xcode 15 以降
- Swift 5.9 以降

## 機能 (Phase 1 MVP)

- 全画面キャプチャ ✅
- ウィンドウ指定キャプチャ ✅ (Sprint 2 / `Cmd+Shift+3` のメニュー → アプリごとにウィンドウを選択)
- 自由範囲指定キャプチャ（次スプリント）
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

## セットアップ手順 (まっさらな環境から)

[SETUP.md](SETUP.md) を参照。
