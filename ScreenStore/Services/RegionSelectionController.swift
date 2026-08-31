import Foundation
import AppKit
import CoreGraphics
import os.log

private let regionLog = Logger(subsystem: "com.sinoda.ScreenStore", category: "region-select")

/// 範囲指定キャプチャの結果。`rect` は `screen` の origin に対するローカル座標 (左下原点 / point)。
struct RegionSelection {
    let rect: CGRect
    let screen: NSScreen
}

/// スクリーンを覆う透過オーバーレイ NSWindow を出して、ドラッグで矩形選択させるコントローラ。
@MainActor
final class RegionSelectionController {
    static let shared = RegionSelectionController()

    private var overlayWindows: [RegionOverlayWindow] = []
    private var continuation: CheckedContinuation<RegionSelection?, Never>?
    private var isPresenting = false

    private init() {}

    /// オーバーレイを表示してユーザーの矩形選択を待つ。
    /// ESC または小さすぎる矩形 (< 4pt) は nil を返す。
    func selectRegion() async -> RegionSelection? {
        if isPresenting {
            regionLog.notice("selectRegion called while already presenting; ignoring")
            return nil
        }
        isPresenting = true
        defer { isPresenting = false }

        return await withCheckedContinuation { (cont: CheckedContinuation<RegionSelection?, Never>) in
            self.continuation = cont
            self.openOverlays()
        }
    }

    private func openOverlays() {
        closeOverlays()
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else {
            cancelSelection()
            return
        }

        regionLog.info("opening overlay on screen frame=\(NSStringFromRect(screen.frame), privacy: .public)")
        let win = RegionOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .screenSaver
        win.ignoresMouseEvents = false
        win.acceptsMouseMovedEvents = true
        win.isMovableByWindowBackground = false
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        win.setFrame(screen.frame, display: true)

        let displayID = CaptureService.displayID(for: screen)
        let backgroundImage = CGDisplayCreateImage(displayID).map {
            NSImage(cgImage: $0, size: screen.frame.size)
        }
        let view = RegionOverlayView(
            targetScreen: screen,
            controller: self,
            backgroundImage: backgroundImage
        )
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        win.contentView = view
        win.initialFirstResponder = view
        win.makeFirstResponder(view)
        overlayWindows = [win]

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
    }

    private func closeOverlays() {
        for win in overlayWindows {
            win.orderOut(nil)
        }
        overlayWindows.removeAll()
    }

    /// オーバーレイ View から呼ばれる確定通知。orderOut してから continuation を resume する。
    func commitSelection(rect: CGRect, on screen: NSScreen) {
        regionLog.info("commitSelection rect=\(NSStringFromRect(rect), privacy: .public)")
        let cont = continuation
        continuation = nil
        closeOverlays()
        cont?.resume(returning: RegionSelection(rect: rect, screen: screen))
    }

    /// オーバーレイ View または ESC から呼ばれるキャンセル通知。
    func cancelSelection() {
        regionLog.info("cancelSelection")
        let cont = continuation
        continuation = nil
        closeOverlays()
        cont?.resume(returning: nil)
    }
}

// MARK: - Overlay window

/// `.borderless` でも keyDown / mouse イベントを受け付けるための最小オーバーライド。
/// stored property を持たないので NSWindow の指定 init をそのまま継承でき、
/// AppKit が内部的に 4 引数 init を self 呼びしても SIGTRAP しない。
final class RegionOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Overlay view

final class RegionOverlayView: NSView {
    let targetScreen: NSScreen
    weak var controller: RegionSelectionController?
    private let backgroundImage: NSImage?

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?

