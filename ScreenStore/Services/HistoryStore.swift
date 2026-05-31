import Foundation
import SwiftUI

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [CaptureItem] = []
    @Published private(set) var initializationError: String?

    func bootstrap() async {
        do {
            try StorageService.shared.prepare()
        } catch {
            initializationError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return
        }

        let loaded = await Task.detached(priority: .userInitiated) {
            StorageService.shared.loadExistingImages()
        }.value
        replaceAll(loaded)
    }

    func prepend(_ item: CaptureItem) {
        items.insert(item, at: 0)
    }

    func replaceAll(_ newItems: [CaptureItem]) {
        items = newItems
    }

    func remove(id: CaptureItem.ID) {
        items.removeAll { $0.id == id }
    }
}
