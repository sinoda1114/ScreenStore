import SwiftUI
import AppKit
import CoreGraphics

// MARK: - Layout helper

/// Maps between the editor's image-pixel/top-left-origin space and on-screen view
/// points. `scale` is uniform (scaled-to-fit) and `displayRect` is the centered
/// frame the base image occupies inside the container.
private struct CanvasLayout {
    let scale: CGFloat
    let displayRect: CGRect

    init(container: CGSize, pixelSize: CGSize) {
        let safeW = max(pixelSize.width, 1)
        let safeH = max(pixelSize.height, 1)
        let raw = min(container.width / safeW, container.height / safeH)
        let s = (raw.isFinite && raw > 0) ? raw : 1
        let w = pixelSize.width * s
        let h = pixelSize.height * s
        self.scale = s
        self.displayRect = CGRect(
            x: (container.width - w) / 2,
            y: (container.height - h) / 2,
            width: w,
            height: h
        )
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: displayRect.minX + p.x * scale, y: displayRect.minY + p.y * scale)
    }

    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - displayRect.minX) / scale, y: (p.y - displayRect.minY) / scale)
    }

    func toView(_ r: CGRect) -> CGRect {
        let std = r.standardized
        return CGRect(
            x: displayRect.minX + std.minX * scale,
            y: displayRect.minY + std.minY * scale,
            width: std.width * scale,
            height: std.height * scale
        )
    }
}

// MARK: - Canvas

/// Live, interactive drawing surface for the annotation editor. Renders the base
/// image plus every annotation, and turns pointer gestures into model mutations.
/// All persisted geometry stays in image-pixel/top-left-origin space; this view
/// only multiplies by `scale` for display.
struct AnnotationCanvasView: View {
    @ObservedObject var model: AnnotationEditorModel

    /// A resize handle on the selected annotation.
    private enum Handle {
        case topLeft, topRight, bottomLeft, bottomRight
        case arrowFrom, arrowTo
    }

    /// In-flight drag of an existing annotation (move or resize).
    private struct DragSession {
        var origin: Annotation
        var handle: Handle?
        var startImage: CGPoint
        var snapshotted: Bool
    }

    // Draft state for creation tools (image-pixel coordinates).
    @State private var draftStart: CGPoint?
    @State private var draftCurrent: CGPoint?
    @State private var freehandPoints: [CGPoint] = []

    // Selection drag state.
    @State private var dragSession: DragSession?

    // Text editing state.
    @State private var editingTextID: Annotation.ID?
    @FocusState private var textFieldFocused: Bool

    private let handleSize: CGFloat = 9
    private let hitTolerance: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let layout = CanvasLayout(container: geo.size, pixelSize: model.pixelSize)

