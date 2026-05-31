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

    @State private var availableWindows: [WindowDescriptor] = []
    @State private var windowFetchError: String?
    @State private var isRefreshingWindows = false

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

            Menu {
                windowMenuContents
            } label: {
                Label("ウィンドウ", systemImage: "macwindow")
            } primaryAction: {
                Task { await refreshWindows() }
            }
            .help("ウィンドウ指定キャプチャ (一覧を開く前にクリックして更新)")
            .disabled(isCapturing)
            .keyboardShortcut("3", modifiers: [.command, .shift])

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
        .task { await refreshWindows() }
    }

    // MARK: - Window menu

    @ViewBuilder
    private var windowMenuContents: some View {
        if isRefreshingWindows && availableWindows.isEmpty {
            Text("一覧を取得中…")
        } else if let err = windowFetchError {
            Text("一覧の取得に失敗: \(err)")
        } else if availableWindows.isEmpty {
            Text("対象ウィンドウなし (他のアプリのウィンドウを前面に出してから「一覧を更新」)")
        } else {
            ForEach(groupedWindows, id: \.appName) { group in
                Section(group.appName) {
                    ForEach(group.windows) { window in
                        Button {
                            Task { await runWindowCapture(window) }
                        } label: {
                            Text(window.title)
                        }
                    }
                }
            }
        }
        Divider()
        Button {
            Task { await refreshWindows() }
        } label: {
            Label("一覧を更新", systemImage: "arrow.clockwise")
        }
    }

    private var groupedWindows: [(appName: String, windows: [WindowDescriptor])] {
        let grouped = Dictionary(grouping: availableWindows, by: { $0.appName })
        return grouped
            .map { (appName: $0.key, windows: $0.value.sorted { $0.title < $1.title }) }
            .sorted { $0.appName < $1.appName }
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
    private func runWindowCapture(_ window: WindowDescriptor) async {
        isCapturing = true
        defer { isCapturing = false }
        guard await ensurePermission() else { return }

        do {
            let item = try await CaptureService.shared.captureWindow(id: window.id)
            historyStore.prepend(item)
            toolbarLog.info("captureWindow OK: \(item.fileURL.path, privacy: .public) title=\(window.title, privacy: .public)")
        } catch {
            handle(error: error)
            // ウィンドウが消えていた場合に備えて再取得しておく
            await refreshWindows()
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

    @MainActor
    private func refreshWindows() async {
        if isRefreshingWindows { return }
        isRefreshingWindows = true
        defer { isRefreshingWindows = false }
        do {
            let list = try await CaptureService.shared.listCapturableWindows()
            availableWindows = list
            windowFetchError = nil
            toolbarLog.info("refreshWindows OK count=\(list.count, privacy: .public)")
        } catch {
            availableWindows = []
            windowFetchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            toolbarLog.error("refreshWindows failed: \(String(describing: error), privacy: .public)")
        }
    }
}
