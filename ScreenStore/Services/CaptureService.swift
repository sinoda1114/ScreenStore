import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

enum CaptureError: LocalizedError {
    case noDisplay
    case windowNotFound
    case emptyRegion
    case croppingFailed
    case permissionDenied
    case captureFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "利用可能なディスプレイが見つかりませんでした。"
        case .windowNotFound:
            return "対象のウィンドウが既に閉じられているか、共有可能ウィンドウから外れました。一覧を更新してから再度お試しください。"
        case .emptyRegion:
            return "選択範囲が空、もしくは画面外です。もう一度ドラッグしてやり直してください。"
        case .croppingFailed:
            return "画像の切り抜きに失敗しました。"
        case .permissionDenied:
            return """
            画面収録の許可が現在起動中の ScreenStore に紐づいていません。
            システム設定 > プライバシーとセキュリティ > 画面収録とシステムオーディオ録音 で ScreenStore を一度「−」で削除し、「＋」から /Applications/ScreenStore.app を追加し直してから ScreenStore を再起動してください。

            起動中のアプリ: \(Bundle.main.bundlePath)
            """
        case .captureFailed(let err):
            let nsError = err as NSError
            return "キャプチャ処理に失敗しました: \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
        }
    }
}

/// SwiftUI 側で表示するために SCWindow から必要なフィールドだけ抜いた Sendable な値型。
struct WindowDescriptor: Identifiable, Sendable, Hashable {
    let id: CGWindowID
    let title: String
    let appName: String
    let bundleIdentifier: String?
    let frame: CGRect
}

/// キャプチャ結果。`item` は履歴用、`pngData` は同じ内容のバイト列で
/// 「クリップボードへの即時貼り付け」に使う。ディスクから読み直すレイテンシを避けるため。
struct CaptureOutput {
    let item: CaptureItem
    let pngData: Data
}

final class CaptureService {
    static let shared = CaptureService()

    /// 自前で除外したい bundle ID (= ScreenStore 自身)。
    private static let ownBundleIdentifier = "com.sinoda.ScreenStore"

    /// SCShareableContent.excludingDesktopWindows は macOS 14+ で 0.5〜2 秒かかることがあり、
    /// 連続キャプチャの体感レスポンスを大きく落とす。短時間のキャッシュで 2 発目以降を高速化する。
    private var displaysCache: (displays: [SCDisplay], at: Date)?
    private static let displaysCacheTTL: TimeInterval = 5.0

    private init() {}

    // MARK: - Full screen

    /// メインディスプレイの全画面を PNG として保存し、CaptureOutput を返す。
    /// アプリ自身のウィンドウは一時的に隠して写り込みを避ける。
    func captureFullScreen() async throws -> CaptureOutput {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }

        await hideOwnWindows()
        // ウィンドウを完全にフェードアウトさせるための待ち。最低限を狙って 150ms に短縮。
        try? await Task.sleep(nanoseconds: 150_000_000)

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

        // PNG をメモリで 1 回だけエンコードし、ディスクとクリップボードで使い回す。
        let pngData = try StorageService.shared.encodePNGData(cgImage)
        let url = StorageService.shared.nextImageURL()
        try StorageService.shared.writePNGData(pngData, to: url)