            ZStack(alignment: .topLeading) {
                baseImageView(layout)
                annotationsLayer(layout)
                draftLayer(layout)
                cropOverlay(layout)
                selectionOverlay(layout)
                textEditorOverlay(layout)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { handleDragChanged($0, layout: layout) }
                    .onEnded { handleDragEnded($0, layout: layout) }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 2)
                    .onEnded { handleDoubleClick(at: $0.location, layout: layout) }
            )
        }
    }

    // MARK: Base image

    @ViewBuilder
    private func baseImageView(_ layout: CanvasLayout) -> some View {
        LayerBackedCGImageView(image: model.baseImage)
            .frame(width: layout.displayRect.width, height: layout.displayRect.height)
            .position(x: layout.displayRect.midX, y: layout.displayRect.midY)
    }

    // MARK: Annotations

    @ViewBuilder
    private func annotationsLayer(_ layout: CanvasLayout) -> some View {
        ForEach(model.annotations) { annotation in
            annotationView(annotation, layout: layout)
        }
    }

    @ViewBuilder
    private func annotationView(_ annotation: Annotation, layout: CanvasLayout) -> some View {
        let style = annotation.style
        let stroke = Color(nsColor: style.strokeColor.nsColor)
        let lineWidth = max(style.lineWidth * layout.scale, 0.5)

        switch annotation.kind {
        case let .rectangle(rect):
            Path { $0.addRect(layout.toView(rect)) }
                .stroke(stroke, lineWidth: lineWidth)
                .opacity(style.opacity)

        case let .highlight(rect):
            let fill = Color(nsColor: (style.fillColor ?? style.strokeColor).nsColor)
            Path { $0.addRect(layout.toView(rect)) }
                .fill(fill)
                .opacity(style.opacity)

        case let .blur(rect, radius):
            blurPreview(rect: rect, radius: radius, layout: layout)

        case let .arrow(from, to):
            arrowPath(from: layout.toView(from), to: layout.toView(to), lineWidth: lineWidth)
                .stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .opacity(style.opacity)

        case let .text(rect, string, fontSize):
            if editingTextID != annotation.id {
                textLabel(string, rect: rect, fontSize: fontSize, style: style, layout: layout)
            }

        case let .freehand(points):
            freehandPath(points.map(layout.toView))
                .stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .opacity(style.opacity)
        }
    }

    @ViewBuilder
    private func textLabel(_ string: String, rect: CGRect, fontSize: CGFloat, style: AnnotationStyle, layout: CanvasLayout) -> some View {
        let viewRect = layout.toView(rect)
        let display = string.isEmpty ? " " : string
        Text(display)
            .font(.system(size: max(fontSize * layout.scale, 1)))
            .foregroundStyle(Color(nsColor: style.strokeColor.nsColor))
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 2)
            .frame(width: viewRect.width, height: viewRect.height, alignment: .topLeading)
            .background {
                if let fill = style.fillColor {
                    Color(nsColor: fill.nsColor).opacity(style.opacity)
                }
            }
            .position(x: viewRect.midX, y: viewRect.midY)
            .opacity(style.opacity)
    }

    @ViewBuilder
    private func blurPreview(rect: CGRect, radius: CGFloat, layout: CanvasLayout) -> some View {
        let viewRect = layout.toView(rect)
        RoundedRectangle(cornerRadius: 2)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(min(0.20 + radius / 160, 0.45)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color(nsColor: .systemBlue).opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
            }
            .frame(width: viewRect.width, height: viewRect.height)
            .position(x: viewRect.midX, y: viewRect.midY)
    }

    // MARK: Draft preview

    @ViewBuilder
    private func draftLayer(_ layout: CanvasLayout) -> some View {
        if let start = draftStart, let current = draftCurrent {
            let stroke = Color(nsColor: model.currentStyle.strokeColor.nsColor)
            let lineWidth = max(model.currentStyle.lineWidth * layout.scale, 0.5)
            switch model.selectedTool {
            case .rectangle:
                Path { $0.addRect(layout.toView(rect(start, current))) }
                    .stroke(stroke, lineWidth: lineWidth)
            case .highlight:
                let hStyle = highlightCreationStyle
                Path { $0.addRect(layout.toView(rect(start, current))) }
                    .fill(Color(nsColor: (hStyle.fillColor ?? hStyle.strokeColor).nsColor))
                    .opacity(hStyle.opacity)
            case .blur:
                blurPreview(rect: rect(start, current), radius: model.currentBlurRadius, layout: layout)
            case .arrow:
                arrowPath(from: layout.toView(start), to: layout.toView(current), lineWidth: lineWidth)
                    .stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            case .freehand:
                freehandPath(freehandPoints.map(layout.toView))
                    .stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            default:
                EmptyView()
            }
        }
    }

    // MARK: Crop overlay

    @ViewBuilder
    private func cropOverlay(_ layout: CanvasLayout) -> some View {
        if let crop = model.cropRect {
            let viewRect = layout.toView(crop)
            ZStack {
                Path { path in
                    path.addRect(layout.displayRect)
                    path.addRect(viewRect)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

                Path { $0.addRect(viewRect) }
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Selection overlay

    @ViewBuilder
    private func selectionOverlay(_ layout: CanvasLayout) -> some View {
        if let id = model.selectedID,
           let annotation = model.annotations.first(where: { $0.id == id }) {
            let box = layout.toView(annotation.boundingBox)
            ZStack {
                Path { $0.addRect(box.insetBy(dx: -2, dy: -2)) }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                ForEach(Array(handlePoints(for: annotation, layout: layout).enumerated()), id: \.offset) { _, point in
                    Path { $0.addRect(CGRect(x: point.x - handleSize / 2, y: point.y - handleSize / 2, width: handleSize, height: handleSize)) }
                        .fill(Color.white)
                    Path { $0.addRect(CGRect(x: point.x - handleSize / 2, y: point.y - handleSize / 2, width: handleSize, height: handleSize)) }
                        .stroke(Color.accentColor, lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Text editing overlay

    @ViewBuilder
    private func textEditorOverlay(_ layout: CanvasLayout) -> some View {
        if let id = editingTextID,
           let annotation = model.annotations.first(where: { $0.id == id }),
           case let .text(rect, _, fontSize) = annotation.kind {
            let viewRect = layout.toView(rect)
            TextField("テキスト", text: textBinding(for: id), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: max(fontSize * layout.scale, 1)))
                .foregroundStyle(Color(nsColor: annotation.style.strokeColor.nsColor))
                .padding(.horizontal, 2)
                .frame(width: max(viewRect.width, 40), alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.85))
                .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                .focused($textFieldFocused)
                .position(x: viewRect.midX, y: viewRect.minY + viewRect.height / 2)
                .onSubmit { endTextEditing() }
                .onExitCommand { endTextEditing() }
                .onAppear { textFieldFocused = true }
        }
    }

    // MARK: Gesture handling

    private func handleDragChanged(_ value: DragGesture.Value, layout: CanvasLayout) {
        switch model.selectedTool {
        case .select:
            handleSelectDrag(value, layout: layout)
        case .rectangle, .highlight, .blur, .arrow:
            if draftStart == nil { draftStart = layout.toImage(value.startLocation) }
            draftCurrent = layout.toImage(value.location)
        case .freehand:
            if draftStart == nil {
                draftStart = layout.toImage(value.startLocation)
                freehandPoints = [layout.toImage(value.startLocation)]
            }
            let p = layout.toImage(value.location)
            freehandPoints.append(p)
            draftCurrent = p
        case .crop:
            if draftStart == nil { draftStart = layout.toImage(value.startLocation) }
            draftCurrent = layout.toImage(value.location)
            model.cropRect = rect(draftStart!, draftCurrent!)
        case .text:
            break // text is created on tap (onEnded)
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value, layout: CanvasLayout) {
        defer { resetDraft() }

        switch model.selectedTool {
        case .select:
            dragSession = nil
            return
        case .text:
            createText(at: layout.toImage(value.location))
            return
        case .crop:
            if let start = draftStart, let current = draftCurrent {
                let crop = rect(start, current)
                if crop.width >= 3, crop.height >= 3 {
                    model.applyCrop(to: crop)
                }
            }
            return
        default:
            break
        }

        guard let start = draftStart, let current = draftCurrent else { return }
        let r = rect(start, current)

        switch model.selectedTool {
        case .rectangle:
            guard r.width >= 3, r.height >= 3 else { return }
            model.add(Annotation(kind: .rectangle(rect: r), style: model.currentStyle))
        case .highlight:
            guard r.width >= 3, r.height >= 3 else { return }
            model.add(Annotation(kind: .highlight(rect: r), style: highlightCreationStyle))
        case .blur:
            guard r.width >= 3, r.height >= 3 else { return }
            model.add(Annotation(kind: .blur(rect: r, radius: model.currentBlurRadius), style: model.currentStyle))
        case .arrow:
            guard hypot(current.x - start.x, current.y - start.y) >= 3 else { return }
            model.add(Annotation(kind: .arrow(from: start, to: current), style: model.currentStyle))
        case .freehand:
            guard freehandPoints.count >= 2 else { return }
            model.add(Annotation(kind: .freehand(points: freehandPoints), style: model.currentStyle))
        default:
            break
        }
    }

    private func handleSelectDrag(_ value: DragGesture.Value, layout: CanvasLayout) {
        let image = layout.toImage(value.location)

        if dragSession == nil {
            let startImage = layout.toImage(value.startLocation)
            var handle: Handle?
            if let selected = selectedAnnotation {
                handle = handleAt(value.startLocation, annotation: selected, layout: layout)
            }
            if handle == nil {
                model.selectedID = hitTest(startImage)
            }
            guard let origin = selectedAnnotation else { return }
            dragSession = DragSession(origin: origin, handle: handle, startImage: startImage, snapshotted: false)
        }

        guard var session = dragSession,
              let index = model.annotations.firstIndex(where: { $0.id == session.origin.id }) else { return }

        let delta = CGSize(width: image.x - session.startImage.x, height: image.y - session.startImage.y)
        guard delta.width != 0 || delta.height != 0 else { return }

        if !session.snapshotted {
            model.snapshot()
            session.snapshotted = true
            dragSession = session
        }

        if let handle = session.handle {
            model.annotations[index] = resized(session.origin, handle: handle, delta: delta)
        } else {
            model.annotations[index] = session.origin.translated(by: delta)
        }
    }

    private func handleDoubleClick(at viewPoint: CGPoint, layout: CanvasLayout) {
        let image = layout.toImage(viewPoint)
        guard let id = hitTest(image),
              let annotation = model.annotations.first(where: { $0.id == id }),
              case .text = annotation.kind else { return }
        model.selectedID = id
        editingTextID = id
    }

    // MARK: Text helpers

    private func createText(at image: CGPoint) {
        let fontSize = max(24, model.pixelSize.height * 0.035)
        let box = CGRect(x: image.x, y: image.y, width: fontSize * 8, height: fontSize * 1.6)
        let annotation = Annotation(kind: .text(rect: box, string: "", fontSize: fontSize), style: model.currentStyle)
        model.add(annotation)
        editingTextID = annotation.id
    }

    private func endTextEditing() {
        // Remove empty text boxes so stray taps don't leave invisible artifacts.
        if let id = editingTextID,
           let annotation = model.annotations.first(where: { $0.id == id }),
           case let .text(_, string, _) = annotation.kind,
           string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.selectedID = id
            model.deleteSelected()
        }
        editingTextID = nil
        textFieldFocused = false
    }

    /// Live binding into the editing text box. Mutates the array directly (no
    /// `snapshot()`) so each keystroke doesn't flood the undo history; the initial
    /// `add` already captured a snapshot.
    private func textBinding(for id: Annotation.ID) -> Binding<String> {
        Binding(
            get: {
                if let a = model.annotations.first(where: { $0.id == id }),
                   case let .text(_, string, _) = a.kind {
                    return string
                }
                return ""
            },
            set: { newValue in
                guard let index = model.annotations.firstIndex(where: { $0.id == id }),
                      case let .text(rect, _, fontSize) = model.annotations[index].kind else { return }
                model.annotations[index].kind = .text(rect: rect, string: newValue, fontSize: fontSize)
            }
        )
    }

    // MARK: Hit testing & handles

    private var selectedAnnotation: Annotation? {
        guard let id = model.selectedID else { return nil }
        return model.annotations.first(where: { $0.id == id })
    }

    /// Returns the front-most annotation whose bounding box contains `image`.
    /// `pad` is a small image-space tolerance so thin shapes stay clickable.
    private func hitTest(_ image: CGPoint) -> Annotation.ID? {
        let pad = hitTolerance
        for annotation in model.annotations.reversed() {
            if annotation.boundingBox.insetBy(dx: -pad, dy: -pad).contains(image) {
                return annotation.id
            }
        }
        return nil
    }

    private func handlePoints(for annotation: Annotation, layout: CanvasLayout) -> [CGPoint] {
        switch annotation.kind {
        case let .arrow(from, to):
            return [layout.toView(from), layout.toView(to)]
        case .freehand:
            return []
        default:
            let box = layout.toView(annotation.boundingBox)
            return [
                CGPoint(x: box.minX, y: box.minY),
                CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.minX, y: box.maxY),
                CGPoint(x: box.maxX, y: box.maxY)
            ]
        }
    }

    private func handleAt(_ viewPoint: CGPoint, annotation: Annotation, layout: CanvasLayout) -> Handle? {
        let tol = handleSize
        switch annotation.kind {
        case let .arrow(from, to):
            if distance(viewPoint, layout.toView(from)) <= tol { return .arrowFrom }
            if distance(viewPoint, layout.toView(to)) <= tol { return .arrowTo }
            return nil
        case .freehand:
            return nil
        default:
            let box = layout.toView(annotation.boundingBox)
            let corners: [(Handle, CGPoint)] = [
                (.topLeft, CGPoint(x: box.minX, y: box.minY)),
                (.topRight, CGPoint(x: box.maxX, y: box.minY)),
                (.bottomLeft, CGPoint(x: box.minX, y: box.maxY)),
                (.bottomRight, CGPoint(x: box.maxX, y: box.maxY))
            ]
            return corners.first(where: { distance(viewPoint, $0.1) <= tol })?.0
        }
    }

    private func resized(_ annotation: Annotation, handle: Handle, delta: CGSize) -> Annotation {
        var copy = annotation
        switch annotation.kind {
        case let .rectangle(r):
            copy.kind = .rectangle(rect: resizeRect(r, handle: handle, delta: delta))
        case let .highlight(r):
            copy.kind = .highlight(rect: resizeRect(r, handle: handle, delta: delta))
        case let .blur(r, radius):
            copy.kind = .blur(rect: resizeRect(r, handle: handle, delta: delta), radius: radius)
        case let .text(r, string, fontSize):
            copy.kind = .text(rect: resizeRect(r, handle: handle, delta: delta), string: string, fontSize: fontSize)
        case let .arrow(from, to):
            switch handle {
            case .arrowFrom:
                copy.kind = .arrow(from: CGPoint(x: from.x + delta.width, y: from.y + delta.height), to: to)
            case .arrowTo:
                copy.kind = .arrow(from: from, to: CGPoint(x: to.x + delta.width, y: to.y + delta.height))
            default:
                break
            }
        case .freehand:
            break
        }
        return copy
    }

    private func resizeRect(_ rect: CGRect, handle: Handle, delta: CGSize) -> CGRect {
        let r = rect.standardized
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case .topLeft:
            minX += delta.width; minY += delta.height
        case .topRight:
            maxX += delta.width; minY += delta.height
        case .bottomLeft:
            minX += delta.width; maxY += delta.height
        case .bottomRight:
            maxX += delta.width; maxY += delta.height
        default:
            break
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    // MARK: Style helpers

    /// ハイライト作成時のスタイル。現在の色 (`currentStyle.strokeColor`) を塗りに使い、
    /// 半透明で塗り潰す。ユーザーが不透明度を下げている場合はそれを尊重し、
    /// 既定 (不透明) のままなら下地が透ける 0.35 にフォールバックする。
    private var highlightCreationStyle: AnnotationStyle {
        let base = model.currentStyle
        let opacity = base.opacity < 1 ? base.opacity : 0.35
        return AnnotationStyle(
            strokeColor: base.strokeColor,
            fillColor: base.strokeColor,
            lineWidth: base.lineWidth,
            opacity: opacity
        )
    }

    // MARK: Geometry utilities

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func resetDraft() {
        draftStart = nil
        draftCurrent = nil
        freehandPoints = []
    }

    private func arrowPath(from: CGPoint, to: CGPoint, lineWidth: CGFloat) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLength = max(lineWidth * 3.5, 10)
        let spread = CGFloat.pi / 7
        let left = CGPoint(x: to.x - cos(angle - spread) * headLength, y: to.y - sin(angle - spread) * headLength)
        let right = CGPoint(x: to.x - cos(angle + spread) * headLength, y: to.y - sin(angle + spread) * headLength)
        path.move(to: to)
        path.addLine(to: left)
        path.move(to: to)
        path.addLine(to: right)
        return path
    }

    private func freehandPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        return path
    }
}

// MARK: - Base image view

private struct LayerBackedCGImageView: NSViewRepresentable {
    let image: CGImage

    func makeNSView(context: Context) -> ImageLayerView {
        let view = ImageLayerView()
        view.image = image
        return view
    }

    func updateNSView(_ nsView: ImageLayerView, context: Context) {
        nsView.image = image
    }
}

private final class ImageLayerView: NSView {
    var image: CGImage? {
        didSet {
            guard image !== oldValue else { return }
            layer?.contents = image
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }
}
