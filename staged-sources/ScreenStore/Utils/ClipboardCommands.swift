import SwiftUI
import AppKit

/// メインメニュー (`.commands`) と HistorySidebar とを橋渡しするための focused-value 群。
/// HistorySidebar 側でハンドラ closure を `.focusedSceneValue` で公開し、
/// CommandGroup 側がそれを拾って Cmd+C / Cmd+V のアクションを駆動する。

struct CopyImageHandlerKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct PasteImageHandlerKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var copyImageHandler: (() -> Void)? {
        get { self[CopyImageHandlerKey.self] }
        set { self[CopyImageHandlerKey.self] = newValue }
    }

    var pasteImageHandler: (() -> Void)? {
        get { self[PasteImageHandlerKey.self] }
        set { self[PasteImageHandlerKey.self] = newValue }
    }
}

/// 編集メニューに「画像のコピー / ペースト」を差し込むコマンド。
/// HistorySidebar に選択がある時だけ Copy が有効になり、
/// HistorySidebar が描画されている (= 通常起動の単一ウィンドウ) 間 Paste が有効になる。
struct ClipboardCommands: Commands {
    @FocusedValue(\.copyImageHandler)  private var copyHandler
    @FocusedValue(\.pasteImageHandler) private var pasteHandler

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button("画像をコピー") { copyHandler?() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(copyHandler == nil)

            Button("画像をペースト") { pasteHandler?() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(pasteHandler == nil)
        }
    }
}
