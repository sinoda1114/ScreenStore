import AppKit
import CoreGraphics
import ScreenCaptureKit
import os.log

private let windowSelectionLog = Logger(
    subsystem: "com.sinoda.ScreenStore",
    category: "window-select"
)

/// ScreenCaptureKit / Core Graphics の上端原点座標をAppKitの下端原点座標へ変換し、
/// 前面から並んだウインドウの中からポインタ直下の対象を決める純粋ロジック。
enum WindowSelectionGeometry {
    static func appKitFrame(
        fromScreenCaptureFrame frame: CGRect,
        primaryScreenMaxY: CGFloat
    ) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryScreenMaxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    static func topmostWindowID(
        at point: CGPoint,
        orderedWindowIDs: [CGWindowID],
        framesByWindowID: [CGWindowID: CGRect]
    ) -> CGWindowID? {
        orderedWindowIDs.first { windowID in
            framesByWindowID[windowID]?.contains(point) == true
        }
    }
}

/// ScreenCaptureKitで取得したウインドウを、画面上で直接ホバー・クリックして選択する。
/// 外部コマンドやAccessibility APIを使わず、App Sandbox内で完結する。
@MainActor
final class WindowSelectionController {
    static let shared = WindowSelectionController()

    private struct HiddenWindowState {
        let window: NSWindow
        let wasKey: Bool
    }

    private var continuation: CheckedContinuation<SCContentFilter?, Never>?
    private var candidateWindows: [CGWindowID: SCWindow] = [:]
    private var framesByWindowID: [CGWindowID: CGRect] = [:]
    private var orderedWindowIDs: [CGWindowID] = []
    private var overlayWindows: [WindowSelectionOverlayWindow] = []
    private var hiddenWindowStates: [HiddenWindowState] = []
    private var selectionObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var hoveredWindowID: CGWindowID?

    private init() {}

    func selectWindow() async throws -> SCContentFilter? {
        guard continuation == nil else {
            windowSelectionLog.notice("selectWindow called while already presenting; ignoring")
            return nil
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

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let windows = content.windows.filter { window in
            window.windowLayer == 0
                && window.isOnScreen
                && window.frame.width >= 20
                && window.frame.height >= 20
                && window.owningApplication?.bundleIdentifier != ownBundleIdentifier
        }
        guard !windows.isEmpty else { return nil }

        let primaryScreenMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        candidateWindows = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        framesByWindowID = Dictionary(uniqueKeysWithValues: windows.map {
            (
                $0.windowID,
                WindowSelectionGeometry.appKitFrame(
                    fromScreenCaptureFrame: $0.frame,
                    primaryScreenMaxY: primaryScreenMaxY
                )
            )
        })

        hideOwnWindows()
        // orderOutがWindow Serverへ反映されてから重なり順を取得する。
        try? await Task.sleep(nanoseconds: 80_000_000)
        orderedWindowIDs = currentFrontToBackOrder(candidateIDs: Set(candidateWindows.keys))

        guard !Task.isCancelled else {
            cleanupSelectionState()
            return nil
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled {
                    finish(with: nil)
                } else {
                    openOverlays()
                }
            }
        } onCancel: {
            Task { @MainActor in
                WindowSelectionController.shared.cancelSelection()
            }
        }
    }

    private func hideOwnWindows() {
        hiddenWindowStates = NSApp.windows
            .filter(\.isVisible)
            .map { HiddenWindowState(window: $0, wasKey: $0.isKeyWindow) }

        for state in hiddenWindowStates {
            state.window.orderOut(nil)
        }
    }

    private func restoreOwnWindows() {
        let states = hiddenWindowStates
        hiddenWindowStates.removeAll()

        for state in states {
            state.window.orderFront(nil)
        }
        if let keyWindow = states.first(where: \.wasKey)?.window {
            keyWindow.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func currentFrontToBackOrder(candidateIDs: Set<CGWindowID>) -> [CGWindowID] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        var seen = Set<CGWindowID>()
        var result: [CGWindowID] = []

        for entry in info {
            guard let number = entry[kCGWindowNumber as String] as? NSNumber else { continue }
            let windowID = CGWindowID(number.uint32Value)
            guard candidateIDs.contains(windowID), seen.insert(windowID).inserted else { continue }
            result.append(windowID)
        }

        // Window Serverの一覧に一時的に現れない候補も、最後尾なら選択可能にしておく。
        result.append(contentsOf: candidateIDs.subtracting(seen).sorted())
        return result
    }

    private func openOverlays() {
        closeOverlays()
        guard !NSScreen.screens.isEmpty else {
            finish(with: nil)
            return
        }

        observeEnvironmentChanges()

        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let window = WindowSelectionOverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.isMovableByWindowBackground = false
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .ignoresCycle,
                .fullScreenAuxiliary
            ]
            window.setFrame(screen.frame, display: true)

            let view = WindowSelectionOverlayView(targetScreen: screen, controller: self)
            view.frame = NSRect(origin: .zero, size: screen.frame.size)
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            window.initialFirstResponder = view
            window.makeFirstResponder(view)
            overlayWindows.append(window)
            window.orderFrontRegardless()
        }

