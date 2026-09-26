import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import os.log
import AVFoundation

private let sidebarLog = Logger(subsystem: "com.sinoda.ScreenStore", category: "sidebar")

struct HistorySidebar: View {
    @EnvironmentObject private var historyStore: HistoryStore
    @Binding var selectedIDs: Set<CaptureItem.ID>

    @State private var pasteErrorMessage: String?
    @State private var showPasteError = false
    @State private var selectionAnchorID: CaptureItem.ID?

    var body: some View {
        Group {
            if historyStore.items.isEmpty {
                ContentUnavailableView(
                    "履歴なし",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("ツールバーから全画面キャプチャを実行すると履歴に追加されます。")
                )
            } else {
                // 行は List が、サムネイルは select(_:modifiers:) が選択を処理する。
                List(selection: $selectedIDs) {
                    ForEach(historyStore.items) { item in
                        HistoryRow(item: item) { modifiers in
                            select(item, modifiers: modifiers)
                        }
                        .tag(item.id)
                    }
                }
                .listStyle(.sidebar)
                // 右クリックメニュー: 右クリックされた行が選択中ならその選択集合に対して、
                // そうでなければ右クリック行 1 つに対してアクション可能。
                .contextMenu(forSelectionType: CaptureItem.ID.self) { ids in
                    contextMenuButtons(for: ids)
                }
                // List に focus がある状態で Delete キーを押したらゴミ箱へ
                .onDeleteCommand {
                    deleteSelected()
                }
            }
        }
        // メニュー (Cmd+C / Cmd+X / Cmd+V / Cmd+Delete) からこのサイドバーを駆動する focused-value を公開。
        .focusedSceneValue(\.copyImageHandler, selectedCopyHandler)
        .focusedSceneValue(\.cutImageHandler, selectedCutHandler)
        .focusedSceneValue(\.pasteImageHandler, pasteHandler)
        .focusedSceneValue(\.deleteImageHandler, selectedDeleteHandler)
        .alert("ペーストに失敗しました", isPresented: $showPasteError, presenting: pasteErrorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }

    private func select(_ item: CaptureItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift) {
            let ids = historyStore.items.map(\.id)
            let anchor = selectionAnchorID.flatMap { selectedIDs.contains($0) && ids.contains($0) ? $0 : nil }
                ?? ids.first(where: { selectedIDs.contains($0) })
                ?? item.id
            guard let start = ids.firstIndex(of: anchor),
                  let end = ids.firstIndex(of: item.id) else { return }
            let range = Set(ids[min(start, end)...max(start, end)])
            selectedIDs = modifiers.contains(.command) ? selectedIDs.union(range) : range
        } else if modifiers.contains(.command) {
            if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
            selectionAnchorID = item.id
        } else {
            selectedIDs = [item.id]
            selectionAnchorID = item.id
        }
    }

    /// `.contextMenu(forSelectionType:)` から渡される ID 集合に対してアクションを提供する。
    /// 行を右クリックしたとき、その行が現在の選択集合に含まれていれば `ids` は集合全体、
    /// 含まれていなければ `ids` はその 1 行だけになる。
    @ViewBuilder
    private func contextMenuButtons(for ids: Set<CaptureItem.ID>) -> some View {
        let items = historyStore.items.filter { ids.contains($0.id) }
        if items.isEmpty {
            EmptyView()
        } else {
            Button("画像をコピー") {
                copyToPasteboard(items: items)
            }
            Button("画像を切り取り") {
                cutToPasteboard(items: items)
            }
            Divider()
            Button("Finder で表示") {
                NSWorkspace.shared.activateFileViewerSelecting(items.map { $0.fileURL })
            }
            Divider()
            Button("ゴミ箱に入れる", role: .destructive) {
                delete(ids: ids)
            }
        }
    }

    // MARK: - Clipboard handlers

    /// 選択中のアイテムを履歴の並び順 (新しい順) で返す。
    private var selectedItemsInOrder: [CaptureItem] {
        historyStore.items.filter { selectedIDs.contains($0.id) }
    }

    private var selectedCopyHandler: (() -> Void)? {
        let items = selectedItemsInOrder
        guard !items.isEmpty else { return nil }
        return {
            copyToPasteboard(items: items)
        }
    }

    private var selectedCutHandler: (() -> Void)? {
        let items = selectedItemsInOrder
        guard !items.isEmpty else { return nil }
        return {
            cutToPasteboard(items: items)
        }
    }

    private var selectedDeleteHandler: (() -> Void)? {
        guard !selectedIDs.isEmpty else { return nil }
        return {
            deleteSelected()
        }
    }

