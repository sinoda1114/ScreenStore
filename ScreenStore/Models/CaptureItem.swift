import Foundation
import CoreGraphics

enum CaptureMode: String, Codable {
    case full
    case window
    case region
    case regionRecording
}

enum CaptureMediaKind: String, Codable {
    case image
    case video
}

struct CaptureItem: Identifiable, Hashable {
    let id: UUID
    let fileURL: URL
    let createdAt: Date
    let pixelSize: CGSize
    let captureMode: CaptureMode
    let mediaKind: CaptureMediaKind

    init(
        id: UUID = UUID(),
        fileURL: URL,
        createdAt: Date = Date(),
        pixelSize: CGSize,
        captureMode: CaptureMode,
        mediaKind: CaptureMediaKind = .image
    ) {
        self.id = id
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.pixelSize = pixelSize
        self.captureMode = captureMode
        self.mediaKind = mediaKind
    }

    var isVideo: Bool {
        mediaKind == .video
    }
}
