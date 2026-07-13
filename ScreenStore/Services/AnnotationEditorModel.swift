import Foundation
import SwiftUI
import AppKit
import CoreGraphics

/// Direction for 90-degree base-image rotation.
enum RotateDirection {
    case left
    case right
}

/// Pure state model backing the inline annotation editor.
///
/// This object owns the editable base image, the annotation list, the current
/// drawing tool/style, and an undo/redo history. It contains no SwiftUI views;
/// follow-up workers wire a canvas UI on top of this API.
///
/// All annotation geometry is in image-pixel, top-left-origin space (see
/// `Annotation.swift`).
@MainActor
final class AnnotationEditorModel: ObservableObject {

    // MARK: Persistence keys

    private enum DefaultsKey {
        static let style = "annotation.style"
        static let lastTool = "annotation.lastTool"
        static let blurRadius = "annotation.blurRadius"
    }

    // MARK: Published state

    @Published var annotations: [Annotation] = []

    @Published var selectedTool: AnnotationTool = .select {
        didSet {
            guard selectedTool != oldValue else { return }
            persistPreferences()
        }
    }

    @Published var selectedID: Annotation.ID? = nil
    @Published var currentStyle: AnnotationStyle
    @Published var currentBlurRadius: CGFloat
    @Published var cropRect: CGRect? = nil

    private(set) var baseImage: CGImage

    var pixelSize: CGSize {
        CGSize(width: baseImage.width, height: baseImage.height)
    }

    // MARK: Undo / redo

    private var undoStack: [([Annotation], CGImage)] = []
    private var redoStack: [([Annotation], CGImage)] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private let defaults: UserDefaults

    // MARK: Init

    init(baseImage: CGImage, defaults: UserDefaults = .standard) {
        self.baseImage = baseImage
        self.defaults = defaults

        if let data = defaults.data(forKey: DefaultsKey.style),
           let restored = try? JSONDecoder().decode(AnnotationStyle.self, from: data) {
            self.currentStyle = restored
        } else {
            self.currentStyle = Annotation.defaultStyle
        }

        let restoredBlurRadius = defaults.double(forKey: DefaultsKey.blurRadius)
        self.currentBlurRadius = restoredBlurRadius > 0 ? CGFloat(restoredBlurRadius) : 16

        if let raw = defaults.string(forKey: DefaultsKey.lastTool),
           let tool = AnnotationTool(rawValue: raw) {
            self.selectedTool = tool
        } else {
            self.selectedTool = .select
        }
    }

    // MARK: History

    /// Captures the current annotations + base image before a mutating operation.
    func snapshot() {
        undoStack.append((annotations, baseImage))
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append((annotations, baseImage))
        annotations = previous.0
        baseImage = previous.1
        normalizeSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append((annotations, baseImage))
        annotations = next.0
        baseImage = next.1
        normalizeSelection()
    }

    private func normalizeSelection() {
        if let id = selectedID, !annotations.contains(where: { $0.id == id }) {
            selectedID = nil
        }
    }

    // MARK: Annotation operations

    func add(_ annotation: Annotation) {
        snapshot()
        annotations.append(annotation)
        selectedID = annotation.id
    }

    /// Mutates the currently selected annotation in place. Common entry point for
    /// style changes, moves, and resizes.
    func updateSelected(_ transform: (inout Annotation) -> Void) {
        guard let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        snapshot()
        transform(&annotations[index])
    }

    func moveSelected(by offset: CGSize) {
        guard let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        snapshot()
        annotations[index] = annotations[index].translated(by: offset)
    }

    func deleteSelected() {
        guard let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        snapshot()
        annotations.remove(at: index)
        selectedID = nil
    }

