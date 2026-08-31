import SwiftUI
import AppKit
import ImageIO
import AVKit

struct PreviewPane: View {
    let selectedItem: CaptureItem?
    let editingItemID: CaptureItem.ID?
    let editorModel: AnnotationEditorModel?
    let isPreparingEditor: Bool
    let onCancelEditing: () -> Void
    let onSave: (AnnotationEditorModel) -> Void
    let onSaveAs: (AnnotationEditorModel) -> Void
    let onCopy: (AnnotationEditorModel) -> Void
    let onBeginEditing: (CaptureItem) -> Void
    let onExportVideoSpeed: (CaptureItem, Double) async throws -> Void
    var onDelete: ((CaptureItem.ID) -> Void)? = nil

    var body: some View {
        Group {
            if let item = selectedItem {
                PreviewContent(
                    item: item,
                    isEditing: editingItemID == item.id,
                    editorModel: editorModel,
                    isPreparingEditor: isPreparingEditor,
                    onCancelEditing: onCancelEditing,
                    onSave: onSave,
                    onSaveAs: onSaveAs,
                    onCopy: onCopy,
                    onBeginEditing: onBeginEditing,
                    onExportVideoSpeed: onExportVideoSpeed
                )
            } else {
                ContentUnavailableView(
                    "画像が選択されていません",
                    systemImage: "photo",
                    description: Text("左の履歴から画像を選択するか、ツールバーから新規キャプチャを実行してください。")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct PreviewContent: View {
    let item: CaptureItem
    let isEditing: Bool
    let editorModel: AnnotationEditorModel?
    let isPreparingEditor: Bool
    let onCancelEditing: () -> Void
    let onSave: (AnnotationEditorModel) -> Void
    let onSaveAs: (AnnotationEditorModel) -> Void
    let onCopy: (AnnotationEditorModel) -> Void
    let onBeginEditing: (CaptureItem) -> Void
    let onExportVideoSpeed: (CaptureItem, Double) async throws -> Void

    @State private var image: NSImage?
    @State private var isLoadingFull = false
    @State private var isExportingSpeed = false
    @State private var speedExportError: String?
    @State private var isShowingCustomSpeed = false
    @State private var customSpeedText = "1.5"

    private static let previewMaxPixel = 1600
    private static let fixedSpeeds: [Double] = [1.25, 1.5, 2, 3]

    var body: some View {
        Group {
            if isEditing {
                if let editorModel {
                    AnnotationEditorView(
                        model: editorModel,
                        onSave: { onSave(editorModel) },
                        onSaveAs: { onSaveAs(editorModel) },
                        onCopy: { onCopy(editorModel) },
                        onCancel: onCancelEditing
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                viewer
            }
        }
    }

    // MARK: - Viewer

    /// 操作ボタンはウィンドウツールバーへ置き、プレビュー領域は画像表示に集中する。
    /// detail 上端は macOS のタイトルバー統合や NavigationSplitView の影響を受けやすいため。
    private var viewer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(item.fileURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 12)

                if !item.isVideo {
                    Button {
                        onBeginEditing(item)
                    } label: {
                        Label("編集", systemImage: "pencil.tip.crop.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .help("注釈を付けて編集")
                } else {
                    speedMenu
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            Group {
                if item.isVideo {
                    AppKitVideoPlayer(url: item.fileURL)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .onTapGesture(count: 2) {
                                onBeginEditing(item)
                            }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .padding(20)
        }
        .task(id: item.id) {
            if item.isVideo {
                image = nil
            } else {
                await loadImage()
            }
        }
        .alert(
            "動画の変換に失敗しました",
            isPresented: Binding(
                get: { speedExportError != nil },
                set: { if !$0 { speedExportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { speedExportError = nil }
        } message: {
            Text(speedExportError ?? "")
        }
        .sheet(isPresented: $isShowingCustomSpeed) {
            CustomSpeedSheet(
                speedText: $customSpeedText,
                onCancel: { isShowingCustomSpeed = false },
                onExport: {
                    guard let speed = Double(customSpeedText), speed > 0.1, speed <= 10 else {
                        speedExportError = String(localized: "video.error.speed_range")
                        isShowingCustomSpeed = false
                        return
                    }
                    isShowingCustomSpeed = false
                    exportSpeed(speed)
                }
            )
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach(Self.fixedSpeeds, id: \.self) { speed in
                Button("\(speedDisplay(speed))倍速で書き出し") {
                    exportSpeed(speed)
                }
            }
            Divider()
            Button("カスタム…") {
                isShowingCustomSpeed = true
            }
        } label: {
            if isExportingSpeed {
                Label("変換中", systemImage: "hourglass")
            } else {
                Label("倍速", systemImage: "speedometer")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(isExportingSpeed)
        .help("動画を倍速に変換して書き出し")
    }

    private func exportSpeed(_ speed: Double) {
        guard !isExportingSpeed else { return }
        isExportingSpeed = true
        Task {
            do {
                try await onExportVideoSpeed(item, speed)
            } catch {
                speedExportError = error.localizedDescription
            }
            isExportingSpeed = false
        }
    }

    /// 1. まずサムネキャッシュを即時表示（クリック直後の体感を速くする）。
    /// 2. その後、表示用に縮小したフル画像を ImageIO で非同期に差し替える。
    /// `NSImage(contentsOf:)` は 5K PNG を丸ごとデコードするため、選択切替で見た目が固まる原因になる。
    private func loadImage() async {
        let url = item.fileURL
        // フル画像と取り違えないようロード途中フラグだけ立てる
        isLoadingFull = true

        if let cached = PreviewImageCache.shared.image(for: url) {
            self.image = cached
            isLoadingFull = false
            return
        }

        // (1) サイドバー用キャッシュ済みサムネを即時プレースホルダに
        if let cached = ThumbnailCache.shared.image(for: url) {
            self.image = cached
        } else {
            self.image = nil
        }

        // (2) 表示用にダウンサンプルしたフル画像を ImageIO で生成
        let loaded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            // プレビュー領域に対して十分かつ過大ではないサイズ（Retina 込み）。
            // 原寸表示や編集用の画像は beginEditing 側で別途読むので、ここは軽さを優先する。
            return ThumbnailLoader.makeThumbnail(url: url, maxPixel: Self.previewMaxPixel)
        }.value

        if Task.isCancelled { return }
        if let loaded {
            PreviewImageCache.shared.set(loaded, for: url)
            self.image = loaded
        }
        isLoadingFull = false
    }

}

private struct CustomSpeedSheet: View {
    @Binding var speedText: String
    var onCancel: () -> Void
    var onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("カスタム倍率")
                .font(.headline)

            TextField("例: 1.8", text: $speedText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)

            HStack {
                Spacer()
                Button("キャンセル", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("書き出し", action: onExport)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 280)
    }
}

private func speedDisplay(_ speed: Double) -> String {
    String(format: "%.2f", speed)
        .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
}

/// プレビュー用の中解像度キャッシュ。サイドバー用サムネとはサイズが違うので分ける。
final class PreviewImageCache: @unchecked Sendable {
    static let shared = PreviewImageCache()

    private let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 64
        return c
    }()

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func set(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

private struct AppKitVideoPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let currentURL = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url
        guard currentURL != url else { return }
        nsView.player = AVPlayer(url: url)
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
