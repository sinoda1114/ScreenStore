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

    /// 閉じるボタンで呼ばれる。パレット (NSPanel) を hide する。
    var onClose: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
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
                title: "範囲",
                systemImage: "selection.pin.in.out",
                help: "自由範囲キャプチャ (\(shortcuts.region.displayString))"
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
                .frame(height: 22)
                .padding(.horizontal, 2)

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
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("パレットを閉じる")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(8)
        .alert("キャプチャに失敗しました", isPresented: $capture.showError, presenting: capture.lastError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var sideDragHandle: some View {
        PaletteDragHandleView()
        .frame(width: 18, height: 38)
        .help("ドラッグして移動")
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
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .regular))
                Text(title)
                    .font(.system(size: 9))
            }
            .frame(width: 52, height: 38)
            .contentShape(Rectangle())
            .foregroundStyle(isActiveRecording ? Color.white : Color.primary)
            .background {
                if isActiveRecording {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.red)
                        .shadow(color: Color.red.opacity(0.45), radius: 7, x: 0, y: 0)
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
        drawHandleLine(x: bounds.midX - 3, color: color)
        drawHandleLine(x: bounds.midX + 3, color: secondary)
    }

    private func drawHandleLine(x: CGFloat, color: NSColor) {
        let rect = NSRect(x: x - 1.5, y: bounds.midY - 11, width: 3, height: 22)
        let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
        color.setFill()
        path.fill()
    }
}
