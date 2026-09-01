# ScreenStore App Store 公開計画

## Goal

ScreenStore を無料の macOS アプリとして Mac App Store で検索・インストールできる状態にする。日本語と英語に対応し、画像・録画・設定は端末内だけで扱い、解析やトラッキングは導入しない。

## Target Files

- `ScreenStore.xcodeproj/project.pbxproj`: Sandbox、Hardened Runtime、ローカライズ、リソース設定
- `ScreenStore/ScreenStore.entitlements`: 写真フォルダとユーザー選択ファイルへの権限
- `ScreenStore/PrivacyInfo.xcprivacy`: プライバシーマニフェスト
- `ScreenStore/ScreenStoreApp.swift`: 他アプリの設定変更を廃止
- `ScreenStore/Services/CaptureController.swift`: 新しいウインドウ撮影・範囲録画フローへの接続
- `ScreenStore/Services/CaptureService.swift`: ScreenCaptureKit による撮影処理
- `ScreenStore/Services/WindowSelectionController.swift`: ScreenCaptureKitを使った直接クリック型ウインドウ選択オーバーレイ
- `ScreenStore/Services/ScreenRecordingService.swift`: ScreenCaptureKit と AVFoundation による録画
- `ScreenStore/Services/VideoSpeedExportService.swift`: 外部 `ffmpeg` 依存の廃止
- `ScreenStore/Localizable.xcstrings`: 日本語・英語の表示文言
- `ScreenStore/InfoPlist.xcstrings`: 画面収録権限説明の日本語・英語化
- `ScreenStoreTests/`: 新しいサービスと設定のテスト
- `docs/app-store/`: プライバシーポリシー、サポート、掲載文、審査メモ

## Steps

1. 公開用ブランチと本計画を作成する。— 検証: `git status` で既存の未追跡ファイルが混入していないことを確認する。
2. App Sandbox と Hardened Runtime を有効化し、Pictures とユーザー選択ファイルへの最小権限を設定する。他アプリの設定変更と Homebrew `ffmpeg` 参照を廃止し、プライバシーマニフェストを追加する。— 検証: Debug/Release のビルド設定、署名済みアプリの entitlements、単体テストを確認する。
3. `/usr/sbin/screencapture -W` を廃止し、ScreenCaptureKitとAppKitによる直接クリック型の単一ウインドウ撮影へ置き換える。外部コマンド、Accessibility API、private APIは使わない。— 検証: 複数画面でのホバー表示、クリック選択、Esc・右クリックのキャンセル、PNG保存、履歴追加、クリップボードを手動確認する。
4. `/usr/sbin/screencapture -v` を廃止し、ScreenCaptureKit と AVFoundation による範囲録画に置き換える。— 検証: 開始・停止・キャンセル、複数ディスプレイ、音声なし動画、速度変更書き出しを確認する。
5. SwiftUI とエラー表示を日本語・英語へローカライズする。— 検証: macOS の優先言語を日本語・英語に切り替え、主要画面と権限ダイアログを確認する。
6. App Store Connect 用の掲載文、プライバシーポリシー、サポートページ、審査メモ、スクリーンショット構成を作る。— 検証: URL、連絡先、機能説明、データ収集なしの申告がアプリの実装と一致することを確認する。
7. Release Archive を作成し、Validate App と TestFlight 相当の配布確認を経て提出する。— 検証: Xcode Organizer の Validate App が成功し、実機相当環境で初回権限から保存まで確認する。

## Dependencies

- 手順3と4は手順2の Sandbox 方針に依存する。
- 手順5の翻訳対象は手順3と4で追加するUIが確定してから仕上げる。
- Archive の署名と App Store Connect 登録には Apple Developer Program の有効化、Team ID、契約同意が必要。
- App Store のアプリ名は App Store Connect で新規アプリを作成する時点で空きを確認する。

## Test Plan

- 自動: `xcodebuild` による Debug/Release ビルド、`ScreenStoreTests`、`git diff --check`
- 権限: 画面収録を未許可・許可済み・拒否後の3状態で確認
- Sandbox: Pictures への保存、NSSavePanel で選択した場所への書き出し、それ以外への不正アクセスがないことを確認
- 撮影: 全画面、ウインドウ、範囲、キャンセル、複数ディスプレイを確認
- 録画: 開始・停止・失敗復旧、再生、速度変更、ファイル破損がないことを確認
- 言語: 日本語と英語で切れ・未翻訳・レイアウト崩れがないことを確認
- 審査: Archive のプライバシーレポート、署名、entitlements、Validate App の結果を確認

## Rollback Plan

- 各段階を独立したコミットに分け、問題のある段階だけを戻せるようにする。
- Sandbox 有効化で既存保存先が使えない場合は、Sandbox 自体を解除せず、ユーザー選択フォルダと security-scoped bookmark に切り替える。
- 新録画処理が安定しない場合は、App Store 初版では録画ボタンを明示的に無効化し、撮影機能のみで提出する。外部コマンド方式には戻さない。
- App Store 提出後に重大な問題が見つかった場合は、そのビルドを提出対象から外し、修正版のビルド番号を上げて再提出する。

## Definition of Done

- Mac App Store 用の署名付き Archive を作成でき、Validate App が成功する。
- アプリが App Sandbox 内で全画面・ウインドウ・範囲撮影と範囲録画を完結できる。
- Homebrew、外部実行ファイル、他アプリの設定変更に依存しない。
- 日本語・英語の主要導線と権限説明が揃っている。
- App Store Connect のプライバシー申告、掲載情報、スクリーンショット、サポートURLを登録できる。
- 初回起動から撮影・保存・再起動後の履歴表示までを公開候補ビルドで確認できる。
