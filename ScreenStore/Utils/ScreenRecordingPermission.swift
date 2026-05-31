import Foundation
import AppKit
import CoreGraphics
import SwiftUI
import os.log

private let permLog = Logger(subsystem: "com.sinoda.ScreenStore", category: "permission")

@MainActor
final class ScreenRecordingPermission: ObservableObject {
    @Published private(set) var isGranted: Bool = false

    private var pollingTask: Task<Void, Never>?

    init() {
        refresh()
        permLog.info("ScreenRecordingPermission init, isGranted=\(self.isGranted, privacy: .public)")
    }

    /// 現在の許諾状況を即時に確認して isGranted を更新する。
    func refresh() {
        let value = CGPreflightScreenCaptureAccess()
        isGranted = value
        permLog.info("refresh -> isGranted=\(value, privacy: .public)")
    }

    /// 初回キャプチャなどで一度だけ TCC ダイアログを出すために使う。
    /// 既に許諾済みの場合は何もしない。
    @discardableResult
    func requestIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            isGranted = true
            return true
        }
        let granted = CGRequestScreenCaptureAccess()
        isGranted = granted
        return granted
    }

    /// バナーから呼ばれるエントリポイント。
    /// 1. 先に CGRequestScreenCaptureAccess() を呼んで TCC データベースに
    ///    ScreenStore を登録させる (これをしないとシステム設定のリストに出ない)
    /// 2. システム設定の「画面収録」ペインを開く
    /// 3. ユーザーが許諾するまでバックグラウンドでポーリング
    func requestAccessAndOpenSettings() {
        permLog.info("requestAccessAndOpenSettings called")
        if CGPreflightScreenCaptureAccess() {
            permLog.info("preflight true -> nothing to do")
            isGranted = true
            return
        }
        // CGRequestScreenCaptureAccess() を呼ぶと TCC に登録され、
        // 初回ならシステムダイアログが自動で出る (返値は即時)。
        let req = CGRequestScreenCaptureAccess()
        permLog.info("CGRequestScreenCaptureAccess returned \(req, privacy: .public)")
        openSystemSettings()
    }

    /// システム設定の「画面収録」ペインを開くだけ (TCC 登録はしない)。
    func openSystemSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        startPolling()
    }

    /// ユーザーが設定アプリで許諾したかをポーリングで反映するために使う。
    /// 1 秒間隔で最大 60 回、または許諾されたら停止する。
    func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                let granted = CGPreflightScreenCaptureAccess()
                await MainActor.run {
                    self.isGranted = granted
                }
                if granted { return }
            }
        }
    }
}