        let item = CaptureItem(
            fileURL: url,
            createdAt: Date(),
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height),
            captureMode: .full
        )
        return CaptureOutput(item: item, pngData: pngData)
    }

    // MARK: - Window picker

    /// 共有可能ウィンドウ一覧を取得し、UI 表示用の WindowDescriptor 配列を返す。
    /// ScreenStore 自身のウィンドウ・layer != 0・画面外・タイトル空は除外する。
    func listCapturableWindows() async throws -> [WindowDescriptor] {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.captureFailed(error)
        }

        return content.windows.compactMap { window -> WindowDescriptor? in
            guard window.windowLayer == 0 else { return nil }
            guard window.isOnScreen else { return nil }
            guard let title = window.title, !title.isEmpty else { return nil }
            let bundleID = window.owningApplication?.bundleIdentifier
            if bundleID == Self.ownBundleIdentifier { return nil }
            let appName = window.owningApplication?.applicationName ?? "(不明なアプリ)"
            return WindowDescriptor(
                id: window.windowID,
                title: title,
                appName: appName,
                bundleIdentifier: bundleID,
                frame: window.frame
            )
        }
        .sorted { lhs, rhs in
            if lhs.appName != rhs.appName { return lhs.appName < rhs.appName }
            return lhs.title < rhs.title
        }
    }

    // MARK: - Window capture

    /// 指定 windowID のウィンドウだけを SCK でキャプチャする。
    /// SCContentFilter(desktopIndependentWindow:) を使うので、ウィンドウが画面上で
    /// 他に隠されていても直接コンテンツを取得できる (ScreenStore のウィンドウを隠す必要はない)。
    func captureWindow(id windowID: CGWindowID) async throws -> CaptureItem {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.captureFailed(error)
        }

        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }

        let cgImage = try await captureImage(of: window)

        let url = StorageService.shared.nextImageURL()
        try StorageService.shared.writePNG(cgImage, to: url)

        return CaptureItem(
            fileURL: url,
            createdAt: Date(),
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height),
            captureMode: .window
        )
    }

    // MARK: - Interactive window picker (macOS 標準スタイル)

    /// `/usr/sbin/screencapture -W` を呼び、macOS 標準の「カメラカーソル → ホバーで光る → クリックで撮る」
    /// 体験そのままで 1 ウィンドウを撮影する。
    /// ユーザーが ESC で抜けたとき (= ファイルが作られなかったとき) は nil を返す。
    func captureSelectedWindowInteractive() async throws -> CaptureOutput? {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }

        try StorageService.shared.prepare()
        let outURL = StorageService.shared.nextImageURL()

        // ScreenStore 自身が選択肢に並ばないよう一旦隠す
        await hideOwnWindows()
        defer {
            Task { @MainActor in
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // ウィンドウフェード分を 150ms に短縮 (ScreenStore は単一ウィンドウなので元から軽い)
        try? await Task.sleep(nanoseconds: 150_000_000)

        try await runScreencaptureCLI(arguments: [
            "-W",                // ウィンドウ選択モード
            "-o",                // ウィンドウシャドウなし (Sprint 1 と同じ方針)
            "-x",                // 撮影音を鳴らさない
            outURL.path
        ])

        // ESC でキャンセルされた場合はファイルが作られない
        guard FileManager.default.fileExists(atPath: outURL.path) else {
            return nil
        }

        // ファイル本体は CLI が書いている。今回は 1 度だけ読んで pixelSize と pasteboard 用 PNG の両方を満たす。
        let pngData = (try? Data(contentsOf: outURL)) ?? Data()
        let pixelSize = PasteboardService.pixelSize(forPNG: pngData)
            ?? StorageService.readPixelSize(from: outURL) ?? .zero
        let item = CaptureItem(
            fileURL: outURL,
            createdAt: Date(),
            pixelSize: pixelSize,
            captureMode: .window
        )
        return CaptureOutput(item: item, pngData: pngData)
    }

    /// `/usr/sbin/screencapture` をサブプロセスとして起動し、終了まで待つ。
    /// メインスレッドをブロックしないよう terminationHandler ベースで継続を返す。
    private func runScreencaptureCLI(arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = arguments
            process.terminationHandler = { _ in
                cont.resume()
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: CaptureError.captureFailed(error))
            }
        }
    }

    // MARK: - Region capture

    /// 指定スクリーン (= displayID) の上で選択された矩形をキャプチャする。
    ///
    /// - Parameters:
    ///   - rect: 透過オーバーレイ NSWindow ローカル座標 (左下原点 / point)。
    ///           オーバーレイが NSScreen.frame と一致している前提なので、画面ローカル座標と等価。
    ///   - displayID: 対象 NSScreen の `NSScreenNumber` から得た CGDirectDisplayID
    ///   - screenPointSize: NSScreen.frame.size (point)
    ///   - backingScale: NSScreen.backingScaleFactor
    ///
    /// 呼び出し側 (RegionSelectionController など) がオーバーレイを必ず orderOut してから呼ぶこと。
    func captureRegion(
        windowLocalRect rect: CGRect,
        displayID: CGDirectDisplayID,
        screenPointSize: CGSize,
        backingScale: CGFloat
    ) async throws -> CaptureOutput {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
        guard rect.width > 0, rect.height > 0 else {
            throw CaptureError.emptyRegion
        }

        let display = try await fetchDisplay(matching: displayID)
        let fullImage = try await captureImage(of: display)

        let pixelRect = RegionMath.pixelCropRect(
            windowLocalRect: rect,
            windowSize: screenPointSize,
            backingScale: backingScale
        )
        let clamped = RegionMath.clamp(
            rect: pixelRect,
            to: CGSize(width: fullImage.width, height: fullImage.height)
        )
        guard clamped.width >= 1, clamped.height >= 1 else {
            throw CaptureError.emptyRegion
        }

        guard let cropped = fullImage.cropping(to: clamped) else {
            throw CaptureError.croppingFailed
        }

        let pngData = try StorageService.shared.encodePNGData(cropped)
        let url = StorageService.shared.nextImageURL()
        try StorageService.shared.writePNGData(pngData, to: url)

        let item = CaptureItem(
            fileURL: url,
            createdAt: Date(),
            pixelSize: CGSize(width: cropped.width, height: cropped.height),
            captureMode: .region
        )
        return CaptureOutput(item: item, pngData: pngData)
    }

    // MARK: - Internal helpers

    @MainActor
    private func hideOwnWindows() {
        NSApp.hide(nil)
    }

    private func fetchMainDisplay() async throws -> SCDisplay {
        try await fetchDisplay(matching: CGMainDisplayID())
    }

    private func fetchDisplay(matching displayID: CGDirectDisplayID?) async throws -> SCDisplay {
        let displays = try await fetchDisplays()
        guard !displays.isEmpty else {
            throw CaptureError.noDisplay
        }

        if let displayID, let match = displays.first(where: { $0.displayID == displayID }) {
            return match
        }
        if let main = displays.first(where: { $0.displayID == CGMainDisplayID() }) {
            return main
        }
        if let first = displays.first {
            return first
        }
        throw CaptureError.noDisplay
    }

    /// 表示中ディスプレイ一覧を 5 秒キャッシュ。
    /// `SCShareableContent.excludingDesktopWindows` が hot path で 0.5〜2 秒かかる問題への対策。
    /// 連続キャプチャの 2 発目以降はキャッシュヒットでほぼ 0ms。
    /// SCK 撮影に失敗したらキャッシュは破棄するので、ディスプレイ構成が変わっても次回で復帰する。
    private func fetchDisplays() async throws -> [SCDisplay] {
        if let cache = displaysCache,
           Date().timeIntervalSince(cache.at) < Self.displaysCacheTTL,
           !cache.displays.isEmpty {
            return cache.displays
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.captureFailed(error)
        }
        displaysCache = (content.displays, Date())
        return content.displays
    }

    /// SCK 撮影に失敗したときにキャッシュを破棄する hook。
    private func invalidateDisplaysCache() {
        displaysCache = nil
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
            // ディスプレイが変わっている可能性があるのでキャッシュは捨てる。
            invalidateDisplaysCache()
            throw CaptureError.captureFailed(error)
        }
    }

    /// SCWindow 用。SCContentFilter(desktopIndependentWindow:) が提供する
    /// `pointPixelScale` と `contentRect` を使って Retina 解像度のままキャプチャする。
    private func captureImage(of window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let scale = CGFloat(filter.pointPixelScale)
        let widthPts = filter.contentRect.width
        let heightPts = filter.contentRect.height
        let pixelWidth = max(1, Int((widthPts * scale).rounded()))
        let pixelHeight = max(1, Int((heightPts * scale).rounded()))

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.scalesToFit = false
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true

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

    /// NSScreen → CGDirectDisplayID。`NSScreenNumber` がデバイス記述から取れるはず。
    @MainActor
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        return CGMainDisplayID()
    }
}
