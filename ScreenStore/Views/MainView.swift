import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import os.log

private let mainViewLog = Logger(subsystem: "com.sinoda.ScreenStore", category: "main-view")

struct MainView: View {
    @EnvironmentObject private var historyStore: HistoryStore
    @EnvironmentObject private var permission: ScreenRecordingPermission

    @State private var editingItemID: CaptureItem.ID?
    @State private var editorModel: AnnotationEditorModel?
    @State private var isPreparingEditor = false
    @State private var editErrorMessage: String?

    var body: some View {
        NavigationSplitView {
            HistorySidebar(selectedIDs: $historyStore.selectedIDs)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            VStack(spacing: 0) {
                banners
                PreviewPane(
                    selectedItem: previewedItem,
                    editingItemID: editingItemID,
                    editorModel: editorModel,
                    isPreparingEditor: isPreparingEditor,
                    onCancelEditing: cancelEditing,
                    onSave: { model in
                        save(model: model)
                    },
                    onSaveAs: { model in
                        saveAs(model: model)
                    },
                    onCopy: { model in
                        copy(model: model)
                    },
                    onBeginEditing: { item in
                        beginEditing(item)
                    },
                    onExportVideoSpeed: { item, speed in
                        try await exportVideoSpeed(item: item, speed: speed)
                    },
                    onDelete: { id in
                        deleteItem(id: id)
                    }
                )
            }
        }
        .toolbar {
            if editingItemID == nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    if let item = previewedItem {
                        if !item.isVideo {
                            Button {
                                beginEditing(item)
                            } label: {
                                Label("編集", systemImage: "pencil.tip.crop.circle")
                            }
                            .help("注釈を付けて編集 (画像をダブルクリックしても開始)")
                        }

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
                        } label: {
                            Label("Finder", systemImage: "folder")
                        }
                        .help("保存先を Finder で表示")

                        Button(role: .destructive) {
                            deleteItem(id: item.id)
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                        .help("この項目をゴミ箱に入れる (⌘Delete)")

                        Divider()
                    }

                    CaptureToolbar()
                }
            }
        }
        .navigationTitle("ScreenStore")
        .alert(
            "エラー",
            isPresented: Binding(
                get: { editErrorMessage != nil },
                set: { if !$0 { editErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { editErrorMessage = nil }
        } message: {
            Text(editErrorMessage ?? "")
        }
    }

    /// PreviewPane のゴミ箱アイコンから 1 枚削除する。HistorySidebar 側の削除と同じく
    /// HistoryStore からの除去 + ゴミ箱への実体移動を行う。
    private func deleteItem(id: CaptureItem.ID) {
        let removed = historyStore.remove(ids: [id])
        StorageService.shared.trashFiles(removed.map { $0.fileURL })
        historyStore.selectedIDs.remove(id)
        if editingItemID == id {
            cancelEditing()
        }
    }

    private func beginEditing(_ item: CaptureItem) {
        guard !item.isVideo else { return }
        editingItemID = item.id
        editorModel = nil
        isPreparingEditor = true
        let url = item.fileURL
        mainViewLog.info("begin editing: \(url.path, privacy: .public)")

        Task { @MainActor in
            let cg = await loadEditableImage(from: url)

            guard editingItemID == item.id else { return }
            isPreparingEditor = false
            guard let cg else {
                mainViewLog.error("failed to load editable image: \(url.path, privacy: .public)")
                editErrorMessage = "編集用の画像を読み込めませんでした。\n\(url.path)"
                cancelEditing()
                return
            }
            editorModel = AnnotationEditorModel(baseImage: cg)
            mainViewLog.info("editor ready: \(cg.width, privacy: .public)x\(cg.height, privacy: .public)")
        }
    }

    private func loadEditableImage(from url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url),
                  let src = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }

            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            return CGImageSourceCreateImageAtIndex(src, 0, options as CFDictionary)
        }.value
    }

    private func cancelEditing() {
        editingItemID = nil
        editorModel = nil
        isPreparingEditor = false
    }

    private func save(model: AnnotationEditorModel) {
        guard let item = previewedItem else { return }
        guard let cg = model.flattenedCGImage() else {
            editErrorMessage = "注釈の合成に失敗しました。"
            return
        }
        do {
            let data = try StorageService.shared.encodePNGData(cg)
            let url = StorageService.shared.editedImageURL(basedOn: item.fileURL)
            try StorageService.shared.writePNGData(data, to: url)
            let newItem = CaptureItem(
                fileURL: url,
                pixelSize: CGSize(width: cg.width, height: cg.height),
                captureMode: .full
            )
            historyStore.prependAndSelect(newItem)
            PasteboardService.writePNG(data: data, fileURL: url, to: .general)
            cancelEditing()
        } catch {
            editErrorMessage = error.localizedDescription
        }
    }

    private func copy(model: AnnotationEditorModel) {
        guard let cg = model.flattenedCGImage() else {
            editErrorMessage = "注釈の合成に失敗しました。"
            return
        }
        do {
            let data = try StorageService.shared.encodePNGData(cg)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.declareTypes([.png], owner: nil)
            pasteboard.setData(data, forType: .png)
        } catch {
            editErrorMessage = error.localizedDescription
        }
    }

    private func saveAs(model: AnnotationEditorModel) {
        guard let item = previewedItem else { return }
        guard let cg = model.flattenedCGImage() else {
            editErrorMessage = "注釈の合成に失敗しました。"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        panel.directoryURL = StorageService.shared.imagesDirectory
        panel.nameFieldStringValue = StorageService.shared.editedImageURL(basedOn: item.fileURL).lastPathComponent

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let ext = url.pathExtension.lowercased()
        do {
            let outputURL: URL
            if url.standardizedFileURL == item.fileURL.standardizedFileURL {
                outputURL = StorageService.shared.editedImageURL(basedOn: item.fileURL)
            } else {
                outputURL = url
            }

            if ext == "jpg" || ext == "jpeg" {
                try writeJPEG(cg, to: outputURL, quality: 0.9)
            } else {
                try StorageService.shared.writePNG(cg, to: outputURL)
            }

            let newItem = CaptureItem(
                fileURL: outputURL,
                pixelSize: CGSize(width: cg.width, height: cg.height),
                captureMode: .full
            )
            historyStore.prependAndSelect(newItem)
            cancelEditing()
        } catch {
            editErrorMessage = error.localizedDescription
        }
    }

    private func exportVideoSpeed(item: CaptureItem, speed: Double) async throws {
        guard item.isVideo else { return }
        let outputURL = StorageService.shared.speedAdjustedVideoURL(basedOn: item.fileURL, speed: speed)
        let exportedURL = try await VideoSpeedExportService.export(
            inputURL: item.fileURL,
            outputURL: outputURL,
            speed: speed
        )
        let newItem = CaptureItem(
            fileURL: exportedURL,
            pixelSize: StorageService.readVideoPixelSize(from: exportedURL) ?? item.pixelSize,
            captureMode: item.captureMode,
            mediaKind: .video
        )
        historyStore.prependAndSelect(newItem)
    }

    private func writeJPEG(_ image: CGImage, to url: URL, quality: CGFloat) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        if !CGImageDestinationFinalize(destination) {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    @ViewBuilder
    private var banners: some View {
        if let error = historyStore.initializationError {
            StatusBanner(
                icon: "exclamationmark.triangle.fill",
                title: "保存先の初期化に失敗しました",
                message: error,
                tint: .red
            )
        }

        if !permission.isGranted {
            StatusBanner(
                icon: "lock.shield",
                title: "画面収録の許可が必要です",
                message: "「許可をリクエスト」を押した後、システム設定の「画面収録とシステムオーディオ録音」で ScreenStore を一度「−」で削除し、「＋」から /Applications/ScreenStore.app を追加し直してから再起動してください。",
                tint: .orange,
                primaryAction: (
                    label: "許可をリクエスト",
                    action: { permission.requestAccessAndOpenSettings() }
                ),
                secondaryAction: (
                    label: "再確認",
                    action: { permission.refresh() }
                )
            )
        }
    }

    /// 複数選択時は履歴の並び順 (新しい順) で先頭に来る選択中アイテムをプレビューする。
    /// 0 件なら nil。
    private var previewedItem: CaptureItem? {
        guard !historyStore.selectedIDs.isEmpty else { return nil }
        return historyStore.items.first(where: { historyStore.selectedIDs.contains($0.id) })
    }
}

#Preview {
    MainView()
        .environmentObject(HistoryStore())
        .environmentObject(ScreenRecordingPermission())
        .environmentObject(ShortcutSettings())
        .environmentObject(CaptureController())
        .frame(width: 1100, height: 700)
}
