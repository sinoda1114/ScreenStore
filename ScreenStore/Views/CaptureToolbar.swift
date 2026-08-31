import SwiftUI
import AppKit

struct CaptureToolbar: View {
    @EnvironmentObject private var capture: CaptureController
    @EnvironmentObject private var shortcuts: ShortcutSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            Button {
                Task { await capture.runFullScreen() }
            } label: {
                Label("全画面", systemImage: "rectangle.dashed")
            }
            .help("全画面をキャプチャ (\(shortcuts.fullScreen.displayString))")
            .disabled(capture.isCapturing)
            .keyboardShortcut(shortcuts.fullScreen.keyEquivalent,
                              modifiers: shortcuts.fullScreen.swiftUIEventModifiers)

            Button {
                Task { await capture.runWindow() }
            } label: {
                Label("ウィンドウ", systemImage: "macwindow")
            }
            .help("ウィンドウ指定キャプチャ (\(shortcuts.window.displayString))")
            .disabled(capture.isCapturing)
            .keyboardShortcut(shortcuts.window.keyEquivalent,
                              modifiers: shortcuts.window.swiftUIEventModifiers)

            Button {
                Task { await capture.runRegion() }
            } label: {
                Label("切抜", systemImage: "selection.pin.in.out")
            }
            .help("選択範囲を切り抜き (\(shortcuts.region.displayString))")
            .disabled(capture.isCapturing)
            .keyboardShortcut(shortcuts.region.keyEquivalent,
                              modifiers: shortcuts.region.swiftUIEventModifiers)

            Button {
                Task { await capture.toggleRegionRecording() }
            } label: {
                Label(
                    capture.isRecording ? "停止" : "録画",
                    systemImage: capture.isRecording ? "stop.circle.fill" : "record.circle"
                )
            }
            .help(capture.isRecording ? "範囲録画を停止" : "選択範囲を録画")
            .disabled(capture.isCapturing && !capture.isRecording)

            Button {
                CapturePaletteController.shared.show(capture: capture, shortcuts: shortcuts)
            } label: {
                Label("パレット", systemImage: "rectangle.on.rectangle")
            }
            .help("フローティングキャプチャパレットを表示")

            Button {
                openSettingsWindow()
            } label: {
                Label("設定", systemImage: "gearshape")
            }
            .help("設定 (⌘,)")
        }
        .alert("キャプチャに失敗しました", isPresented: $capture.showError, presenting: capture.lastError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    /// 設定ウィンドウを開き、既存があれば最前面に持ってくる。
    private func openSettingsWindow() {
        openSettings()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
