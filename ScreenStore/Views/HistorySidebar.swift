import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os.log

private let sidebarLog = Logger(subsystem: "com.sinoda.ScreenStore", category: "sidebar")

struct HistorySidebar: View {
    @EnvironmentObject private var historyStore: HistoryStore
    @Binding var selectedItemID: CaptureItem.ID?

    @State private var pasteErrorMessage: String?
    @State private var showPasteError = false

    var body: some View {
        Group {
            if historyStore.items.isEmpty {
                ContentUnavailableView(
                    "履歴なし",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("ツールバーから全画面キャプチャを実行すると履歴に追加されます。")
                )
            } else {
                List(selection: $selectedItemID) {
                    ForEach(historyStore.items) { item in
                        HistoryRow(item: item)
                            .tag(Optional(item.id))
                    }
                }
                .listStyle(.sidebar)
            }
        }
        // メニュー (Cmd+C / Cmd+V) からこのサイドバーを駆動するためのハンドラ公開。
        // 選択が無い時は copyImageHandler は nil → Copy メニューが自動的に disabled になる。
        .focusedSceneValue(\.copyImageHandler, selectedCopyHandler)
        .focusedSceneValue(\.pasteImageHandler, pasteHandler)
        .alert("ペーストに失敗しました", isPresented: $showPasteError, presenting: pasteErrorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Clipboard handlers

    private var selectedItem: CaptureItem? {
        guard let id = selectedItemID else { return nil }
        return historyStore.items.first(where: { $0.id == id })
    }

    private var selectedCopyHandler: (() -> Void)? {
        guard let item = selectedItem else { return nil }
        return {
            copyToPasteboard(item: item)
        }
    }

    private var pasteHandler: () -> Void {
        return {
            do {
                let png = try PasteboardService.extractPNG(from: .general)
                try persistPasted(pngData: png)
            } catch {
                pasteErrorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                showPasteError = true
                sidebarLog.error("paste failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func copyToPasteboard(item: CaptureItem) {
        do {
            let encoded = try PasteboardService.encode(item: item)
            PasteboardService.write(encoded, to: .general)
            sidebarLog.info("copied to pasteboard: \(item.fileURL.path, privacy: .public)")
        } catch {
            pasteErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            showPasteError = true
            sidebarLog.error("copy failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func persistPasted(pngData: Data) throws {
        try StorageService.shared.prepare()
        let url = StorageService.shared.nextImageURL()
        try pngData.write(to: url)
        let size = PasteboardService.pixelSize(forPNG: pngData) ?? .zero
        let item = CaptureItem(
            fileURL: url,
            createdAt: Date(),
            pixelSize: size,
            captureMode: .full
        )
        historyStore.prepend(item)
        selectedItemID = item.id
        sidebarLog.info("pasted from pasteboard: \(url.path, privacy: .public) \(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public)")
    }
}

private struct HistoryRow: View {
    let item: CaptureItem

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(url: item.fileURL)
                .frame(width: 56, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(formattedDate)
                    .font(.subheadline)
                Text("\(Int(item.pixelSize.width))×\(Int(item.pixelSize.height))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onDrag { dragProvider(for: item) }
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm:ss"
        return f.string(from: item.createdAt)
    }
}

/// 行を外部アプリへドラッグするための NSItemProvider を生成する。
/// PNG のファイル URL 表現を public.png として登録することで、
/// Finder / Chrome / Cursor / メーラーいずれでも素直に「画像ファイル」として受け取れる。
private func dragProvider(for item: CaptureItem) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.suggestedName = item.fileURL.deletingPathExtension().lastPathComponent
    provider.registerFileRepresentation(
        forTypeIdentifier: UTType.png.identifier,
        fileOptions: [],
        visibility: .all
    ) { completion in
        completion(item.fileURL, true, nil)
        return nil
    }
    return provider
}

private struct ThumbnailView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary.opacity(0.5))
                    )
            }
        }
        .task(id: url) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        let target = url
        let thumb = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let original = NSImage(contentsOf: target) else { return nil }
            let size = NSSize(width: 168, height: 108)
            let thumb = NSImage(size: size)
            thumb.lockFocus()
            original.draw(
                in: NSRect(origin: .zero, size: size),
                from: .zero,
                operation: .copy,
                fraction: 1.0
            )
            thumb.unlockFocus()
            return thumb
        }.value
        await MainActor.run { self.image = thumb }
    }
}
