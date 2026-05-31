import SwiftUI
import AppKit

struct HistorySidebar: View {
    @EnvironmentObject private var historyStore: HistoryStore
    @Binding var selectedItemID: CaptureItem.ID?

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
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm:ss"
        return f.string(from: item.createdAt)
    }
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
