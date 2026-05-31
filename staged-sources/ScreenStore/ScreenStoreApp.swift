import SwiftUI

@main
struct ScreenStoreApp: App {
    @StateObject private var historyStore = HistoryStore()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(historyStore)
                .frame(minWidth: 920, minHeight: 600)
                .task {
                    await historyStore.bootstrap()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
