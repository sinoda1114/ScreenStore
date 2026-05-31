import SwiftUI
import AppKit
import ScreenCaptureKit
import os.log

private let appLog = Logger(subsystem: "com.sinoda.ScreenStore", category: "app")

@main
struct ScreenStoreApp: App {
    @StateObject private var historyStore = HistoryStore()
    @StateObject private var permission = ScreenRecordingPermission()

    init() {
        if CommandLine.arguments.contains("--register-tcc") {
            Self.registerWithTCC()
        }
        if CommandLine.arguments.contains("--smoke-capture") {
            Self.runSmokeCapture()
        }
        if CommandLine.arguments.contains("--smoke-window") {
            Self.runSmokeWindow()
        }
        if let regionArgIndex = CommandLine.arguments.firstIndex(of: "--smoke-region"),
           regionArgIndex + 1 < CommandLine.arguments.count {
            Self.runSmokeRegion(rawArg: CommandLine.arguments[regionArgIndex + 1])
        }
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(historyStore)
                .environmentObject(permission)
                .frame(minWidth: 920, minHeight: 600)
                .task {
                    await historyStore.bootstrap()
                    permission.refresh()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    /// 起動引数 `--register-tcc` 専用。
    /// macOS 15 では CGRequestScreenCaptureAccess() に加えて
    /// SCShareableContent.current を実際に呼ぶことで TCC db に
    /// ScreenStore のエントリが確実に作成される。
    private static func registerWithTCC() {
        appLog.info("register-tcc starting")
        let pre = CGPreflightScreenCaptureAccess()
        let req = CGRequestScreenCaptureAccess()
        appLog.info("register-tcc preflight=\(pre, privacy: .public) request=\(req, privacy: .public)")
        Task.detached {
            do {
                let content = try await SCShareableContent.current
                appLog.info("register-tcc SCShareableContent OK: displays=\(content.displays.count, privacy: .public) windows=\(content.windows.count, privacy: .public)")
            } catch {
                appLog.info("register-tcc SCShareableContent error (これが TCC ダイアログ誘発): \(String(describing: error), privacy: .public)")
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let postPre = CGPreflightScreenCaptureAccess()
            appLog.info("register-tcc post-sleep preflight=\(postPre, privacy: .public)")
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    /// 起動引数 `--smoke-capture` 専用。GUI に依存せず CaptureService をフル実行し、
    /// 結果を os_log に出してプロセスを終了する。
    private static func runSmokeCapture() {
        appLog.info("smoke-capture starting")
        let preflight = CGPreflightScreenCaptureAccess()
        appLog.info("smoke-capture preflight=\(preflight, privacy: .public)")

        Task.detached {
            do {
                try StorageService.shared.prepare()
                let item = try await CaptureService.shared.captureFullScreen()
                appLog.info("smoke-capture OK: \(item.fileURL.path, privacy: .public) \(Int(item.pixelSize.width), privacy: .public)x\(Int(item.pixelSize.height), privacy: .public)")
            } catch {
                appLog.error("smoke-capture FAILED: \(String(describing: error), privacy: .public)")
            }
            await MainActor.run {
                NSApp.terminate(nil)
            }
        }
    }

    /// 起動引数 `--smoke-window` 専用。共有可能ウィンドウ一覧から最初の他アプリウィンドウを選び、
    /// 撮影してログ出力 → 終了する。GUI 操作なしで end-to-end 確認するためのデバッグ補助。
    private static func runSmokeWindow() {
        appLog.info("smoke-window starting")
        Task.detached {
            do {
                try StorageService.shared.prepare()
                let windows = try await CaptureService.shared.listCapturableWindows()
                appLog.info("smoke-window candidates=\(windows.count, privacy: .public)")
                guard let target = windows.first else {
                    appLog.error("smoke-window: no candidate windows")
                    await MainActor.run { NSApp.terminate(nil) }
                    return
                }
                appLog.info("smoke-window picking: app=\(target.appName, privacy: .public) title=\(target.title, privacy: .public) id=\(target.id, privacy: .public)")
                let item = try await CaptureService.shared.captureWindow(id: target.id)
                appLog.info("smoke-window OK: \(item.fileURL.path, privacy: .public) \(Int(item.pixelSize.width), privacy: .public)x\(Int(item.pixelSize.height), privacy: .public)")
            } catch {
                appLog.error("smoke-window FAILED: \(String(describing: error), privacy: .public)")
            }
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    /// 起動引数 `--smoke-region <x>,<y>,<w>,<h>` 専用。メインスクリーン上の左下原点 / point の矩形を
    /// 撮影してログ出力 → 終了する。
    private static func runSmokeRegion(rawArg: String) {
        appLog.info("smoke-region starting arg=\(rawArg, privacy: .public)")
        let parts = rawArg.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3] else {
            appLog.error("smoke-region: invalid arg, expected x,y,w,h")
            Task.detached { await MainActor.run { NSApp.terminate(nil) } }
            return
        }
        let rect = CGRect(x: x, y: y, width: w, height: h)

        Task.detached {
            do {
                try StorageService.shared.prepare()
                let (displayID, size, scale): (CGDirectDisplayID, CGSize, CGFloat) = await MainActor.run {
                    let screen = NSScreen.main ?? NSScreen.screens.first!
                    return (CaptureService.displayID(for: screen), screen.frame.size, screen.backingScaleFactor)
                }
                let item = try await CaptureService.shared.captureRegion(
                    windowLocalRect: rect,
                    displayID: displayID,
                    screenPointSize: size,
                    backingScale: scale
                )
                appLog.info("smoke-region OK: \(item.fileURL.path, privacy: .public) \(Int(item.pixelSize.width), privacy: .public)x\(Int(item.pixelSize.height), privacy: .public)")
            } catch {
                appLog.error("smoke-region FAILED: \(String(describing: error), privacy: .public)")
            }
            await MainActor.run { NSApp.terminate(nil) }
        }
    }
}