        if let activeOverlay = overlayWindows.first(where: { $0.frame.contains(mouseLocation) })
            ?? overlayWindows.first {
            activeOverlay.makeKeyAndOrderFront(nil)
            activeOverlay.makeFirstResponder(activeOverlay.contentView)
        }
        updateHover(at: mouseLocation)
        windowSelectionLog.info("opened overlays on \(self.overlayWindows.count, privacy: .public) screens")
    }

    private func closeOverlays() {
        stopObservingEnvironmentChanges()
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        hoveredWindowID = nil
    }

    private func observeEnvironmentChanges() {
        stopObservingEnvironmentChanges()

        let applicationCenter = NotificationCenter.default
        let screenObserver = applicationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancelForEnvironmentChange("screen parameters changed")
            }
        }
        selectionObservers.append((applicationCenter, screenObserver))

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let spaceObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancelForEnvironmentChange("active Space changed")
            }
        }
        selectionObservers.append((workspaceCenter, spaceObserver))
    }

    private func stopObservingEnvironmentChanges() {
        for (center, observer) in selectionObservers {
            center.removeObserver(observer)
        }
        selectionObservers.removeAll()
    }

    private func cancelForEnvironmentChange(_ reason: String) {
        windowSelectionLog.info("window selection cancelled: \(reason, privacy: .public)")
        finish(with: nil)
    }

    func updateHover(at appKitScreenPoint: CGPoint) {
        let newWindowID = WindowSelectionGeometry.topmostWindowID(
            at: appKitScreenPoint,
            orderedWindowIDs: orderedWindowIDs,
            framesByWindowID: framesByWindowID
        )
        guard hoveredWindowID != newWindowID else { return }
        hoveredWindowID = newWindowID
        for case let view as WindowSelectionOverlayView in overlayWindows.compactMap(\.contentView) {
            view.needsDisplay = true
        }
    }

    func highlightRect(on screen: NSScreen) -> CGRect? {
        guard let hoveredWindowID,
              let globalFrame = framesByWindowID[hoveredWindowID] else { return nil }
        let intersection = globalFrame.intersection(screen.frame)
        guard !intersection.isNull, !intersection.isEmpty else { return nil }
        return intersection.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    func commitHoveredWindow() {
        guard let hoveredWindowID,
              let window = candidateWindows[hoveredWindowID] else {
            NSSound.beep()
            return
        }
        windowSelectionLog.info("selected window id=\(hoveredWindowID, privacy: .public)")
        finish(with: SCContentFilter(desktopIndependentWindow: window))
    }

    func cancelSelection() {
        windowSelectionLog.info("window selection cancelled")
        finish(with: nil)
    }

    private func finish(with filter: SCContentFilter?) {
        guard let continuation else { return }
        self.continuation = nil
        cleanupSelectionState()
        continuation.resume(returning: filter)
    }

    private func cleanupSelectionState() {
        closeOverlays()
        restoreOwnWindows()
        candidateWindows.removeAll()
        framesByWindowID.removeAll()
        orderedWindowIDs.removeAll()
    }
}

// MARK: - Overlay window

final class WindowSelectionOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Overlay view

final class WindowSelectionOverlayView: NSView {
    let targetScreen: NSScreen
    weak var controller: WindowSelectionController?
    private var trackingAreaReference: NSTrackingArea?

    init(targetScreen: NSScreen, controller: WindowSelectionController) {
        self.targetScreen = targetScreen
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: Self.cameraCursor)
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        updateHover(with: event)
        controller?.commitHoveredWindow()
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.cancelSelection()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            controller?.cancelSelection()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()

        if let rect = controller?.highlightRect(on: targetScreen) {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7)
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 4
            path.stroke()
        }

        drawHint()
    }

    private func updateHover(with event: NSEvent) {
        guard let window else { return }
        controller?.updateHover(at: window.convertPoint(toScreen: event.locationInWindow))
    }

    private func drawHint() {
        let text = String(localized: "window.selection_hint")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let textOrigin = CGPoint(
            x: (bounds.width - textSize.width) / 2,
            y: bounds.height - textSize.height - 28
        )
        let background = CGRect(
            x: textOrigin.x - 12,
            y: textOrigin.y - 6,
            width: textSize.width + 24,
            height: textSize.height + 12
        )
        NSColor.black.withAlphaComponent(0.68).setFill()
        NSBezierPath(roundedRect: background, xRadius: 8, yRadius: 8).fill()
        attributed.draw(at: textOrigin)
    }

    private static let cameraCursor: NSCursor = {
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.black.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: NSRect(x: 1, y: 6, width: 30, height: 21), xRadius: 6, yRadius: 6).fill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: 25, width: 10, height: 5), xRadius: 2, yRadius: 2).fill()

        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 3, y: 8, width: 26, height: 17), xRadius: 4, yRadius: 4).fill()
        NSColor.black.withAlphaComponent(0.88).setFill()
        NSBezierPath(ovalIn: NSRect(x: 10, y: 10, width: 12, height: 12)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 13, y: 13, width: 6, height: 6)).fill()

        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: 16, y: 16))
    }()
}
