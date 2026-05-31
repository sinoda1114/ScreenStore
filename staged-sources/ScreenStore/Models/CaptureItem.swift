import Foundation
import CoreGraphics

enum CaptureMode: String, Codable {
    case full
    case window
    case region
}

struct CaptureItem: Identifiable, Hashable {
    let id: UUID
    let fileURL: URL
    let createdAt: Date
    let pixelSize: CGSize
    let captureMode: CaptureMode

    init(
        id: UUID = UUID(),
        fileURL: URL,
        createdAt: Date = Date(),
        pixelSize: CGSize,
        captureMode: CaptureMode
    ) {
        self.id = id
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.pixelSize = pixelSize
        self.captureMode = captureMode
    }
}
