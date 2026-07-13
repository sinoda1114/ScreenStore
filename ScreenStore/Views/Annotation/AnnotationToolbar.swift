import SwiftUI
import AppKit

/// Horizontal control strip for the inline annotation editor.
struct AnnotationToolbar: View {
    @ObservedObject var model: AnnotationEditorModel

    var onSave: () -> Void
    var onSaveAs: () -> Void
    var onCopy: () -> Void
    var onCancel: () -> Void

    @State private var hoverHelp: String?

    private static let tools: [(AnnotationTool, String, String)] = [
        (.select, "cursorarrow", "選択 / 移動 / サイズ変更"),
        (.rectangle, "rectangle", "四角形を描く"),
        (.arrow, "arrow.up.right", "矢印を描く"),
        (.text, "textformat", "テキストを追加"),
        (.highlight, "highlighter", "半透明のハイライトを描く"),
        (.blur, "eye.slash", "範囲をぼかす"),
        (.freehand, "scribble", "フリーハンドで描く"),
        (.crop, "crop", "トリミング範囲を選択")
    ]

    var body: some View {
        HStack(spacing: 3) {
            toolPicker

            Divider().frame(height: 22)

            iconButton(systemName: "rotate.left", help: "左に90度回転") { model.rotate(.left) }
            iconButton(systemName: "rotate.right", help: "右に90度回転") { model.rotate(.right) }

            Divider().frame(height: 22)

            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 40)
                .trackHoverHelp("線・塗りの色", hoverHelp: $hoverHelp)

            styleSlider(title: "線の太さ", systemImage: "lineweight", value: lineWidthBinding, range: 1...30)
            if isBlurControlActive {
                styleSlider(title: "ぼかし強度", systemImage: "circle.lefthalf.filled", value: blurRadiusBinding, range: 2...40)
            } else {
                styleSlider(title: "不透明度", systemImage: "circle.lefthalf.filled", value: opacityBinding, range: 0...1)
            }

            Divider().frame(height: 22)

            iconButton(systemName: "arrow.uturn.backward", help: "元に戻す (⌘Z)", disabled: !model.canUndo) { model.undo() }
            iconButton(systemName: "arrow.uturn.forward", help: "やり直し (⇧⌘Z)", disabled: !model.canRedo) { model.redo() }

            iconButton(
                systemName: "square.2.layers.3d.bottom.filled",
                help: "選択中を背面へ（重なり順を下げる）",
                disabled: model.selectedID == nil
            ) { model.bringBackward() }
            iconButton(
                systemName: "square.2.layers.3d.top.filled",
                help: "選択中を前面へ（重なり順を上げる）",
                disabled: model.selectedID == nil
            ) { model.bringForward() }

            Button(role: .destructive) { model.deleteSelected() } label: {
                Image(systemName: "trash")
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(model.selectedID == nil)
            .trackHoverHelp("選択中を削除 (Delete)", hoverHelp: $hoverHelp)

            Divider().frame(height: 22)

            helpButton(help: "クリップボードにコピー（保存しない）", action: onCopy) {
                Label("コピー", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 26)
            }

            helpButton(help: "元画像を残して別名で保存 (PNG / JPEG)", action: onSaveAs) {
                saveAsLabel
                    .frame(width: 28, height: 26)
            }

            helpButton(help: "元画像を残してコピー保存し、履歴に追加＋クリップボードへ (⌘S)", action: onSave) {
                FloppySaveIcon()
                    .frame(width: 28, height: 26)
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)

            helpButton(help: "編集を閉じる（未保存の注釈は破棄）", action: onCancel) {
                Label("閉じる", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 26)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: - 保存 / 別名保存（macOS テンプレート＝フロッピー系）

    private var saveLabel: some View {
        templateIcon(Self.saveTemplate, pointSize: 18)
    }

    private var saveAsLabel: some View {
        templateIcon(Self.saveAsTemplate, pointSize: 18)
    }

    private func templateIcon(_ image: NSImage, pointSize: CGFloat) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: pointSize, height: pointSize)
    }

    private static var saveTemplate: NSImage {
        sizedTemplate(named: "NSSaveTemplate", pointSize: 18, fallbackSymbol: "square.and.arrow.down")
    }

    private static var saveAsTemplate: NSImage {
        sizedTemplate(named: "NSSaveAsTemplate", pointSize: 18, fallbackSymbol: "square.on.square")
    }

    private static func sizedTemplate(named name: String, pointSize: CGFloat, fallbackSymbol: String) -> NSImage {
        let img: NSImage
        if let t = NSImage(named: NSImage.Name(name)) {
            t.isTemplate = true
            img = t
        } else if let sym = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: nil) {
            sym.isTemplate = true
            img = sym
        } else {
            img = NSImage(size: NSSize(width: pointSize, height: pointSize))
        }
        img.size = NSSize(width: pointSize, height: pointSize)
        return img
    }

