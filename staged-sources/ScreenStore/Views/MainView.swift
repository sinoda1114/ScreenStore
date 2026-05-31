import SwiftUI

struct MainView: View {
    @EnvironmentObject private var historyStore: HistoryStore
    @State private var selectedItemID: CaptureItem.ID?

    var body: some View {
        NavigationSplitView {
            HistorySidebar(selectedItemID: $selectedItemID)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            PreviewPane(selectedItem: selectedItem)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                CaptureToolbar()
            }
        }
        .navigationTitle("ScreenStore")
    }

    private var selectedItem: CaptureItem? {
        guard let id = selectedItemID else { return nil }
        return historyStore.items.first(where: { $0.id == id })
    }
}

#Preview {
    MainView()
        .environmentObject(HistoryStore())
        .frame(width: 1100, height: 700)
}
