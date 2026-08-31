import SwiftUI
import AppKit
import ScreenCaptureKit
import os.log

private let appLog = Logger(subsystem: "com.sinoda.ScreenStore", category: "app")

/// アプリの起動/終了タイミングに対するフックを担当する。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var captureController: CaptureController?
    private var terminationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            self.configureMainWindows()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        configureMainWindows()
    }

    /// Dock アイコンのクリックやアプリ再アクティブ化でメインウィンドウを必ず呼び戻す。
    ///
    /// 常駐するキャプチャパレット (`NSPanel`) が生き続けるため、メインウィンドウを閉じると
    /// アプリは終了せず、かつ「可視ウィンドウあり」と判定されて標準の再オープンも走らない。
    /// その結果メインウィンドウ＝編集や履歴の画面に戻れなくなる。ここで明示的に復帰させる。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // パレットは NSPanel。メインは通常の NSWindow（メインになれる）で見分ける。
        if let main = sender.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) {
            main.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
            return false
        }
        // メインウィンドウが破棄済みなら true を返して WindowGroup に再生成させる。
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard captureController?.isRecording == true else {
            return .terminateNow
        }
        guard terminationTask == nil else {
            return .terminateLater
        }

        terminationTask = Task { @MainActor [weak self, weak captureController] in
            await captureController?.stopActiveRecordingForTermination()
            self?.terminationTask = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func configureMainWindows() {
        for window in NSApp.windows where !(window is NSPanel) {
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.toolbarStyle = .expanded
            window.backgroundColor = .windowBackgroundColor
            window.isOpaque = true
        }
    }

}

@main
struct ScreenStoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var historyStore = HistoryStore()
    @StateObject private var permission = ScreenRecordingPermission()
    @StateObject private var shortcuts = ShortcutSettings()
    @StateObject private var captureController = CaptureController()

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
                .environmentObject(shortcuts)
                .environmentObject(captureController)
                .frame(minWidth: 920, minHeight: 600)
                .task {
                    await historyStore.bootstrap()
                    permission.refresh()
                    // env オブジェクトが揃ったこのタイミングで共有コントローラを構成し、
                    // 起動時に常時最前面のフローティングパレットを表示する。
                    captureController.configure(historyStore: historyStore, permission: permission)
                    appDelegate.captureController = captureController
                    CapturePaletteController.shared.show(capture: captureController, shortcuts: shortcuts)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            ClipboardCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(shortcuts)
                .environmentObject(historyStore)
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
        print("register-tcc preflight=\(pre) request=\(req) app=\(Bundle.main.bundlePath)")
        Task.detached {
            do {
                let content = try await SCShareableContent.current
                appLog.info("register-tcc SCShareableContent OK: displays=\(content.displays.count, privacy: .public) windows=\(content.windows.count, privacy: .public)")
                print("register-tcc SCShareableContent OK displays=\(content.displays.count) windows=\(content.windows.count)")
            } catch {
                appLog.info("register-tcc SCShareableContent error (これが TCC ダイアログ誘発): \(String(describing: error), privacy: .public)")
                print("register-tcc SCShareableContent error: \(String(describing: error))")
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let postPre = CGPreflightScreenCaptureAccess()
            appLog.info("register-tcc post-sleep preflight=\(postPre, privacy: .public)")
            print("register-tcc post-sleep preflight=\(postPre)")
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    /// 起動引数 `--smoke-capture` 専用。GUI に依存せず CaptureService をフル実行し、
    /// 結果を os_log に出してプロセスを終了する。
    private static func runSmokeCapture() {
        appLog.info("smoke-capture starting")
        let preflight = CGPreflightScreenCaptureAccess()
        appLog.info("smoke-capture preflight=\(preflight, privacy: .public)")
        print("smoke-capture preflight=\(preflight) app=\(Bundle.main.bundlePath)")

        Task.detached {
            do {
                try StorageService.shared.prepare()
                let output = try await CaptureService.shared.captureFullScreen()
                appLog.info("smoke-capture OK: \(output.item.fileURL.path, privacy: .public) \(Int(output.item.pixelSize.width), privacy: .public)x\(Int(output.item.pixelSize.height), privacy: .public)")
                print("smoke-capture OK: \(output.item.fileURL.path) \(Int(output.item.pixelSize.width))x\(Int(output.item.pixelSize.height))")
            } catch {
                appLog.error("smoke-capture FAILED: \(String(describing: error), privacy: .public)")
                print("smoke-capture FAILED: \(String(describing: error))")
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
                let output = try await CaptureService.shared.captureWindow(id: target.id)
                appLog.info("smoke-window OK: \(output.item.fileURL.path, privacy: .public) \(Int(output.item.pixelSize.width), privacy: .public)x\(Int(output.item.pixelSize.height), privacy: .public)")
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
                let output = try await CaptureService.shared.captureRegion(
                    windowLocalRect: rect,
                    displayID: displayID,
                    screenPointSize: size,
                    backingScale: scale
                )
                appLog.info("smoke-region OK: \(output.item.fileURL.path, privacy: .public) \(Int(output.item.pixelSize.width), privacy: .public)x\(Int(output.item.pixelSize.height), privacy: .public)")
            } catch {
                appLog.error("smoke-region FAILED: \(String(describing: error), privacy: .public)")
            }
            await MainActor.run { NSApp.terminate(nil) }
        }
    }
}