    // MARK: - Tool picker

    private var toolPicker: some View {
        HStack(spacing: 2) {
            ForEach(Self.tools, id: \.0) { tool, symbol, label in
                Button { model.selectedTool = tool } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .background {
                    if model.selectedTool == tool {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accentColor.opacity(0.22))
                    }
                }
                .trackHoverHelp(label, hoverHelp: $hoverHelp)
            }
        }
        .frame(width: 260)
    }

    private func iconButton(
        systemName: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .trackHoverHelp(help, hoverHelp: $hoverHelp)
    }

    private func helpButton<Label: View>(
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action, label: label)
            .buttonStyle(.borderless)
            .disabled(disabled)
            .trackHoverHelp(help, hoverHelp: $hoverHelp)
    }

    @ViewBuilder
    private func styleSlider(
        title: String,
        systemImage: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 26)
                .trackHoverHelp(title, hoverHelp: $hoverHelp)
            Slider(value: value, in: range)
                .frame(width: 90)
                .trackHoverHelp(title, hoverHelp: $hoverHelp)
        }
    }

    // MARK: Bindings

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: model.currentStyle.strokeColor.nsColor) },
            set: { model.setCurrentColor(NSColor($0)) }
        )
    }

    private var lineWidthBinding: Binding<Double> {
        Binding(
            get: { Double(model.currentStyle.lineWidth) },
            set: { model.setCurrentLineWidth(CGFloat($0)) }
        )
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { model.currentStyle.opacity },
            set: { model.setCurrentOpacity($0) }
        )
    }

    private var isBlurControlActive: Bool {
        model.selectedTool == .blur || model.selectedBlurRadius != nil
    }

    private var blurRadiusBinding: Binding<Double> {
        Binding(
            get: { Double(model.selectedBlurRadius ?? model.currentBlurRadius) },
            set: { model.setCurrentBlurRadius(CGFloat($0)) }
        )
    }
}

// MARK: - ホバー説明（ツールバー上段へ即表示）

private struct HoverHelpModifier: ViewModifier {
    let text: String
    @Binding var hoverHelp: String?

    func body(content: Content) -> some View {
        content
            .help(text)
    }
}

private extension View {
    func trackHoverHelp(_ text: String, hoverHelp: Binding<String?>) -> some View {
        modifier(HoverHelpModifier(text: text, hoverHelp: hoverHelp))
    }
}

private struct FloppySaveIcon: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 22
            context.translateBy(x: (size.width - 22 * scale) / 2, y: (size.height - 22 * scale) / 2)
            context.scaleBy(x: scale, y: scale)

            let outer = RoundedRectangle(cornerRadius: 3)
                .path(in: CGRect(x: 3, y: 2, width: 16, height: 18))
            context.fill(outer, with: .color(.primary))

            let label = Path(CGRect(x: 6, y: 4, width: 9, height: 6))
            context.fill(label, with: .color(Color(nsColor: .controlBackgroundColor)))

            let notch = Path(CGRect(x: 14, y: 4, width: 2, height: 5))
            context.fill(notch, with: .color(Color(nsColor: .controlBackgroundColor)))

            let window = RoundedRectangle(cornerRadius: 1.5)
                .path(in: CGRect(x: 7, y: 13, width: 8, height: 5))
            context.fill(window, with: .color(Color(nsColor: .controlBackgroundColor)))
        }
        .accessibilityLabel("保存")
    }
}
