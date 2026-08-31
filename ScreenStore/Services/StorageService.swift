import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import AVFoundation

enum StorageError: LocalizedError {
    case directoryCreationFailed(URL, underlying: Error)
    case fileWriteFailed(URL, underlying: Error)
    case pngEncodingFailed(URL)

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let url, let err):
            return "ディレクトリ作成に失敗: \(url.path)\n\(err.localizedDescription)"
        case .fileWriteFailed(let url, let err):
            return "ファイル書き出しに失敗: \(url.path)\n\(err.localizedDescription)"
        case .pngEncodingFailed(let url):
            return "PNG エンコードに失敗: \(url.path)"
        }
    }
}

final class StorageService {
    static let shared = StorageService()

    let baseDirectory: URL
    let imagesDirectory: URL
    let videosDirectory: URL

    convenience init() {
        self.init(baseDirectory: Self.defaultBaseDirectory())
    }

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        self.imagesDirectory = baseDirectory.appendingPathComponent("images", isDirectory: true)
        self.videosDirectory = baseDirectory.appendingPathComponent("videos", isDirectory: true)
    }

    static func defaultBaseDirectory() -> URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("ScreenStore", isDirectory: true)
    }

    func prepare() throws {
        for url in [baseDirectory, imagesDirectory, videosDirectory] {
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
            } catch {
                throw StorageError.directoryCreationFailed(url, underlying: error)
            }
        }
    }

    func nextImageURL(for date: Date = Date()) -> URL {
        nextURL(in: imagesDirectory, fileExtension: "png", for: date)
    }

    func nextVideoURL(for date: Date = Date()) -> URL {
        nextURL(in: imagesDirectory, fileExtension: "mov", for: date)
    }

    private func nextURL(in directory: URL, fileExtension: String, for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let baseName = formatter.string(from: date)

        var candidate = directory.appendingPathComponent("\(baseName).\(fileExtension)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)_\(suffix).\(fileExtension)")
            suffix += 1
        }
        return candidate
    }

    /// 元画像の URL を基に、ベース名へ `_edited` を付けた imagesDirectory 配下の
    /// 衝突しない URL を返す。注釈エディタの「保存」で元画像と紐づく名前を残すため。
    func editedImageURL(basedOn source: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = imagesDirectory.appendingPathComponent("\(base)_edited.png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = imagesDirectory.appendingPathComponent("\(base)_edited_\(suffix).png")
            suffix += 1
        }
        return candidate
    }

    func speedAdjustedVideoURL(basedOn source: URL, speed: Double) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let speedLabel = Self.speedLabel(speed)
        var candidate = imagesDirectory.appendingPathComponent("\(base)_\(speedLabel)x.mov")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = imagesDirectory.appendingPathComponent("\(base)_\(speedLabel)x_\(suffix).mov")
            suffix += 1
        }
        return candidate
    }

    private static func speedLabel(_ speed: Double) -> String {
        let formatted = String(format: "%.2f", speed)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        return formatted.replacingOccurrences(of: ".", with: "_")
    }

    func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw StorageError.pngEncodingFailed(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw StorageError.pngEncodingFailed(url)
        }
    }

    /// CGImage を PNG バイト列にエンコードするだけ (ディスクには書かない)。
    /// 「クリップボードへ即座に貼り、続けてファイルにも書く」というキャプチャの hot path 用。
    func encodePNGData(_ image: CGImage) throws -> Data {
        let mutable = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutable as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw StorageError.pngEncodingFailed(URL(fileURLWithPath: "<memory>"))
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw StorageError.pngEncodingFailed(URL(fileURLWithPath: "<memory>"))
        }
        return mutable as Data
    }

    /// 既にメモリ上にある PNG バイト列をディスクに書き出す。
    /// `encodePNGData` で生成した Data をそのまま渡す想定。
    func writePNGData(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw StorageError.fileWriteFailed(url, underlying: error)
        }
    }

    func loadExistingImages() -> [CaptureItem] {
        loadExistingMedia()
            .filter { $0.mediaKind == .image }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.fileURL.lastPathComponent > rhs.fileURL.lastPathComponent
                }
                return lhs.createdAt > rhs.createdAt
            }
    }

    func loadExistingMedia() -> [CaptureItem] {
        loadExistingImageItems() + loadExistingVideoItems()
    }

    /// 外部アプリから追加・削除されたファイルとの差分確認用。
    /// 画像のデコードは行わず、対象拡張子の URL だけを軽量に列挙する。
    func existingMediaFileURLs() -> Set<URL> {
        let fm = FileManager.default
        let imageEntries = (try? fm.contentsOfDirectory(
            at: imagesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let legacyVideoEntries = (try? fm.contentsOfDirectory(
            at: videosDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let imageDirectoryMedia = imageEntries.filter {
            ["png", "mov", "mp4", "m4v"].contains($0.pathExtension.lowercased())
        }
        let legacyVideos = legacyVideoEntries.filter {
            ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased())
        }
        return Set(imageDirectoryMedia + legacyVideos)
    }

    /// 差分監視で新しく見つかった URL だけを CaptureItem に変換する。
    /// 書き込み途中でサイズを読めないファイルは次回の照合まで保留する。
    func loadMediaItems(at urls: [URL]) -> [CaptureItem] {
        urls.compactMap { url in
            let attrs = try? url.resourceValues(forKeys: [
                .creationDateKey,
                .contentModificationDateKey
            ])
            let createdAt = attrs?.creationDate
                ?? attrs?.contentModificationDate
                ?? Date(timeIntervalSince1970: 0)

            switch url.pathExtension.lowercased() {
            case "png":
                guard let pixelSize = Self.readPixelSize(from: url) else { return nil }
                return CaptureItem(
                    fileURL: url,
                    createdAt: createdAt,
                    pixelSize: pixelSize,
                    captureMode: .full
                )
            case "mov", "mp4", "m4v":
                guard let pixelSize = Self.readVideoPixelSize(from: url) else { return nil }
                return CaptureItem(
                    fileURL: url,
                    createdAt: createdAt,
                    pixelSize: pixelSize,
                    captureMode: .regionRecording,
                    mediaKind: .video
                )
            default:
                return nil
            }
        }
    }

    private func loadExistingImageItems() -> [CaptureItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: imagesDirectory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let pngs = entries.filter { $0.pathExtension.lowercased() == "png" }
        let items: [CaptureItem] = pngs.compactMap { url in
            let attrs = try? url.resourceValues(forKeys: [
                .creationDateKey,
                .contentModificationDateKey
            ])
            let createdAt = attrs?.creationDate
                ?? attrs?.contentModificationDate
                ?? Date(timeIntervalSince1970: 0)
            let pixelSize = Self.readPixelSize(from: url) ?? .zero
            return CaptureItem(
                fileURL: url,
                createdAt: createdAt,
                pixelSize: pixelSize,
                captureMode: .full
            )
        }

        return items
    }

    private func loadExistingVideoItems() -> [CaptureItem] {
        let fm = FileManager.default
        let directories = [imagesDirectory, videosDirectory]
        let entries = directories.flatMap { directory in
            (try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        guard !entries.isEmpty else {
            return []
        }

        let videos = entries.filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }
        return videos.map { url in
            let attrs = try? url.resourceValues(forKeys: [
                .creationDateKey,
                .contentModificationDateKey
            ])
            let createdAt = attrs?.creationDate
                ?? attrs?.contentModificationDate
                ?? Date(timeIntervalSince1970: 0)
            let pixelSize = Self.readVideoPixelSize(from: url) ?? .zero
            return CaptureItem(
                fileURL: url,
                createdAt: createdAt,
                pixelSize: pixelSize,
                captureMode: .regionRecording,
                mediaKind: .video
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// 指定 URL 群をユーザーのゴミ箱に移動する。
    /// 失敗したパスはサイレントに飛ばす (一部だけ削除に失敗してもアプリの履歴は前へ進めたいため)。
    /// - Returns: 実際にゴミ箱へ移動できた URL の配列
    @discardableResult
    func trashFiles(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var moved: [URL] = []
        for url in urls {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                moved.append(url)
            } catch {
                // ファイルが既に存在しない等。続行。
                continue
            }
        }
        return moved
    }

    static func readPixelSize(from url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    static func readVideoPixelSize(from url: URL) -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let transformed = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }
}
