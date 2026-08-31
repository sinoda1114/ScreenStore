import Foundation
import SwiftUI
import AppKit
import os.log

private let historyStoreLog = Logger(subsystem: "com.sinoda.ScreenStore", category: "history-store")

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [CaptureItem] = []
    @Published private(set) var initializationError: String?

    /// サイドバーの選択状態。MainView の @State から HistoryStore に持ち上げたのは、
    /// CaptureToolbar 等の「履歴を変更する側」が選択もまとめて更新できるようにするため
    /// (キャプチャ直後の自動選択 / 自動コピーで古いアイテムを誤ペーストする問題対策)。
    @Published var selectedIDs: Set<CaptureItem.ID> = []

    private var directoryWatchSource: DispatchSourceFileSystemObject?
    private var directoryWatchDescriptor: CInt = -1
    private var refreshTask: Task<Void, Never>?
    private var periodicRefreshTask: Task<Void, Never>?
    private var isReconcilingWithDisk = false
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    deinit {
        directoryWatchSource?.cancel()
        refreshTask?.cancel()
        periodicRefreshTask?.cancel()
    }

    func bootstrap() async {
        do {
            try StorageService.shared.prepare()
        } catch {
            initializationError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return
        }

        await reloadFromDisk(preserveSelection: false)
        startWatchingStorageDirectory()
        startPeriodicStorageRefresh()

        // 起動直後に何も選択されていないと右ペインが空のままになる。
        // 履歴があれば先頭（最新）を自動選択し、すぐプレビュー（と編集導線）を見せる。
        if selectedIDs.isEmpty, let first = items.first {
            selectedIDs = [first.id]
        }
    }

    func prepend(_ item: CaptureItem) {
        items.insert(item, at: 0)
    }

    /// 履歴の先頭に追加して、そのまま単一選択状態にする。
    /// キャプチャ直後にこれを呼ぶことで、ユーザーが「直前に選んでいた古い行」を ⌘C で
    /// 誤って拾ってしまう問題を防ぐ。
    func prependAndSelect(_ item: CaptureItem) {
        prepend(item)
        selectedIDs = [item.id]
    }

    func replaceAll(_ newItems: [CaptureItem]) {
        items = newItems
    }

    func reloadFromDisk(preserveSelection: Bool = true) async {
        let previousSelectedURLs = Set(
            items
                .filter { selectedIDs.contains($0.id) }
                .map(\.fileURL)
        )

        let diskItems = await Task.detached(priority: .userInitiated) {
            StorageService.shared.loadExistingMedia()
                .sorted { $0.createdAt > $1.createdAt }
        }.value
        syncWithDiskItems(diskItems)

        if preserveSelection {
            let preservedIDs = Set(items.filter { previousSelectedURLs.contains($0.fileURL) }.map(\.id))
            if !preservedIDs.isEmpty {
                selectedIDs = preservedIDs
                return
            }
        }

        if selectedIDs.isEmpty || !items.contains(where: { selectedIDs.contains($0.id) }) {
            selectedIDs = items.first.map { [$0.id] } ?? []
        }
    }

    private func syncWithDiskItems(_ diskItems: [CaptureItem]) {
        let existingByURL = Dictionary(uniqueKeysWithValues: items.map { ($0.fileURL, $0) })
        let merged = diskItems.map { diskItem in
            existingByURL[diskItem.fileURL] ?? diskItem
        }
        items = merged
    }

    func remove(id: CaptureItem.ID) {
        items.removeAll { $0.id == id }
    }

    /// 複数 ID をまとめて履歴から外す。実ファイル削除は呼び出し側 (StorageService.trashFiles) の責務。
    /// - Returns: 履歴から外した CaptureItem たち (ファイル URL 取得用)
    @discardableResult
    func remove(ids: Set<CaptureItem.ID>) -> [CaptureItem] {
        guard !ids.isEmpty else { return [] }
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        return removed
    }

    private func startWatchingStorageDirectory() {
        directoryWatchSource?.cancel()
        if directoryWatchDescriptor >= 0 {
            close(directoryWatchDescriptor)
            directoryWatchDescriptor = -1
        }

        let path = StorageService.shared.imagesDirectory.path
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        directoryWatchDescriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReloadFromDisk()
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.directoryWatchDescriptor >= 0 else { return }
            close(self.directoryWatchDescriptor)
            self.directoryWatchDescriptor = -1
        }
        source.resume()
        directoryWatchSource = source
    }

    private func scheduleReloadFromDisk() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await reconcileWithDisk()
        }
    }

    /// Vnode 通知は外部アプリの保存方法によって取りこぼすことがあるため、
    /// 定期的な差分照合を併用して一覧が止まったままになるのを防ぐ。
    private func startPeriodicStorageRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.reconcileWithDisk()
            }
        }
    }

    private func reconcileWithDisk() async {
        guard !isReconcilingWithDisk else { return }
        isReconcilingWithDisk = true
        defer { isReconcilingWithDisk = false }

        let diskURLs = await Task.detached(priority: .utility) {
            StorageService.shared.existingMediaFileURLs()
        }.value
        let existingURLs = Set(items.map(\.fileURL))
        guard diskURLs != existingURLs else { return }

        let addedURLs = Array(diskURLs.subtracting(existingURLs))
        let addedItems = await Task.detached(priority: .utility) {
            StorageService.shared.loadMediaItems(at: addedURLs)
        }.value
        let retainedItems = items.filter { diskURLs.contains($0.fileURL) }
        items = (retainedItems + addedItems).sorted { $0.createdAt > $1.createdAt }

        if !selectAndCopyNewestAddedItem(from: addedItems),
           !items.contains(where: { selectedIDs.contains($0.id) }) {
            selectedIDs = items.first.map { [$0.id] } ?? []
        }
    }

    /// macOS 純正スクリーンショットなど、保存フォルダーへ外部から追加された最新画像を
    /// 選択し、そのまま ⌘V できるようクリップボードにも載せる。
    /// 動画は履歴で選択するだけにして、既存のクリップボードを上書きしない。
    @discardableResult
    func selectAndCopyNewestAddedItem(from addedItems: [CaptureItem]) -> Bool {
        guard let newestAddedItem = addedItems.max(by: { $0.createdAt < $1.createdAt }) else {
            return false
        }

        selectedIDs = [newestAddedItem.id]
        guard !newestAddedItem.isVideo else { return true }

        PasteboardService.writeItems([newestAddedItem], to: pasteboard)
        historyStoreLog.info("external image auto-copied: \(newestAddedItem.fileURL.path, privacy: .public)")
        return true
    }
}
