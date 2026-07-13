import Foundation
import SwiftUI

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [CaptureItem] = []
    @Published private(set) var initializationError: String?

    /// サイドバーの選択状態。MainView の @State から HistoryStore に持ち上げたのは、
    /// CaptureToolbar 等の「履歴を変更する側」が選択もまとめて更新できるようにするため
    /// (キャプチャ直後の自動選択 / 自動コピーで古いアイテムを誤ペーストする問題対策)。
    @Published var selectedIDs: Set<CaptureItem.ID> = []

    func bootstrap() async {
        do {
            try StorageService.shared.prepare()
        } catch {
            initializationError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return
        }

        let loaded = await Task.detached(priority: .userInitiated) {
            StorageService.shared.loadExistingMedia()
                .sorted { $0.createdAt > $1.createdAt }
        }.value
        replaceAll(loaded)

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
}
