import SwiftUI
import AppKit
import Carbon.HIToolbox

struct SettingsView: View {
    enum Tab: Hashable { case general, shortcuts }
    @State private var selection: Tab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView()
                .tabItem { Label("一般", systemImage: "gear") }
                .tag(Tab.general)
            ShortcutSettingsTab()
                .tabItem { Label("ショートカット", systemImage: "keyboard") }
                .tag(Tab.shortcuts)
        }
        .frame(width: 520, height: 320)
    }
}

// MARK: - 一般タブ

private struct GeneralSettingsView: View {
    @State private var savePath: String = StorageService.shared.imagesDirectory.path

    var body: some View {
        Form {
            Section {
                LabeledContent("保存先フォルダ") {
                    HStack(spacing: 8) {
                        Text(savePath)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Finder で開く") { openSaveFolder() }
                    }
                }
            } header: {
                Text("保存先")
            } footer: {
                Text("撮影した PNG はすべてこのフォルダ配下に保存されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private func openSaveFolder() {
        let url = StorageService.shared.imagesDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - ショートカットタブ

private struct ShortcutSettingsTab: View {
    @EnvironmentObject private var shortcuts: ShortcutSettings

    var body: some View {
        Form {
            Section {
                ShortcutRow(label: "全画面キャプチャ", key: .fullScreen)
                ShortcutRow(label: "ウィンドウキャプチャ", key: .window)
                ShortcutRow(label: "範囲キャプチャ", key: .region)
            } footer: {
                Text("欄をクリックして任意のキー組み合わせを入力してください。Esc で取消、「既定」ボタンで初期値に戻します。Cmd+Shift+数字などプロセス内で動くショートカットのみ対応 (グローバルホットキーは Sprint 4 以降)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private struct ShortcutRow: View {
    let label: String
    let key: ShortcutSettings.Key
    @EnvironmentObject private var shortcuts: ShortcutSettings

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                ShortcutRecorderView(spec: binding)
                    .frame(width: 160, height: 22)
                Button("既定") { shortcuts.reset(key) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var binding: Binding<KeyboardShortcutSpec> {
        Binding(
            get: { shortcuts.spec(for: key) },
            set: { shortcuts.update(key, spec: $0) }
        )
    }
}

// MARK: - ショートカット記録 NSViewRepresentable

private struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var spec: KeyboardShortcutSpec

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let view = ShortcutRecorderButton()
        view.specProvider = { spec }
        view.onCommit = { newSpec in
            DispatchQueue.main.async { spec = newSpec }
        }
        view.refreshTitle()
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.specProvider = { spec }
        nsView.refreshTitle()
    }
}

final class ShortcutRecorderButton: NSButton {
    var specProvider: (() -> KeyboardShortcutSpec)?
    var onCommit: ((KeyboardShortcutSpec) -> Void)?

    private var isRecording = false
    private var localMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        target = self
        action = #selector(handleClick(_:))
        focusRingType = .default
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    deinit {
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }

    override var acceptsFirstResponder: Bool { true }

    func refreshTitle() {
        if isRecording {
            title = "押してください…"
        } else {
            title = specProvider?().displayString ?? ""
        }
    }

    @objc private func handleClick(_ sender: Any?) {
        startRecording()
    }

    override func resignFirstResponder() -> Bool {
        stopRecording(commit: nil)
        return super.resignFirstResponder()
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        refreshTitle()
        window?.makeFirstResponder(self)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    /// keyDown を消費したら true を返す。
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        // Esc → 取消
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording(commit: nil)
            return true
        }

        let mods = event.modifierFlags.intersection(KeyboardShortcutSpec.relevantMask)
        // modifier が一つもないキーは弾く
        guard !mods.isEmpty else { return true }

        // Shift で文字が大文字や記号に変わるのを避けるため、UCKeyTranslate で
        // modifier 無視の "ベース文字" を取り直す。
        guard let baseChar = KeyboardLayoutHelper.baseCharacter(forKeyCode: event.keyCode) else {
            return true
        }
        let newSpec = KeyboardShortcutSpec(keyCharacter: baseChar.lowercased(),
                                           modifierFlags: mods.rawValue)
        guard newSpec.isValid else { return true }

        stopRecording(commit: newSpec)
        return true
    }

    private func stopRecording(commit: KeyboardShortcutSpec?) {
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
        isRecording = false
        if let commit { onCommit?(commit) }
        refreshTitle()
    }
}

/// US/JIS どちらでも「シフト・modifier を無視した素の文字」を取得するための薄いラッパ。
/// Sprint 3 のショートカット記録器がシフト+数字 → 記号 ("@" など) を保存しないようにするためだけに使う。
enum KeyboardLayoutHelper {
    static func baseCharacter(forKeyCode keyCode: UInt16) -> String? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = unsafeBitCast(layoutPointer, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let keyboardLayout = unsafeBitCast(bytes, to: UnsafePointer<UCKeyboardLayout>.self)

        var deadKeyState: UInt32 = 0
        var chars: [UniChar] = Array(repeating: 0, count: 4)
        var length = 0

        let status = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDown),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

#Preview {
    SettingsView()
        .environmentObject(ShortcutSettings())
}
