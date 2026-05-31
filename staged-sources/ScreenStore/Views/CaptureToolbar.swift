import SwiftUI

struct CaptureToolbar: View {
    @EnvironmentObject private var historyStore: HistoryStore
    @EnvironmentObject private var permission: ScreenRecordingPermission
    @State private var isCapturing = false
    @State private var lastError: String?
    @State private var showError = false

    var body: some View {
        Group {
            Button {
                Task { await runFullScreenCapture() }
            } label: {
                Label("全画面", systemImage: "rectangle.dashed")
            }
            .help("全画面をキャプチャ")
            .disabled(isCapturing)
            .keyboardShortcut("2", modifiers: [.command, .shift])

            Button {
                // 次スプリント: ウィンドウ指定
            } label: {
                Label("ウィンドウ", systemImage: "macwindow")
            }
            .help("ウィンドウ指定キャプチャ (次スプリント実装予定)")
            .disabled(true)

            Button {
                // 次スプリント: 範囲指定
            } label: {
                Label("範囲", systemImage: "selection.pin.in.out")
            }
            .help("自由範囲キャプチャ (次スプリント実装予定)")
            .disabled(true)
        }
        .alert("キャプチャに失敗しました", isPresented: $showError, presenting: lastError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    @MainActor
    private func runFullScreenCapture() async {
        isCapturing = true
        defer { isCapturing = false }

        if !permission.isGranted {
            permission.refresh()
            if !permission.isGranted {
                let granted = permission.requestIfNeeded()
                if !granted {
                    permission.openSystemSettings()
                    lastError = (CaptureError.permissionDenied as LocalizedError).errorDescription
                    showError = true
                    return
                }
            }
        }

        do {
            let item = try await CaptureService.shared.captureFullScreen()
            historyStore.prepend(item)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showError = true
        }
    }
}
