import SwiftUI
import AppKit

/// 常に最前面に出るコンパクトなフローティングキャプチャパレットの中身。
///
/// macOS 標準の Cmd+Shift+5 パレットに雰囲気を寄せた横並びのアイコンボタン群。
/// キャプチャ実行ロジックは `CaptureController` に委譲しており、メインウィンドウの
/// `CaptureToolbar` と完全に同じ挙動 (クリップボード即時書き込み → 履歴 prependAndSelect) になる。
struct CapturePaletteView: View {
    @EnvironmentObject private var capture: CaptureController
    @EnvironmentObject private var shortcuts: ShortcutSettings
    @AppStorage(AppPreferenceKeys.capturePaletteBackgroundOpacity)
    private var backgroundOpacity = AppPreferenceKeys.defaultCapturePaletteBackgroundOpacity
    @AppStorage(AppPreferenceKeys.capturePaletteScale)
    private var storedScale = AppPreferenceKeys.defaultCapturePaletteScale
    @State private var isCollapsed = false

    /// 閉じるボタンで呼ばれる。パレット (NSPanel) を hide する。
    var onClose: () -> Void = {}
    /// 折りたたみ状態の変更後、パネルを内容の自然サイズへ追従させる。
    var onCollapsedChange: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: scaled(2)) {
            sideDragHandle

            if !isCollapsed {
                paletteContents
            }
        }
        .padding(.horizontal, scaled(6))
        .padding(.vertical, scaled(3))
        .background(
            RoundedRectangle(cornerRadius: scaled(9), style: .continuous)
                .fill(.regularMaterial)
                .opacity(clampedBackgroundOpacity)
        )
        .overlay(
            RoundedRectangle(cornerRadius: scaled(9), style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08 * clampedBackgroundOpacity), lineWidth: 1)
        )
        .padding(scaled(3))
        .onChange(of: storedScale) { _, _ in
            CapturePaletteController.shared.refreshSize()
        }
        .alert("キャプチャに失敗しました", isPresented: $capture.showError, presenting: capture.lastError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var paletteContents: some View {
        paletteButton(
            title: Text("全画面"),
            systemImage: "rectangle.dashed",
            help: Text("全画面をキャプチャ (\(shortcuts.fullScreen.displayString))")
        ) {
            await capture.runFullScreen()
        }

        paletteButton(
            title: Text("ウィンドウ"),
            systemImage: "macwindow",
            help: Text("ウィンドウ指定キャプチャ (\(shortcuts.window.displayString))")
        ) {
            await capture.runWindow()
        }

        paletteButton(
            title: Text("切抜"),
            systemImage: "selection.pin.in.out",
            help: Text("選択範囲を切り抜き (\(shortcuts.region.displayString))")
        ) {
            await capture.runRegion()
        }

        paletteButton(
            title: capture.isRecording ? Text("停止") : Text("録画"),
            systemImage: capture.isRecording ? "stop.circle.fill" : "record.circle",
            help: capture.isRecording ? Text("範囲録画を停止") : Text("選択範囲を録画"),
            disabled: capture.isCapturing && !capture.isRecording,
            isActiveRecording: capture.isRecording
        ) {
            await capture.toggleRegionRecording()
        }

        Divider()
            .frame(height: scaled(16))
            .padding(.horizontal, scaled(1))

        paletteButton(
            title: capture.delayedCaptureCountdown.map { Text("\($0)秒") } ?? Text("遅延"),
            systemImage: "timer",
            help: Text("5秒後に全画面をキャプチャ。メニューバーのポップオーバー撮影用"),
            disabled: capture.isCapturing,
            isActiveRecording: capture.delayedCaptureCountdown != nil
        ) {
            await capture.runDelayedFullScreen(seconds: 5)
        }

        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: scaled(10), weight: .semibold))
                .frame(width: scaled(20), height: scaled(20))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("パレットを閉じる")
    }

    private var sideDragHandle: some View {
        PaletteDragHandleView(isCollapsed: isCollapsed) {
            let nextState = !isCollapsed
            isCollapsed = nextState
            onCollapsedChange(nextState)
        }
        .frame(width: scaled(10), height: scaled(28))
        .help(isCollapsed
            ? "ダブルクリックしてパレットを展開。ドラッグして移動"
            : "ダブルクリックしてパレットを折りたたみ。ドラッグして移動")
    }

    private var clampedBackgroundOpacity: Double {
        min(max(backgroundOpacity, 0.35), 1)
    }

    private var paletteScale: CGFloat {
        CGFloat(min(
            max(storedScale, AppPreferenceKeys.minimumCapturePaletteScale),
            AppPreferenceKeys.maximumCapturePaletteScale
        ))
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        value * paletteScale
    }

    @ViewBuilder
    private func paletteButton(
        title: Text,
        systemImage: String,
        help: Text,
        disabled: Bool? = nil,
        isActiveRecording: Bool = false,
        action: @escaping () async -> Void
    ) -> some View {
        let isDisabled = disabled ?? capture.isCapturing
        Button {
            Task { await action() }
        } label: {
            VStack(spacing: scaled(2)) {
                Image(systemName: systemImage)
                    .font(.system(size: scaled(13), weight: .regular))
                title
                    .font(.system(size: scaled(7.5)))
            }
            .frame(width: scaled(42), height: scaled(28))
            .contentShape(Rectangle())
            .foregroundStyle(isActiveRecording ? Color.white : Color.primary)
            .background {
                if isActiveRecording {
                    RoundedRectangle(cornerRadius: scaled(6), style: .continuous)
                        .fill(Color.red)
                        .shadow(color: Color.red.opacity(0.4), radius: scaled(4), x: 0, y: 0)
                }
            }
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
    }
}

private struct PaletteDragHandleView: NSViewRepresentable {
    let isCollapsed: Bool
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> PaletteDragHandleNSView {
        let view = PaletteDragHandleNSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: PaletteDragHandleNSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: PaletteDragHandleNSView) {
        view.onDoubleClick = onDoubleClick
        view.setAccessibilityLabel(isCollapsed ? "パレットを展開" : "パレットを折りたたむ")
        view.setAccessibilityHelp("ダブルクリックで切り替え、ドラッグで移動します")
    }
}

private final class PaletteDragHandleNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    var onDoubleClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        window?.performDrag(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onDoubleClick else { return false }
        onDoubleClick()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color = NSColor.labelColor.withAlphaComponent(0.28)
        let secondary = NSColor.labelColor.withAlphaComponent(0.18)
        let offset = bounds.width * 0.3
        drawHandleLine(x: bounds.midX - offset, color: color)
        drawHandleLine(x: bounds.midX + offset, color: secondary)
    }

    private func drawHandleLine(x: CGFloat, color: NSColor) {
        let width = max(1.5, bounds.width * 0.2)
        let height = bounds.height * 0.5
        let rect = NSRect(x: x - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        let path = NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2)
        color.setFill()
        path.fill()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
}
