import SwiftUI
import AppKit
import os.log

private let paletteLog = Logger(subsystem: "com.sinoda.ScreenStore", category: "capture-palette")

/// 常に最前面のフローティングキャプチャパレット (NSPanel) を束ねるマネージャ。
///
/// `CapturePaletteView` を `NSHostingView` でホストし、全 Space / フルスクリーン上でも
/// 最前面に出るよう構成する。env オブジェクトはアプリ側 (`MainView.task`) から注入する。
@MainActor
final class CapturePaletteController {
    static let shared = CapturePaletteController()

    private var panel: NSPanel?
    private var countdownPanel: NSPanel?
    private weak var configuredCapture: CaptureController?
    private weak var configuredShortcuts: ShortcutSettings?

    private init() {}

    /// パレットを生成 (初回のみ) して表示する。既に生成済みなら最前面に出すだけ。
    func show(
        capture: CaptureController,
        shortcuts: ShortcutSettings
    ) {
        configuredCapture = capture
        configuredShortcuts = shortcuts

        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let rootView = CapturePaletteView(
            onClose: { [weak self] in
                self?.hide()
            }
        )
        .environmentObject(capture)
        .environmentObject(shortcuts)

        let hosting = NSHostingView(rootView: rootView)
        // SwiftUI の intrinsic サイズに追従させ、生成直後の fittingSize が 0 になる問題を避ける。
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = [.minSize, .intrinsicContentSize]
        }
        // 内容のレイアウトを確定させてから自然サイズを得る (= 0 サイズパネル回避)。
        hosting.layoutSubtreeIfNeeded()
        var contentSize = hosting.fittingSize
        if contentSize.width < 100 || contentSize.height < 30 {
            let scale = currentPaletteScale
            contentSize = NSSize(width: 280 * scale, height: 40 * scale)
        }
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        hosting.translatesAutoresizingMaskIntoConstraints = true

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        // タイトルバーを隠してコンパクトに。背景は SwiftUI 側の material に任せる。
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        panel.level = .floating
        // 注意: `.canJoinAllSpaces` と `.moveToActiveSpace` は相互排他なので併用しない
        // (併用すると NSPanel 構成時に例外になる)。全 Space / フルスクリーン上に出すだけで十分。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hosting

        // 画面下部中央あたりに配置する。
        panel.setContentSize(contentSize)
        positionAtBottomCenter(panel)

        panel.orderFrontRegardless()
        self.panel = panel
        paletteLog.info("capture palette shown frame=\(NSStringFromRect(panel.frame), privacy: .public)")
    }

    /// パレットを画面から隠す (パネル本体は破棄せず再利用する)。
    func hide() {
        panel?.orderOut(nil)
        paletteLog.info("capture palette hidden")
    }

    func showIfConfigured() {
        guard let configuredCapture, let configuredShortcuts else { return }
        show(capture: configuredCapture, shortcuts: configuredShortcuts)
    }

    /// 設定画面のスライダー変更後に、現在表示中のパネルを新しい自然サイズへ追従させる。
    func refreshSize() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.resizePanelToFit()
        }
    }

    func showCountdown(_ remaining: Int) {
        let rootView = CountdownOverlayView(remaining: remaining)
        if let countdownPanel,
           let hosting = countdownPanel.contentView as? NSHostingView<CountdownOverlayView> {
            hosting.rootView = rootView
            positionAtBottomCenter(countdownPanel, yOffset: 96)
            countdownPanel.orderFrontRegardless()
            return
        }

        let hosting = NSHostingView(rootView: rootView)
        hosting.layoutSubtreeIfNeeded()
        var contentSize = hosting.fittingSize
        if contentSize.width < 60 || contentSize.height < 40 {
            contentSize = NSSize(width: 120, height: 74)
        }
        hosting.frame = NSRect(origin: .zero, size: contentSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.setContentSize(contentSize)
        positionAtBottomCenter(panel, yOffset: 96)
        panel.orderFrontRegardless()
        countdownPanel = panel
    }

    func hideCountdown() {
        countdownPanel?.orderOut(nil)
    }

    /// 表示中なら隠し、隠れているなら出す。メニュー / ショートカットのトグル用。
    func toggle(
        capture: CaptureController,
        shortcuts: ShortcutSettings
    ) {
        if let panel, panel.isVisible {
            hide()
        } else {
            show(capture: capture, shortcuts: shortcuts)
        }
    }

    /// メインスクリーンの可視領域 (Dock / メニューバーを除く) の下部中央にパレットを置く。
    private func positionAtBottomCenter(_ panel: NSPanel, yOffset: CGFloat = 24) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + yOffset
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    private var currentPaletteScale: CGFloat {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: AppPreferenceKeys.capturePaletteScale) as? Double
            ?? AppPreferenceKeys.defaultCapturePaletteScale
        return CGFloat(min(
            max(stored, AppPreferenceKeys.minimumCapturePaletteScale),
            AppPreferenceKeys.maximumCapturePaletteScale
        ))
    }

    private func resizePanelToFit() {
        guard let panel, let hosting = panel.contentView else { return }

        let centerX = panel.frame.midX
        let minY = panel.frame.minY
        hosting.invalidateIntrinsicContentSize()
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()

        let contentSize = hosting.fittingSize
        guard contentSize.width >= 100, contentSize.height >= 20 else { return }

        panel.setContentSize(contentSize)
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        panel.setFrameOrigin(NSPoint(x: centerX - panel.frame.width / 2, y: minY))
        paletteLog.info("capture palette resized frame=\(NSStringFromRect(panel.frame), privacy: .public)")
    }

}

private struct CountdownOverlayView: View {
    let remaining: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(remaining)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("撮影")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white)
        .frame(width: 96, height: 58)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .padding(8)
    }
}
