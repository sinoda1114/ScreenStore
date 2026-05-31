import SwiftUI
import AppKit
import os.log

private let toolbarLog = Logger(subsystem: "com.sinoda.ScreenStore", category: "toolbar")

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
                Task { await runWindowCapture() }
            } label: {
                Label("ウィンドウ", systemImage: "macwindow")
            }
            .help("ウィンドウ指定キャプチャ (画面上のウィンドウをクリックで選択 / ESC でキャンセル)")
            .disabled(isCapturing)
            .keyboardShortcut("3", modifiers: [.command, .shift])

            Button {
                Task { await runRegionCapture() }
            } label: {
                Label("範囲", systemImage: "selection.pin.in.out")
            }
            .help("自由範囲キャプチャ (ドラッグで矩形選択 / ESC でキャンセル)")
            .disabled(isCapturing)
            .keyboardShortcut("4", modifiers: [.command, .shift])
        }
        .alert("キャプチャに失敗しました", isPresented: $showError, presenting: lastError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Capture actions

    @MainActor
    private func runFullScreenCapture() async {
        isCapturing = true
        defer { isCapturing = false }
        guard await ensurePermission() else { return }

        do {
            let item = try await CaptureService.shared.captureFullScreen()
            historyStore.prepend(item)
            toolbarLog.info("captureFullScreen OK: \(item.fileURL.path, privacy: .public)")
        } catch {
            handle(error: error)
        }
    }

    @MainActor
    private func runWindowCapture() async {
        isCapturing = true
        defer { isCapturing = false }
        guard await ensurePermission() else { return }

        do {
            // macOS 標準の `screencapture -W` を使ってインタラクティブにウィンドウを選ばせる。
            // ESC でキャンセルされた場合は nil が返る。
            guard let item = try await CaptureService.shared.captureSelectedWindowInteractive() else {
                toolbarLog.info("window capture cancelled by user")
                return
            }
            historyStore.prepend(item)
            toolbarLog.info("captureSelectedWindow OK: \(item.fileURL.path, privacy: .public)")
        } catch {
            handle(error: error)
        }
    }

    @MainActor
    private func runRegionCapture() async {
        isCapturing = true
        defer { isCapturing = false }
        guard await ensurePermission() else { return }

        guard let selection = await RegionSelectionController.shared.selectRegion() else {
            toolbarLog.info("region capture cancelled by user")
            return
        }

        // SCK 撮影前に念のため少し待つ (オーバーレイのフェードアウトを確実に画面から消すため)
        try? await Task.sleep(nanoseconds: 120_000_000)

        let displayID = CaptureService.displayID(for: selection.screen)
        let scale = selection.screen.backingScaleFactor
        let size = selection.screen.frame.size

        do {
            let item = try await CaptureService.shared.captureRegion(
                windowLocalRect: selection.rect,
                displayID: displayID,
                screenPointSize: size,
                backingScale: scale
            )
            historyStore.prepend(item)
            toolbarLog.info("captureRegion OK: \(item.fileURL.path, privacy: .public) rect=\(NSStringFromRect(selection.rect), privacy: .public)")
        } catch {
            handle(error: error)
        }
    }

    // MARK: - Helpers

    @MainActor
    private func ensurePermission() async -> Bool {
        if permission.isGranted { return true }
        permission.refresh()
        if permission.isGranted { return true }
        let granted = permission.requestIfNeeded()
        if granted { return true }
        permission.openSystemSettings()
        lastError = (CaptureError.permissionDenied as LocalizedError).errorDescription
        showError = true
        return false
    }

    @MainActor
    private func handle(error: Error) {
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        showError = true
        toolbarLog.error("capture error: \(String(describing: error), privacy: .public)")
    }
}