    init(targetScreen: NSScreen, controller: RegionSelectionController, backgroundImage: NSImage?) {
        self.targetScreen = targetScreen
        self.controller = controller
        self.backgroundImage = backgroundImage
        super.init(frame: .zero)
        self.wantsLayer = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// ドラッグ中の選択矩形 (lower-left origin / point)。両端点が無いときは nil。
    private var selectionRect: CGRect? {
        guard let s = startPoint, let c = currentPoint else { return nil }
        return RegionMath.normalizedRect(from: s, to: c)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        startPoint = p
        currentPoint = p
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        currentPoint = p
        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            startPoint = nil
            currentPoint = nil
            setNeedsDisplay(bounds)
        }
        guard let rect = selectionRect, rect.width >= 4, rect.height >= 4 else {
            controller?.cancelSelection()
            return
        }
        controller?.commitSelection(rect: rect, on: targetScreen)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            controller?.cancelSelection()
        case 36, 76: // Return / Numpad Enter
            if let rect = selectionRect, rect.width >= 4, rect.height >= 4 {
                controller?.commitSelection(rect: rect, on: targetScreen)
            } else {
                controller?.cancelSelection()
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        drawBackground()

        if let rect = selectionRect {
            // 背景スクショの上に、選択範囲の周囲4辺だけ暗幕を描く。
            // 透明ウィンドウ依存を捨てることで、全面グレー化しても範囲内は見える。
            drawDimmingRects(excluding: rect, in: context)

            context.saveGState()
            context.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.95).cgColor)
            context.setLineWidth(1.0)
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            context.restoreGState()

            drawSizeLabel(rect: rect, in: context)
        } else {
            context.saveGState()
            context.setFillColor(CGColor(gray: 0.0, alpha: 0.35))
            context.fill(bounds)
            context.restoreGState()
            drawHintLabel(in: context)
        }
    }

    private func drawBackground() {
        guard let backgroundImage else {
            NSColor.clear.setFill()
            bounds.fill()
            return
        }
        backgroundImage.draw(
            in: bounds,
            from: NSRect(origin: .zero, size: backgroundImage.size),
            operation: .copy,
            fraction: 1.0
        )
    }

    private func drawDimmingRects(excluding rect: CGRect, in context: CGContext) {
        let clipped = rect.intersection(bounds)
        context.saveGState()
        context.setFillColor(CGColor(gray: 0.0, alpha: 0.35))
        if clipped.isNull || clipped.isEmpty {
            context.fill(bounds)
        } else {
            let top = CGRect(x: bounds.minX, y: clipped.maxY, width: bounds.width, height: bounds.maxY - clipped.maxY)
            let bottom = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: clipped.minY - bounds.minY)
            let left = CGRect(x: bounds.minX, y: clipped.minY, width: clipped.minX - bounds.minX, height: clipped.height)
            let right = CGRect(x: clipped.maxX, y: clipped.minY, width: bounds.maxX - clipped.maxX, height: clipped.height)
            for dimRect in [top, bottom, left, right] where dimRect.width > 0 && dimRect.height > 0 {
                context.fill(dimRect)
            }
        }
        context.restoreGState()
    }

    private func drawSizeLabel(rect: CGRect, in context: CGContext) {
        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let attr = NSAttributedString(string: label, attributes: attrs)
        let size = attr.size()
        // ラベル位置: 選択矩形の右下、画面外なら左上にずらす
        var x = rect.maxX - size.width - 6
        var y = rect.minY - size.height - 4
        if y < 4 { y = rect.maxY + 4 }
        if x < 4 { x = rect.minX + 6 }
        let bg = CGRect(
            x: x - 4, y: y - 2,
            width: size.width + 8, height: size.height + 4
        )
        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: 0.65))
        context.fill(bg)
        context.restoreGState()
        attr.draw(at: NSPoint(x: x, y: y))
    }

    private func drawHintLabel(in context: CGContext) {
        let hint = String(localized: "region.selection_hint")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let attr = NSAttributedString(string: hint, attributes: attrs)
        let size = attr.size()
        let x = (bounds.width - size.width) / 2
        let y = bounds.height * 0.92 - size.height
        let bg = CGRect(
            x: x - 12, y: y - 6,
            width: size.width + 24, height: size.height + 12
        )
        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: 0.55))
        let path = CGPath(roundedRect: bg, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        attr.draw(at: NSPoint(x: x, y: y))
    }
}
