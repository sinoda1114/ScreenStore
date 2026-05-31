import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

enum CaptureError: LocalizedError {
    case noDisplay
    case permissionDenied
    case captureFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "利用可能なディスプレイが見つかりませんでした。"
        case .permissionDenied:
            return "画面収録の許可がありません。システム設定 > プライバシーとセキュリティ > 画面収録 で ScreenStore を有効にしてください。"
        case .captureFailed(let err):
            return "キャプチャに失敗しました: \(err.localizedDescription)"
        }
    }
}

final class CaptureService {
    static let shared = CaptureService()

    private init() {}

    /// メインディスプレイの全画面を PNG として保存し、CaptureItem を返す。
    /// アプリ自身のウィンドウは一時的に隠して写り込みを避ける。
    func captureFullScreen() async throws -> CaptureItem {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }

        await hideOwnWindows()
        try? await Task.sleep(nanoseconds: 300_000_000)

        let unhide: () -> Void = {
            Task { @MainActor in
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        let cgImage: CGImage
        do {
            let display = try await fetchMainDisplay()
            cgImage = try await captureImage(of: display)
        } catch {
            unhide()
            if let captureError = error as? CaptureError {
                throw captureError
            }
            throw CaptureError.captureFailed(error)
        }
        unhide()

        let url = StorageService.shared.nextImageURL()
        try StorageService.shared.writePNG(cgImage, to: url)

        return CaptureItem(
            fileURL: url,
            createdAt: Date(),
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height),
            captureMode: .full
        )
    }

    @MainActor
    private func hideOwnWindows() {
        NSApp.hide(nil)
    }

    private func fetchMainDisplay() async throws -> SCDisplay {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.captureFailed(error)
        }

        guard !content.displays.isEmpty else {
            throw CaptureError.noDisplay
        }

        let mainID = CGMainDisplayID()
        if let main = content.displays.first(where: { $0.displayID == mainID }) {
            return main
        }
        if let first = content.displays.first {
            return first
        }
        throw CaptureError.noDisplay
    }

    private func captureImage(of display: SCDisplay) async throws -> CGImage {
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let scale = await scaleFactor(for: display.displayID)
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.scalesToFit = false
        config.showsCursor = false
        config.capturesAudio = false

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw CaptureError.captureFailed(error)
        }
    }

    @MainActor
    private func scaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }) {
            return screen.backingScaleFactor
        }
        return NSScreen.main?.backingScaleFactor ?? 2.0
    }
}