    /// Moves the selected annotation one step toward the front (drawn last).
    func bringForward() {
        guard let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }),
              index < annotations.count - 1 else { return }
        snapshot()
        annotations.swapAt(index, index + 1)
    }

    /// Moves the selected annotation one step toward the back (drawn first).
    func bringBackward() {
        guard let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }),
              index > 0 else { return }
        snapshot()
        annotations.swapAt(index, index - 1)
    }

    // MARK: Crop

    /// Crops the base image to `rect` (image-pixel, top-left-origin) and shifts all
    /// annotations so they stay aligned with the new origin.
    func applyCrop(to rect: CGRect) {
        let bounds = CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
        let clamped = rect.standardized.intersection(bounds).integral
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
              let cropped = baseImage.cropping(to: clamped) else { return }

        snapshot()
        baseImage = cropped
        let offset = CGSize(width: -clamped.origin.x, height: -clamped.origin.y)
        annotations = annotations.map { $0.translated(by: offset) }
        cropRect = nil
    }

    // MARK: Rotation

    /// Rotates the base image 90 degrees and rotates all annotation geometry to
    /// match, keeping existing annotations aligned with the image.
    func rotate(_ direction: RotateDirection) {
        let oldWidth = CGFloat(baseImage.width)
        let oldHeight = CGFloat(baseImage.height)
        guard let rotatedImage = Self.rotated90(baseImage, direction: direction) else { return }

        snapshot()
        baseImage = rotatedImage
        annotations = annotations.map {
            Self.rotateAnnotation($0, direction: direction, oldWidth: oldWidth, oldHeight: oldHeight)
        }
    }

    /// Rotates a point from a `oldWidth`x`oldHeight` image into the rotated image's
    /// top-left coordinate space.
    private static func rotatePoint(_ p: CGPoint, direction: RotateDirection, oldWidth: CGFloat, oldHeight: CGFloat) -> CGPoint {
        switch direction {
        case .right: // clockwise: new dims (oldHeight, oldWidth)
            return CGPoint(x: oldHeight - p.y, y: p.x)
        case .left: // counterclockwise: new dims (oldHeight, oldWidth)
            return CGPoint(x: p.y, y: oldWidth - p.x)
        }
    }

    private static func rotateRect(_ rect: CGRect, direction: RotateDirection, oldWidth: CGFloat, oldHeight: CGFloat) -> CGRect {
        let r = rect.standardized
        let c1 = rotatePoint(CGPoint(x: r.minX, y: r.minY), direction: direction, oldWidth: oldWidth, oldHeight: oldHeight)
        let c2 = rotatePoint(CGPoint(x: r.maxX, y: r.maxY), direction: direction, oldWidth: oldWidth, oldHeight: oldHeight)
        let minX = Swift.min(c1.x, c2.x)
        let minY = Swift.min(c1.y, c2.y)
        let maxX = Swift.max(c1.x, c2.x)
        let maxY = Swift.max(c1.y, c2.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func rotateAnnotation(_ annotation: Annotation, direction: RotateDirection, oldWidth: CGFloat, oldHeight: CGFloat) -> Annotation {
        var copy = annotation
        switch annotation.kind {
        case let .rectangle(rect):
            copy.kind = .rectangle(rect: rotateRect(rect, direction: direction, oldWidth: oldWidth, oldHeight: oldHeight))
        case let .highlight(rect):
            copy.kind = .highlight(rect: rotateRect(rect, direction: direction, oldWidth: oldWidth, oldHeight: oldHeight))
        case let .blur(rect, radius):
            copy.kind = .blur(rect: rotateRect(rect, direction: direction, oldWidth: oldWidth, oldHeight: oldHeight), radius: radius)
        case let .arrow(from, to):
            copy.kind = .arrow(
                from: rotatePoint(from, direction: direction, oldWidth: oldWidth, oldHeight: oldHeight),
                to: rotatePoint(to, direction: direction, oldWidth: oldWidth, oldHeight: oldHeight)
            )
        case let .text(rect, string, fontSize):
            // NOTE: The text box is rotated to follow the image, but the glyphs are
            // re-drawn upright inside the new box (no glyph rotation). This is an
            // accepted approximation for 90-degree rotations.
            copy.kind = .text(rect: rotateRect(rect, direction: direction, oldWidth: oldWidth, oldHeight: oldHeight), string: string, fontSize: fontSize)
        case let .freehand(points):
            copy.kind = .freehand(points: points.map { rotatePoint($0, direction: direction, oldWidth: oldWidth, oldHeight: oldHeight) })
        }
        return copy
    }

    /// Produces a 90-degree rotated copy of `image`.
    private static func rotated90(_ image: CGImage, direction: RotateDirection) -> CGImage? {
        let newWidth = image.height
        let newHeight = image.width
        guard newWidth > 0, newHeight > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.translateBy(x: CGFloat(newWidth) / 2, y: CGFloat(newHeight) / 2)
        // CoreGraphics positive rotation is counterclockwise.
        ctx.rotate(by: direction == .right ? -CGFloat.pi / 2 : CGFloat.pi / 2)
        ctx.draw(
            image,
            in: CGRect(
                x: -CGFloat(image.width) / 2,
                y: -CGFloat(image.height) / 2,
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        return ctx.makeImage()
    }

    // MARK: Style mutation

    func setCurrentColor(_ nsColor: NSColor) {
        currentStyle.strokeColor = RGBAColor(nsColor)
        applyStyleToSelection()
        persistPreferences()
    }

    func setCurrentLineWidth(_ w: CGFloat) {
        currentStyle.lineWidth = w
        applyStyleToSelection()
        persistPreferences()
    }

    func setCurrentOpacity(_ o: Double) {
        currentStyle.opacity = o
        applyStyleToSelection()
        persistPreferences()
    }

    func setCurrentBlurRadius(_ radius: CGFloat) {
        currentBlurRadius = radius
        if let id = selectedID,
           let index = annotations.firstIndex(where: { $0.id == id }),
           case let .blur(rect, _) = annotations[index].kind {
            annotations[index].kind = .blur(rect: rect, radius: radius)
        }
        persistPreferences()
    }

    var selectedBlurRadius: CGFloat? {
        guard let id = selectedID,
              let annotation = annotations.first(where: { $0.id == id }),
              case let .blur(_, radius) = annotation.kind else { return nil }
        return radius
    }

    private func applyStyleToSelection() {
        guard selectedID != nil else { return }
        let style = currentStyle
        updateSelected { $0.style = style }
    }

    // MARK: Preferences

    func persistPreferences() {
        if let data = try? JSONEncoder().encode(currentStyle) {
            defaults.set(data, forKey: DefaultsKey.style)
        }
        defaults.set(Double(currentBlurRadius), forKey: DefaultsKey.blurRadius)
        defaults.set(selectedTool.rawValue, forKey: DefaultsKey.lastTool)
    }

    // MARK: Output

    func flattenedCGImage() -> CGImage? {
        AnnotationRenderer.flatten(base: baseImage, annotations: annotations)
    }
}