    private var pasteHandler: () -> Void {
        return {
            do {
                let pngs = try PasteboardService.extractAllPNGs(from: .general)
                try persistPasted(pngDataList: pngs)
            } catch {
                pasteErrorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                showPasteError = true
                sidebarLog.error("paste failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func copyToPasteboard(items: [CaptureItem]) {
        PasteboardService.writeItems(items, to: .general)
        sidebarLog.info("copied \(items.count, privacy: .public) item(s) to pasteboard")
    }

    /// 切り取り = クリップボードにコピー → 履歴とファイル本体をゴミ箱へ。
    /// 標準 macOS Finder では Cut そのものは無いが、本アプリでは「履歴から外しつつ
    /// 別アプリに貼り付ける」用途で 1 アクションにまとめる。
    private func cutToPasteboard(items: [CaptureItem]) {
        copyToPasteboard(items: items)
        let ids = Set(items.map { $0.id })
        delete(ids: ids)
    }

    /// 現在の `selectedIDs` をまとめてゴミ箱へ。
    private func deleteSelected() {
        delete(ids: selectedIDs)
    }

    /// 指定 ID の履歴をストアから外し、ファイル本体をゴミ箱に移動する。
    /// 削除後に選択をクリアする (プレビューも自動的に空に戻る)。
    private func delete(ids: Set<CaptureItem.ID>) {
        guard !ids.isEmpty else { return }
        let removed = historyStore.remove(ids: ids)
        let urls = removed.map { $0.fileURL }
        let moved = StorageService.shared.trashFiles(urls)
        // 選択集合からも消す (未選択行を右クリックで削除した場合は元々入っていない)
        selectedIDs.subtract(ids)
        sidebarLog.info("trashed \(moved.count, privacy: .public)/\(removed.count, privacy: .public) item(s)")
    }

    /// 1 件以上の PNG を順に保存し、まとめて履歴の先頭に積む。
    /// 直近に貼り付けた N 件をそのまま選択状態にする (連続でのコピー等を楽にする)。
    private func persistPasted(pngDataList: [Data]) throws {
        try StorageService.shared.prepare()
        var newIDs: Set<CaptureItem.ID> = []
        for png in pngDataList {
            let url = StorageService.shared.nextImageURL()
            try png.write(to: url)
            let size = PasteboardService.pixelSize(forPNG: png) ?? .zero
            let item = CaptureItem(
                fileURL: url,
                createdAt: Date(),
                pixelSize: size,
                captureMode: .full
            )
            historyStore.prepend(item)
            newIDs.insert(item.id)
            sidebarLog.info("pasted: \(url.path, privacy: .public) \(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public)")
        }
        selectedIDs = newIDs
    }
}

private struct HistoryRow: View {
    let item: CaptureItem
    let select: (NSEvent.ModifierFlags) -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(item: item)
                .frame(width: 56, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
                .onTapGesture {
                    select(NSEvent.modifierFlags)
                }
                .onDrag { HistoryDragProvider.make(for: item) }
                .help("ドラッグしてファイルを渡す")
            VStack(alignment: .leading, spacing: 2) {
                Text(formattedDate)
                    .font(.subheadline)
                Text("\(Int(item.pixelSize.width))×\(Int(item.pixelSize.height))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var formattedDate: String {
        Self.dateFormatter.string(from: item.createdAt)
    }
}

enum HistoryDragProvider {
    static func make(for item: CaptureItem) -> NSItemProvider {
        sidebarLog.info("sidebar file drag started")
        // ブラウザのアップロード欄へ渡すため、ファイル URL と実ファイル表現の両方を提供する。
        let provider = NSItemProvider(object: item.fileURL as NSURL)
        provider.suggestedName = item.fileURL.lastPathComponent
        let contentType = UTType(filenameExtension: item.fileURL.pathExtension)
            ?? (item.isVideo ? .movie : .image)
        provider.registerFileRepresentation(
            forTypeIdentifier: contentType.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(item.fileURL, true, nil)
            return nil
        }
        return provider
    }
}

private struct ThumbnailView: View {
    let item: CaptureItem
    @State private var image: NSImage?

    /// 表示は 56x36 pt。Retina 2x で 112x72、念のため少し余裕を持って 192 px に。
    /// ImageIO 側で長辺基準にリサイズされる。
    private static let maxPixel = 192

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
                        Image(systemName: item.isVideo ? "film" : "photo")
                            .foregroundStyle(.secondary.opacity(0.5))
                    )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if item.isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.65), in: Circle())
                    .padding(3)
            }
        }
        .task(id: item.fileURL) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        let target = item.fileURL
        if let cached = ThumbnailCache.shared.image(for: target) {
            self.image = cached
            return
        }
        let maxPixel = Self.maxPixel
        let isVideo = item.isVideo
        let thumb = await Task.detached(priority: .utility) { () -> NSImage? in
            isVideo
                ? ThumbnailLoader.makeVideoThumbnail(url: target, maxPixel: maxPixel)
                : ThumbnailLoader.makeThumbnail(url: target, maxPixel: maxPixel)
        }.value
        if Task.isCancelled { return }
        if let thumb {
            ThumbnailCache.shared.set(thumb, for: target)
        }
        self.image = thumb
    }
}

/// ImageIO で原画像をフルデコードせず、必要サイズのサムネだけを生成する。
/// `NSImage(contentsOf:)` は 5K キャプチャを丸ごと展開してしまい行表示に対して重すぎるため、
/// CGImageSource 経由のサムネ生成で大幅に軽くする。
enum ThumbnailLoader {
    static func makeThumbnail(url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func makeVideoThumbnail(url: URL, maxPixel: Int) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// URL をキーにしたサムネイルキャッシュ。`NSCache` 自身がスレッドセーフ。
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 512
        return c
    }()

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func set(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}
