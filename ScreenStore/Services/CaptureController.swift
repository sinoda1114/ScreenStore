import SwiftUI
import AppKit
import CoreGraphics
import os.log

private let captureControllerLog = Logger(subsystem: "com.sinoda.ScreenStore", category: "capture-controller")

/// キャプチャ実行ロジックを `CaptureToolbar` とフローティングパレットの両方から
/// 共有するためのコントローラ。
///
/// 旧来 `CaptureToolbar` 内に閉じていた「permission チェック → CaptureService 呼び出し
/// → finishCapture (クリップボード即時書き込み → 履歴 prependAndSelect)」を集約する。
/// View からは `@ObservedObject` / `@EnvironmentObject` として参照し、`isCapturing` で
/// ボタンの disabled、`showError` / `lastError` でエラー表示を駆動する。
@MainActor
final class CaptureController: ObservableObject {
    /// キャプチャ進行中はボタンを無効化するためのフラグ。
    @Published var isCapturing = false
    @Published var isRecording = false
    @Published var delayedCaptureCountdown: Int?
    /// 直近のエラーメッセージ。`showError` と組み合わせて alert に出す。
    @Published var lastError: String?
    @Published var showError = false

    /// env オブジェクトはアプリ起動後に注入されるため弱参照で保持する。
    private weak var historyStore: HistoryStore?
    private weak var permission: ScreenRecordingPermission?
    private var recordingURL: URL?
    private var recordingPixelSize: CGSize = .zero
    private var recordingStartedAt: Date?

    /// `MainView.task` など env オブジェクトが用意できたタイミングで一度呼ぶ。
    func configure(historyStore: HistoryStore, permission: ScreenRecordingPermission) {
        self.historyStore = historyStore
        self.permission = permission
    }

    // MARK: - Capture actions

    func runFullScreen() async {
        isCapturing = true
        defer { isCapturing = false }
        guard await ensurePermission() else { return }

        do {
            let output = try await CaptureService.shared.captureFullScreen()
            finishCapture(output, kind: "captureFullScreen")
        } catch {
            handle(error: error)
        }
    }

