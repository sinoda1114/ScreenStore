import SwiftUI
import AppKit
import Carbon.HIToolbox
import os.log

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
    @AppStorage(AppPreferenceKeys.capturePaletteBackgroundOpacity)
    private var paletteBackgroundOpacity = AppPreferenceKeys.defaultCapturePaletteBackgroundOpacity

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

            Section {
                LabeledContent("フローティングパレット") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { paletteBackgroundOpacity },
                                set: { paletteBackgroundOpacity = min(max($0, 0.35), 1) }
                            ),
                            in: 0.35...1,
                            step: 0.05
                        )
                        .frame(width: 180)

                        Text("\(Int((paletteBackgroundOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            } header: {
                Text("表示")
            } footer: {
                Text("数値を下げるほど背景が透けます。アイコンと文字は読みやすさを優先して濃く表示します。")
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
    private static let log = Logger(subsystem: "com.sinoda.ScreenStore", category: "shortcut-recorder")

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

    /// 記録中は performKeyEquivalent をここで横取りして消費する。
    /// performKeyEquivalent は key window のビュー階層を menu より先に降りてくるため、
    /// Cmd 系コンボ (ツールバーの ⌘⇧2/3/4 や ClipboardCommands の ⌘C/X/V/⌘⌫) が
    /// menu の key equivalent に食われる前に記録器へ届く。これが「設定できない」根本原因への対策。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecording {
            Self.log.info("performKeyEquivalent(recording) keyCode=\(event.keyCode, privacy: .public) mods=\(event.modifierFlags.rawValue, privacy: .public)")
            return consumeRecordingEvent(event)
        }
        return super.performKeyEquivalent(with: event)
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        refreshTitle()
        window?.makeFirstResponder(self)
        Self.log.info("startRecording")
        // performKeyEquivalent で来ない経路 (modifier 無しのキー等) の保険として keyDown モニタも併用する。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            Self.log.info("keyDown monitor keyCode=\(event.keyCode, privacy: .public) mods=\(event.modifierFlags.rawValue, privacy: .public)")
            return self.consumeRecordingEvent(event) ? nil : event
        }
    }

    /// 記録中のキーイベントを解釈し、消費したら true を返す。
    /// performKeyEquivalent と keyDown モニタの両方から呼ばれる。
    private func consumeRecordingEvent(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        // Esc → 取消
        if event.keyCode == UInt16(kVK_Escape) {
            Self.log.info("cancel(Esc)")
            stopRecording(commit: nil)
            return true
        }

        let mods = event.modifierFlags.intersection(KeyboardShortcutSpec.relevantMask)
        // modifier が一つもないキーは弾く (記録中なので消費はする)
        guard !mods.isEmpty else { return true }

        // Shift で文字が大文字や記号に変わるのを避けるため、UCKeyTranslate で
        // modifier 無視の "ベース文字" を取り直す。
        guard let baseChar = KeyboardLayoutHelper.baseCharacter(forKeyCode: event.keyCode) else {
            return true
        }
        let newSpec = KeyboardShortcutSpec(keyCharacter: baseChar.lowercased(),
                                           modifierFlags: mods.rawValue)
        guard newSpec.isValid else { return true }

        Self.log.info("commit spec=\(newSpec.displayString, privacy: .public)")
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
        guard let layoutData = currentUnicodeLayoutData(),
              let bytes = CFDataGetBytePtr(layoutData) else { return nil }
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

    /// 現在の入力ソースから uchr (Unicode キーレイアウト) データを取り出す。
    ///
    /// `TISCopyCurrentKeyboardInputSource()` は日本語などの IME がアクティブな間は
    /// その IME 自体を返し、`kTISPropertyUnicodeKeyLayoutData` が nil になる。
    /// すると `baseCharacter(forKeyCode:)` が常に nil を返し、記録器がどのキーも
    /// commit できず「押してください…」のまま固まる (= 任意キーを設定できない不具合)。
    /// レイアウト用 / ASCII 対応の入力ソースへ段階的にフォールバックして必ず uchr を得る。
    private static func currentUnicodeLayoutData() -> CFData? {
        let candidates: [TISInputSource?] = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        ]
        for source in candidates {
            guard let source,
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { continue }
            return unsafeBitCast(pointer, to: CFData.self)
        }
        return nil
    }
}

#Preview {
    SettingsView()
        .environmentObject(ShortcutSettings())
}
