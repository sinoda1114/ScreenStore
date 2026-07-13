import SwiftUI
import AppKit

/// メインメニュー (`.commands`) と HistorySidebar とを橋渡しするための focused-value 群。
/// HistorySidebar 側でハンドラ closure を `.focusedSceneValue` で公開し、
/// CommandGroup 側がそれを拾って Cmd+C / Cmd+V のアクションを駆動する。

struct CopyImageHandlerKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct CutImageHandlerKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct PasteImageHandlerKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct DeleteImageHandlerKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var copyImageHandler: (() -> Void)? {
        get { self[CopyImageHandlerKey.self] }
        set { self[CopyImageHandlerKey.self] = newValue }
    }

    var cutImageHandler: (() -> Void)? {
        get { self[CutImageHandlerKey.self] }
        set { self[CutImageHandlerKey.self] = newValue }
    }

    var pasteImageHandler: (() -> Void)? {
        get { self[PasteImageHandlerKey.self] }
        set { self[PasteImageHandlerKey.self] = newValue }
    }

    var deleteImageHandler: (() -> Void)? {
        get { self[DeleteImageHandlerKey.self] }
        set { self[DeleteImageHandlerKey.self] = newValue }
    }
}

/// 編集メニューに「画像のコピー / 切り取り / ペースト / 削除」を差し込むコマンド。
/// HistorySidebar に選択がある時だけ Copy/Cut/Delete が有効になり、
/// HistorySidebar が描画されている間 Paste が有効になる。
struct ClipboardCommands: Commands {
    @FocusedValue(\.copyImageHandler)   private var copyHandler
    @FocusedValue(\.cutImageHandler)    private var cutHandler
    @FocusedValue(\.pasteImageHandler)  private var pasteHandler
    @FocusedValue(\.deleteImageHandler) private var deleteHandler

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button("画像をコピー") { copyHandler?() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(copyHandler == nil)

            Button("画像を切り取り") { cutHandler?() }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(cutHandler == nil)

            Button("画像をペースト") { pasteHandler?() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(pasteHandler == nil)

            Divider()

            Button("ゴミ箱に入れる") { deleteHandler?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(deleteHandler == nil)
        }
    }
}
