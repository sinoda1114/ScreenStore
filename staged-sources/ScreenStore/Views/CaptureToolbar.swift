import SwiftUI

struct CaptureToolbar: View {
    @EnvironmentObject private var historyStore: HistoryStore
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
        // Step 3 で CaptureService と結線して実装する
        lastError = "全画面キャプチャはまだ実装されていません (Step 3)。"
        showError = true
    }
}
