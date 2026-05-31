import Foundation
import SwiftUI

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [CaptureItem] = []

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
