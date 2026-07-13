import SwiftUI
import AppKit

/// Top-level container for the inline annotation editor: toolbar on top, the
/// interactive canvas filling the rest. The model is created and owned by the
/// caller (PreviewPane integration phase); save/copy/cancel are injected so this
/// view stays free of persistence concerns.
struct AnnotationEditorView: View {
    @ObservedObject var model: AnnotationEditorModel

    var onSave: () -> Void
    var onSaveAs: () -> Void
    var onCopy: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    AnnotationToolbar(
                        model: model,
                        onSave: onSave,
                        onSaveAs: onSaveAs,
                        onCopy: onCopy,
                        onCancel: onCancel
                    )
                    .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 0)
                }
                .padding(.leading, 2)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.bar)

            Divider()

            AnnotationCanvasView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.delete) {
            guard model.selectedID != nil else { return .ignored }
            model.deleteSelected()
            return .handled
        }
        .onDeleteCommand {
            guard model.selectedID != nil else { return }
            model.deleteSelected()
        }
        .onKeyPress(keys: ["z"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            if press.modifiers.contains(.shift) {
                guard model.canRedo else { return .ignored }
                model.redo()
            } else {
                guard model.canUndo else { return .ignored }
                model.undo()
            }
            return .handled
        }
    }
}
