import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// クリップボード経由で CaptureItem の PNG / ファイル URL を出し入れする純粋関数群。
/// 副作用ある呼び出し (NSPasteboard 直接) と、テストできる純粋関数とを分離する。
enum PasteboardService {

    // MARK: - Copy (出力)

    /// CaptureItem を「エンコード済みの中間表現」にする純粋関数。
    /// 失敗するのは PNG が読めない時のみ。
    static func encode(item: CaptureItem) throws -> EncodedImage {
        let data = try Data(contentsOf: item.fileURL)
        return EncodedImage(pngData: data, fileURL: item.fileURL)
    }

    /// EncodedImage を NSPasteboard に書き込む。
    /// `.png` の生データと `.fileURL` の URL 表現を両方公開する。
    static func write(_ encoded: EncodedImage, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .fileURL], owner: nil)
        pasteboard.setData(encoded.pngData, forType: .png)
        // setString(.fileURL) は file:// URL の絶対文字列を要求する。
        pasteboard.setString(encoded.fileURL.absoluteString, forType: .fileURL)
    }

    /// 既にメモリ上にある PNG バイト列とファイル URL をそのままクリップボードに書く。
    /// キャプチャ直後にファイルを再読込せず即時貼り付け可能にしたい hot path 用。
    static func writePNG(data: Data, fileURL: URL, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .fileURL], owner: nil)
        pasteboard.setData(data, forType: .png)
        pasteboard.setString(fileURL.absoluteString, forType: .fileURL)
    }

    /// 複数の CaptureItem をクリップボードに書き出す。
    /// - 1 件のときは PNG バイト列 + ファイル URL を従来どおり書き、画像エディタやチャット欄が
    ///   そのまま画像として貼り付けられるようにする。
    /// - 複数件のときは NSURL を `writeObjects` で全件書き、Finder / Mail / Cursor などが
    ///   「複数ファイル」として受け取れるようにする (pasteboard 規格上、複数 PNG の生データを
    ///   同時に置く方法はないため、ファイル URL を真とする)。
    static func writeItems(_ items: [CaptureItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        if items.count == 1 {
            if items[0].isVideo {
                pasteboard.writeObjects([items[0].fileURL as NSURL])
                return
            }
            if let encoded = try? encode(item: items[0]) {
                pasteboard.declareTypes([.png, .fileURL], owner: nil)
                pasteboard.setData(encoded.pngData, forType: .png)
                pasteboard.setString(encoded.fileURL.absoluteString, forType: .fileURL)
                return
            }
        }
        // 複数: NSURL の writeObjects で全件
        let urls = items.map { $0.fileURL as NSURL }
        pasteboard.writeObjects(urls)
    }

    // MARK: - Paste (入力)

    /// NSPasteboard から取り出した raw データを 1 ステップで PNG バイト列に変換する。
    static func extractPNG(from pasteboard: NSPasteboard) throws -> Data {
        guard let source = readSource(from: pasteboard) else {
            throw PasteError.noImageOnPasteboard
        }
        return try toPNGData(source)
    }

    /// クリップボード上にある画像を全部取り出して PNG バイト列の配列にする。
    /// - 複数の画像ファイル URL があれば全件読む
    /// - URL が 1 件もなく単一画像データしか無いときは 1 件として返す
    /// - 何も無ければ空配列ではなく throws (UI 側でメッセージを出すため)
    static func extractAllPNGs(from pasteboard: NSPasteboard) throws -> [Data] {
        // 1) 複数ファイル URL を最優先で扱う
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let imageURLs = urls.filter { isImageFile(url: $0) }
            if imageURLs.count >= 2 {
                return try imageURLs.map { url in
                    try toPNGData(.fileURL(url))
                }
            }
        }
        // 2) 単一: 既存ロジック
        let single = try extractPNG(from: pasteboard)
        return [single]
    }

    /// NSPasteboard から取り出した「画像ソース」。テスト容易性のため public。
    enum PasteSource: Equatable {
        case pngData(Data)
        case tiffData(Data)
        case jpegData(Data)
        case fileURL(URL)
    }

    /// 副作用境界: NSPasteboard から PasteSource を 1 つ取り出す。
    static func readSource(from pasteboard: NSPasteboard) -> PasteSource? {
        let types = pasteboard.types ?? []

        if types.contains(.png), let data = pasteboard.data(forType: .png) {
            return .pngData(data)
        }
        if types.contains(.tiff), let data = pasteboard.data(forType: .tiff) {
            return .tiffData(data)
        }
        // JPEG (com.compuserve.gif / public.jpeg) は明示的 type で来ることがある
        let jpegType = NSPasteboard.PasteboardType("public.jpeg")
        if types.contains(jpegType), let data = pasteboard.data(forType: jpegType) {
            return .jpegData(data)
        }
        // 画像系のファイル URL
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first(where: { isImageFile(url: $0) }) {
            return .fileURL(url)
        }
        return nil
    }

    /// 純粋: PasteSource を PNG バイト列に変換する。
    /// ファイル URL 経由のときだけ I/O が発生する。
    static func toPNGData(_ source: PasteSource) throws -> Data {
        switch source {
        case .pngData(let data):
            return data

        case .tiffData(let tiff):
            return try convertImageDataToPNG(tiff)

        case .jpegData(let jpeg):
            return try convertImageDataToPNG(jpeg)

        case .fileURL(let url):
            let data = try Data(contentsOf: url)
            if url.pathExtension.lowercased() == "png" {
                return data
            }
            return try convertImageDataToPNG(data)
        }
    }

    /// 純粋: PNG バイト列のピクセル寸法を読む。
    static func pixelSize(forPNG data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: w, height: h)
    }

    /// 純粋: ファイル URL の拡張子から「画像ファイルか」を判定。
    static func isImageFile(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["png", "tiff", "tif", "jpg", "jpeg", "gif", "bmp", "heic", "webp"].contains(ext)
    }

    // MARK: - 内部ヘルパ

    private static func convertImageDataToPNG(_ data: Data) throws -> Data {
        guard let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:])
        else {
            throw PasteError.cannotConvert
        }
        return png
    }

    // MARK: - 型

    struct EncodedImage: Equatable {
        var pngData: Data
        var fileURL: URL
    }

    enum PasteError: LocalizedError {
        case noImageOnPasteboard
        case cannotConvert

        var errorDescription: String? {
            switch self {
            case .noImageOnPasteboard:
                return "クリップボードに画像が見つかりませんでした。"
            case .cannotConvert:
                return "クリップボード上のデータを PNG に変換できませんでした。"
            }
        }
    }
}