    func runDelayedFullScreen(seconds: Int = 5) async {
        guard !isCapturing, !isRecording else { return }
        isCapturing = true
        defer {
            isCapturing = false
            delayedCaptureCountdown = nil
            CapturePaletteController.shared.hideCountdown()
        }
        guard await ensurePermission() else { return }

        for remaining in stride(from: max(seconds, 1), through: 1, by: -1) {
            delayedCaptureCountdown = remaining
            CapturePaletteController.shared.showCountdown(remaining)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        CapturePaletteController.shared.hide()
        CapturePaletteController.shared.hideCountdown()
        try? await Task.sleep(nanoseconds: 150_000_000)

        do {
            let output = try await CaptureService.shared.captureFullScreen()
            finishCapture(output, kind: "delayedFullScreen")
            CapturePaletteController.shared.showIfConfigured()
        } catch {
            handle(error: error)
            CapturePaletteController.shared.showIfConfigured()
        }
    }

    func runWindow() async {
        isCapturing = true
        defer { isCapturing = false }
        guard await ensurePermission() else { return }

        do {
            guard let filter = try await WindowSelectionController.shared.selectWindow() else {
                captureControllerLog.info("window capture cancelled by user")
                return
            }
            let output = try await CaptureService.shared.captureWindow(contentFilter: filter)
            finishCapture(output, kind: "captureWindow")
        } catch {
            handle(error: error)
        }
    }

    func runRegion() async {
        isCapturing = true
        defer { isCapturing = false }
        guard await ensurePermission() else { return }

        guard let selection = await RegionSelectionController.shared.selectRegion() else {
            captureControllerLog.info("region capture cancelled by user")
            return
        }

        // SCK 撮影前に念のため少し待つ (オーバーレイのフェードアウトを確実に画面から消すため)
        try? await Task.sleep(nanoseconds: 120_000_000)

        let displayID = CaptureService.displayID(for: selection.screen)
        let scale = selection.screen.backingScaleFactor
        let size = selection.screen.frame.size

        do {
            let output = try await CaptureService.shared.captureRegion(
                windowLocalRect: selection.rect,
                displayID: displayID,
                screenPointSize: size,
                backingScale: scale
            )
            finishCapture(output, kind: "captureRegion")
        } catch {
            handle(error: error)
        }
    }

    func toggleRegionRecording() async {
        if isRecording {
            await stopRegionRecording()
        } else {
            await startRegionRecording()
        }
    }

    /// 通常終了時に録画ファイルを確定してからアプリを閉じるための終了フック。
    func stopActiveRecordingForTermination() async {
        guard isRecording else { return }
        await stopRegionRecording()
    }

    private func startRegionRecording() async {
        guard !isCapturing, !isRecording else { return }
        isCapturing = true
        defer { isCapturing = false }
        guard await ensurePermission() else { return }

        guard let selection = await RegionSelectionController.shared.selectRegion() else {
            captureControllerLog.info("region recording cancelled by user")
            return
        }

        try? await Task.sleep(nanoseconds: 120_000_000)

        let displayID = CaptureService.displayID(for: selection.screen)
        guard selection.rect.width >= 1, selection.rect.height >= 1 else {
            handle(error: CaptureError.emptyRegion)
            return
        }

        do {
            try StorageService.shared.prepare()
            let url = StorageService.shared.nextVideoURL()
            let pixelSize = try await ScreenRecordingService.shared.start(
                selection: selection,
                displayID: displayID,
                outputURL: url
            )
            recordingURL = url
            recordingPixelSize = pixelSize
            recordingStartedAt = Date()
            isRecording = true
            captureControllerLog.info("region recording started: \(url.path, privacy: .public)")
        } catch {
            recordingURL = nil
            recordingPixelSize = .zero
            recordingStartedAt = nil
            handle(error: error)
        }
    }

    private func stopRegionRecording() async {
        guard let url = recordingURL else {
            isRecording = false
            return
        }

        recordingURL = nil
        isRecording = false

        do {
            try await ScreenRecordingService.shared.stop()
        } catch {
            try? FileManager.default.removeItem(at: url)
            recordingPixelSize = .zero
            recordingStartedAt = nil
            handle(error: error)
            return
        }

        guard FileManager.default.fileExists(atPath: url.path),
              ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else {
            try? FileManager.default.removeItem(at: url)
            recordingPixelSize = .zero
            recordingStartedAt = nil
            captureControllerLog.info("region recording stopped without output")
            return
        }

        let item = CaptureItem(
            fileURL: url,
            createdAt: recordingStartedAt ?? Date(),
            pixelSize: StorageService.readVideoPixelSize(from: url) ?? recordingPixelSize,
            captureMode: .regionRecording,
            mediaKind: .video
        )
        recordingPixelSize = .zero
        recordingStartedAt = nil
        historyStore?.prependAndSelect(item)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        captureControllerLog.info("region recording stopped: \(url.path, privacy: .public)")
    }

    // MARK: - Shared post-processing

    /// キャプチャ成功時の共通 後処理。
    /// 1. クリップボードを **最初に** 更新する (撮った瞬間にユーザーが ⌘Tab → ⌘V しても新しいものが貼られる)
    /// 2. 履歴の先頭に積み、新規行を単一選択状態にする (古い行を ⌘C で誤って拾う事故を防ぐ)
    /// PNG はメモリに既に存在するので、ファイル読み直しによるレイテンシは発生しない。
    private func finishCapture(_ output: CaptureOutput, kind: String) {
        PasteboardService.writePNG(
            data: output.pngData,
            fileURL: output.item.fileURL,
            to: .general
        )
        historyStore?.prependAndSelect(output.item)
        captureControllerLog.info("\(kind, privacy: .public) OK + auto-copied (\(output.pngData.count, privacy: .public) bytes): \(output.item.fileURL.path, privacy: .public)")
    }

    // MARK: - Helpers

    private func ensurePermission() async -> Bool {
        let preflight = CGPreflightScreenCaptureAccess()
        captureControllerLog.info("ensurePermission preflight=\(preflight, privacy: .public) pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public) app=\(Bundle.main.bundlePath, privacy: .public)")
        if preflight {
            permission?.refresh()
            return true
        }

        guard let permission else {
            lastError = (CaptureError.permissionDenied as LocalizedError).errorDescription
            showError = true
            return false
        }

        permission.refresh()
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        _ = permission.requestIfNeeded()
        lastError = (CaptureError.permissionDenied as LocalizedError).errorDescription
        showError = true
        return false
    }

    private func handle(error: Error) {
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        showError = true
        captureControllerLog.error("capture error: \(String(describing: error), privacy: .public)")
    }
}
