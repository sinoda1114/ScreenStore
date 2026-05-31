import SwiftUI
import AppKit

struct PreviewPane: View {
    let selectedItem: CaptureItem?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            if let item = selectedItem {
                PreviewContent(item: item)
            } else {
                ContentUnavailableView(
                    "画像が選択されていません",
                    systemImage: "photo",
                    description: Text("左の履歴から画像を選択するか、ツールバーから新規キャプチャを実行してください。")
                )
            }
        }
    }
}

private struct PreviewContent: View {
    let item: CaptureItem
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(item.fileURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Text("\(Int(item.pixelSize.width))×\(Int(item.pixelSize.height))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
                } label: {
                    Label("Finder で開く", systemImage: "folder")
                }
                .buttonStyle(.borderless)
                .help("保存先を Finder で表示")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(20)
            }
        }
        .task(id: item.id) { await loadImage() }
    }

    private func loadImage() async {
        let url = item.fileURL
        let loaded = await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: url)
        }.value
        await MainActor.run { self.image = loaded }
    }
}
