import Foundation
import CoreGraphics
import AppKit

// MARK: - Coordinate System Convention
//
// All geometry stored in `AnnotationKind` (rects and points) is expressed in
// **image pixel coordinates** with a **top-left origin** (x grows right, y grows
// down). This matches the natural orientation of a `CGImage` as seen on screen.
//
// `lineWidth` and `fontSize` are also expressed in image-pixel units (not points),
// so they scale together with the geometry when the base image is large.
//
// `AnnotationRenderer.flatten` is responsible for flipping into CoreGraphics'
// bottom-left origin space, so callers and follow-up workers must always supply
// top-left coordinates here.

/// The drawing tool currently selected in the editor.
enum AnnotationTool: String, CaseIterable {
    case select
    case rectangle
    case arrow
    case text
    case highlight
    case blur
    case freehand
    case crop
}

/// A `Codable` RGBA color (component values in 0...1) so styles can be persisted
/// without depending on `NSColor`'s archiving. Bridges to/from `NSColor`.
struct RGBAColor: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(_ nsColor: NSColor) {
        let converted = nsColor.usingColorSpace(.sRGB) ?? nsColor
        self.r = Double(converted.redComponent)
        self.g = Double(converted.greenComponent)
        self.b = Double(converted.blueComponent)
        self.a = Double(converted.alphaComponent)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    var cgColor: CGColor {
        nsColor.cgColor
    }
}

/// Visual style shared by all annotation kinds.
struct AnnotationStyle: Codable, Equatable, Hashable {
    var strokeColor: RGBAColor
    var fillColor: RGBAColor?
    var lineWidth: CGFloat
    var opacity: Double

    init(strokeColor: RGBAColor, fillColor: RGBAColor? = nil, lineWidth: CGFloat = 4, opacity: Double = 1) {
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.lineWidth = lineWidth
        self.opacity = opacity
    }
}

/// The geometric payload of an annotation. All coordinates are in image-pixel,
/// top-left-origin space (see the convention note at the top of this file).
enum AnnotationKind: Equatable {
    case rectangle(rect: CGRect)
    case highlight(rect: CGRect)
    case blur(rect: CGRect, radius: CGFloat)
    case arrow(from: CGPoint, to: CGPoint)
    case text(rect: CGRect, string: String, fontSize: CGFloat)
    case freehand(points: [CGPoint])
}

/// A single annotation: identity + geometry + style.
struct Annotation: Identifiable, Equatable {
    let id: UUID
    var kind: AnnotationKind
    var style: AnnotationStyle

    init(id: UUID = UUID(), kind: AnnotationKind, style: AnnotationStyle = Annotation.defaultStyle) {
        self.id = id
        self.kind = kind
        self.style = style
    }

    // MARK: Geometry helpers

    /// The axis-aligned bounding box of the annotation in image-pixel space.
    var boundingBox: CGRect {
        switch kind {
        case let .rectangle(rect),
             let .highlight(rect):
            return rect.standardized
        case let .blur(rect, _):
            return rect.standardized
        case let .text(rect, _, _):
            return rect.standardized
        case let .arrow(from, to):
            let minX = Swift.min(from.x, to.x)
            let minY = Swift.min(from.y, to.y)
            let maxX = Swift.max(from.x, to.x)
            let maxY = Swift.max(from.y, to.y)
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case let .freehand(points):
            guard let first = points.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for p in points.dropFirst() {
                minX = Swift.min(minX, p.x)
                minY = Swift.min(minY, p.y)
                maxX = Swift.max(maxX, p.x)
                maxY = Swift.max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    /// Returns a copy translated by `offset` (positive dy moves down).
    func translated(by offset: CGSize) -> Annotation {
        var copy = self
        copy.kind = AnnotationKind.translate(kind, by: offset)
        return copy
    }

    // MARK: Default styles

    /// Red, line width 4, fully opaque. Suitable for rectangle/arrow/freehand/text.
    static let defaultStyle = AnnotationStyle(
        strokeColor: RGBAColor(r: 1, g: 0, b: 0, a: 1),
        fillColor: nil,
        lineWidth: 4,
        opacity: 1
    )

    /// A translucent yellow fill style for highlight annotations.
    static var highlightStyle: AnnotationStyle {
        AnnotationStyle(
            strokeColor: RGBAColor(r: 1, g: 0.85, b: 0, a: 1),
            fillColor: RGBAColor(r: 1, g: 0.85, b: 0, a: 1),
            lineWidth: 1,
            opacity: 0.35
        )
    }
}

extension AnnotationKind {
    /// Translates a kind's geometry by the given offset.
    static func translate(_ kind: AnnotationKind, by offset: CGSize) -> AnnotationKind {
        switch kind {
        case let .rectangle(rect):
            return .rectangle(rect: rect.offsetBy(dx: offset.width, dy: offset.height))
        case let .highlight(rect):
            return .highlight(rect: rect.offsetBy(dx: offset.width, dy: offset.height))
        case let .blur(rect, radius):
            return .blur(rect: rect.offsetBy(dx: offset.width, dy: offset.height), radius: radius)
        case let .text(rect, string, fontSize):
            return .text(rect: rect.offsetBy(dx: offset.width, dy: offset.height), string: string, fontSize: fontSize)
        case let .arrow(from, to):
            return .arrow(
                from: CGPoint(x: from.x + offset.width, y: from.y + offset.height),
                to: CGPoint(x: to.x + offset.width, y: to.y + offset.height)
            )
        case let .freehand(points):
            return .freehand(points: points.map { CGPoint(x: $0.x + offset.width, y: $0.y + offset.height) })
        }
    }
}
