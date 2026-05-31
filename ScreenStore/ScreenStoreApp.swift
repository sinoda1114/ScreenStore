import SwiftUI

@main
struct ScreenStoreApp: App {
    @StateObject private var historyStore = HistoryStore()
    @StateObject private var permission = ScreenRecordingPermission()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(historyStore)
                .environmentObject(permission)
                .frame(minWidth: 920, minHeight: 600)
                .task {
                    await historyStore.bootstrap()
                    permission.refresh()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
