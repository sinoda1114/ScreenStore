# App Store 提出チェックリスト

## Apple Developer / App Store Connect

- [x] Apple Developer Program の有効化メールを確認
- [x] Xcodeの「Accounts」でTeamが表示されることを確認
- [ ] App Store Connectの契約・税金・口座情報を確認（無料アプリのみなら口座情報は通常不要）
- [x] Bundle ID `com.sinoda.ScreenStore` をIdentifiersへ登録
- [x] App Store ConnectでmacOSアプリを新規作成し、アプリ名の空きを確認
- [x] SKUを決定（例: `screenstore-macos-001`）

## コードと署名

- [x] App Sandboxを有効化
- [x] Hardened Runtimeを有効化
- [x] 外部`ffmpeg`依存を廃止
- [x] 外部`screencapture`依存を廃止
- [x] 他アプリの設定変更を廃止
- [x] プライバシーマニフェストを追加
- [x] Team IDをXcodeで選択
- [ ] Release Archiveを作成
- [ ] Archiveからプライバシーレポートを生成・確認
- [ ] Validate Appを実行

## 掲載情報

- [x] 日本語・英語の説明文
- [x] プライバシーポリシー原稿
- [x] サポートページ原稿
- [x] GitHub Pagesを有効化して公開URLを確認
- [ ] 日本語・英語のスクリーンショットを作成
- [x] App Privacyを「データ収集なし」で回答
- [x] 年齢制限、カテゴリ、著作権表記を登録

## 最終確認

- [ ] 新規ユーザー相当のMacアカウントで初回起動を確認
- [ ] 画面収録を拒否した場合の案内を確認
- [ ] 日本語・英語で主要画面を確認
- [ ] 全画面・ウインドウ・範囲撮影を確認
- [ ] 範囲録画の開始・停止・再生を確認
- [ ] Pictures保存、コピー、編集、削除を確認
- [ ] TestFlightまたは審査提出ビルドでクラッシュがないことを確認
