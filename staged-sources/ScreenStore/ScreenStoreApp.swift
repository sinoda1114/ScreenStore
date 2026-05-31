import SwiftUI
import AppKit
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

    /// 起動引数 `--register-tcc` 専用。CGRequestScreenCaptureAccess() を呼んで
    /// TCC のリストに ScreenStore を登録し、ログを残して終了する。
    private static func registerWithTCC() {
        appLog.info("register-tcc starting")
        let pre = CGPreflightScreenCaptureAccess()
        let req = CGRequestScreenCaptureAccess()
        appLog.info("register-tcc preflight=\(pre, privacy: .public) request=\(req, privacy: .public)")
        Task.detached {
            try? await Task.sleep(nanoseconds: 200_000_000)
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
}
