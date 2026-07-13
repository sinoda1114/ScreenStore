import Foundation
import AppKit
import CoreGraphics
import CoreText
import CoreImage

/// Flattens a base image plus a list of annotations into a single `CGImage`.
///
/// Coordinate convention (see `Annotation.swift`): annotations are stored in
/// image-pixel, **top-left-origin** space. CoreGraphics draws in bottom-left
/// origin, so we flip the context once up front (`translateBy` + `scaleBy(y: -1)`)
/// and then draw everything using top-left coordinates directly.
enum AnnotationRenderer {

    static func flatten(base: CGImage, annotations: [Annotation]) -> CGImage? {
        let width = base.width
        let height = base.height
        guard width > 0, height > 0 else { return nil }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpace(name: CGColorSpace.genericRGBLinear) else {
            return nil
        }

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Draw the base image in native (bottom-left) orientation first.
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))

        for annotation in annotations {
            if case let .blur(rect, radius) = annotation.kind {
                drawBlur(rect: rect, radius: radius, base: base, in: ctx)
            }
        }

        // Flip into top-left-origin space so annotation coordinates map directly.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        for annotation in annotations {
            if case .blur = annotation.kind { continue }
            draw(annotation, in: ctx, imageHeight: height)
        }

        return ctx.makeImage()
    }

    // MARK: - Per-kind drawing

    private static func draw(_ annotation: Annotation, in ctx: CGContext, imageHeight: Int) {
        let style = annotation.style
        switch annotation.kind {
        case let .rectangle(rect):
            ctx.saveGState()
            ctx.setAlpha(CGFloat(style.opacity))
            if let fill = style.fillColor {
                ctx.setFillColor(fill.cgColor)
                ctx.fill(rect)
            }
            ctx.setStrokeColor(style.strokeColor.cgColor)
            ctx.setLineWidth(style.lineWidth)
            ctx.stroke(rect)
            ctx.restoreGState()

        case let .highlight(rect):
            ctx.saveGState()
            ctx.setAlpha(CGFloat(style.opacity))
            let fill = style.fillColor ?? style.strokeColor
            ctx.setFillColor(fill.cgColor)
            ctx.fill(rect)
            ctx.restoreGState()

        case .blur:
            break

        case let .arrow(from, to):
            drawArrow(from: from, to: to, style: style, in: ctx)

        case let .text(rect, string, fontSize):
            drawText(string, in: rect, fontSize: fontSize, style: style, ctx: ctx, imageHeight: imageHeight)

        case let .freehand(points):
            drawFreehand(points: points, style: style, in: ctx)
        }
    }

    private static func drawBlur(rect: CGRect, radius: CGFloat, base: CGImage, in ctx: CGContext) {
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let topLeftRect = rect.standardized.intersection(bounds).integral
        guard !topLeftRect.isNull, topLeftRect.width >= 1, topLeftRect.height >= 1 else { return }

        let cropRect = CGRect(
            x: topLeftRect.minX,
            y: CGFloat(base.height) - topLeftRect.maxY,
            width: topLeftRect.width,
            height: topLeftRect.height
        ).integral

        let input = CIImage(cgImage: base)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(radius, 0), forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: cropRect) else { return }

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        guard let blurred = ciContext.createCGImage(output, from: cropRect) else { return }

        ctx.saveGState()
        ctx.draw(blurred, in: cropRect)
        ctx.restoreGState()
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, style: AnnotationStyle, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setAlpha(CGFloat(style.opacity))
        ctx.setStrokeColor(style.strokeColor.cgColor)
        ctx.setFillColor(style.strokeColor.cgColor)
        ctx.setLineWidth(style.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let dx = to.x - from.x
        let dy = to.y - from.y
        let angle = atan2(dy, dx)

        // Head size scales with line width.
        let headLength = max(style.lineWidth * 4, 12)
        let headWidth = max(style.lineWidth * 3, 9)

        // Shorten the shaft so it ends at the base of the arrow head.
        let shaftEnd = CGPoint(
            x: to.x - cos(angle) * headLength,
            y: to.y - sin(angle) * headLength
        )

        ctx.move(to: from)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        // Triangular head at the destination point.
        let perpX = -sin(angle) * (headWidth / 2)
        let perpY = cos(angle) * (headWidth / 2)
        let base1 = CGPoint(x: shaftEnd.x + perpX, y: shaftEnd.y + perpY)
        let base2 = CGPoint(x: shaftEnd.x - perpX, y: shaftEnd.y - perpY)

        ctx.move(to: to)
        ctx.addLine(to: base1)
        ctx.addLine(to: base2)
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawFreehand(points: [CGPoint], style: AnnotationStyle, in ctx: CGContext) {
        guard let first = points.first else { return }
        ctx.saveGState()
        ctx.setAlpha(CGFloat(style.opacity))
        ctx.setStrokeColor(style.strokeColor.cgColor)
        ctx.setLineWidth(style.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: first)
        for p in points.dropFirst() {
            ctx.addLine(to: p)
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawText(
        _ string: String,
        in rect: CGRect,
        fontSize: CGFloat,
        style: AnnotationStyle,
        ctx: CGContext,
        imageHeight: Int
    ) {
        ctx.saveGState()
        ctx.setAlpha(CGFloat(style.opacity))

        // The context is currently in top-left-origin (flipped) space. AppKit text
        // drawing expects to manage its own flip, so push an NSGraphicsContext that
        // is `flipped: true` to keep top-left coordinates consistent.
        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: true)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = nsContext

        if let fill = style.fillColor {
            ctx.setFillColor(fill.cgColor)
            ctx.fill(rect)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: style.strokeColor.nsColor,
            .paragraphStyle: paragraph
        ]
        if let fill = style.fillColor {
            attributes[.backgroundColor] = fill.nsColor
        }

        let attrString = NSAttributedString(string: string, attributes: attributes)
        attrString.draw(in: rect)

        NSGraphicsContext.current = previous
        ctx.restoreGState()
    }
}
