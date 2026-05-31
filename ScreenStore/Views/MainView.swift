import SwiftUI

struct MainView: View {
    @EnvironmentObject private var historyStore: HistoryStore
    @EnvironmentObject private var permission: ScreenRecordingPermission
    @State private var selectedItemID: CaptureItem.ID?

    var body: some View {
        NavigationSplitView {
            HistorySidebar(selectedItemID: $selectedItemID)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            VStack(spacing: 0) {
                banners
                PreviewPane(selectedItem: selectedItem)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                CaptureToolbar()
            }
        }
        .navigationTitle("ScreenStore")
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
                message: "ScreenStore でキャプチャを行うには、システム設定の「プライバシーとセキュリティ > 画面収録」で ScreenStore を有効にしてください。",
                tint: .orange,
                primaryAction: (
                    label: "システム設定を開く",
                    action: { permission.openSystemSettings() }
                ),
                secondaryAction: (
                    label: "再確認",
                    action: { permission.refresh() }
                )
            )
        }
    }

    private var selectedItem: CaptureItem? {
        guard let id = selectedItemID else { return nil }
        return historyStore.items.first(where: { $0.id == id })
    }
}

#Preview {
    MainView()
        .environmentObject(HistoryStore())
        .environmentObject(ScreenRecordingPermission())
        .frame(width: 1100, height: 700)
}
