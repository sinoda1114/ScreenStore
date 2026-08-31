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

    /// 閉じるボタンで呼ばれる。パレット (NSPanel) を hide する。
    var onClose: () -> Void = {}

    var body: some View {
        HStack(spacing: scaled(2)) {
            sideDragHandle

            paletteButton(
                title: "全画面",
                systemImage: "rectangle.dashed",
                help: "全画面をキャプチャ (\(shortcuts.fullScreen.displayString))"
            ) {
                await capture.runFullScreen()
            }

            paletteButton(
                title: "ウィンドウ",
                systemImage: "macwindow",
                help: "ウィンドウ指定キャプチャ (\(shortcuts.window.displayString))"
            ) {
                await capture.runWindow()
            }

            paletteButton(
                title: "切抜",
                systemImage: "selection.pin.in.out",
                help: "選択範囲を切り抜き (\(shortcuts.region.displayString))"
            ) {
                await capture.runRegion()
            }

            paletteButton(
                title: capture.isRecording ? "停止" : "録画",
                systemImage: capture.isRecording ? "stop.circle.fill" : "record.circle",
                help: capture.isRecording ? "範囲録画を停止" : "選択範囲を録画",
                disabled: capture.isCapturing && !capture.isRecording,
                isActiveRecording: capture.isRecording
            ) {
                await capture.toggleRegionRecording()
            }

            Divider()
                .frame(height: scaled(16))
                .padding(.horizontal, scaled(1))

            paletteButton(
                title: capture.delayedCaptureCountdown.map { "\($0)秒" } ?? "遅延",
                systemImage: "timer",
                help: "5秒後に全画面をキャプチャ。メニューバーのポップオーバー撮影用",
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

    private var sideDragHandle: some View {
        PaletteDragHandleView()
        .frame(width: scaled(10), height: scaled(28))
        .help("ドラッグして移動")
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
        title: String,
        systemImage: String,
        help: String,
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
                Text(title)
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
    func makeNSView(context: Context) -> PaletteDragHandleNSView {
        PaletteDragHandleNSView()
    }

    func updateNSView(_ nsView: PaletteDragHandleNSView, context: Context) {}
}

private final class PaletteDragHandleNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
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
}
