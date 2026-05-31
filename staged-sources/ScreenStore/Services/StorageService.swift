import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let baseName = formatter.string(from: date)

        var candidate = imagesDirectory.appendingPathComponent("\(baseName).png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = imagesDirectory.appendingPathComponent("\(baseName)_\(suffix).png")
            suffix += 1
        }
        return candidate
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

    func loadExistingImages() -> [CaptureItem] {
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

        return items.sorted { $0.createdAt > $1.createdAt }
    }

    static func readPixelSize(from url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
