import Foundation
import AVFoundation

enum VideoSpeedExportError: LocalizedError {
    case invalidSpeed(Double)
    case noTracks
    case cannotCreateExporter
    case exportFailed(String)
    case speedVerificationFailed(expected: Double, actual: Double)

    var errorDescription: String? {
        switch self {
        case .invalidSpeed(let speed):
            return String.localizedStringWithFormat(
                String(localized: "video.error.invalid_speed"),
                speed
            )
        case .noTracks:
            return String(localized: "video.error.no_tracks")
        case .cannotCreateExporter:
            return String(localized: "video.error.cannot_create_exporter")
        case .exportFailed(let message):
            return String.localizedStringWithFormat(
                String(localized: "video.error.export_failed"),
                message
            )
        case .speedVerificationFailed(let expected, let actual):
            return String.localizedStringWithFormat(
                String(localized: "video.error.verification_failed"),
                expected,
                actual
            )
        }
    }
}

enum VideoSpeedExportService {
    static func export(inputURL: URL, outputURL: URL, speed: Double) async throws -> URL {
        guard speed > 0.1, speed <= 10 else {
            throw VideoSpeedExportError.invalidSpeed(speed)
        }

        let asset = AVURLAsset(url: inputURL)
        let duration = asset.duration
        let tracks = asset.tracks
        guard !tracks.isEmpty, duration.seconds.isFinite, duration.seconds > 0 else {
            throw VideoSpeedExportError.noTracks
        }

        let composition = AVMutableComposition()
        let fullRange = CMTimeRange(start: .zero, duration: duration)
        let scaledDuration = CMTimeMultiplyByFloat64(duration, multiplier: 1 / speed)

        for sourceTrack in tracks {
            guard let targetTrack = composition.addMutableTrack(
                withMediaType: sourceTrack.mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }

            try targetTrack.insertTimeRange(fullRange, of: sourceTrack, at: .zero)
            targetTrack.scaleTimeRange(fullRange, toDuration: scaledDuration)
            targetTrack.preferredTransform = sourceTrack.preferredTransform
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoSpeedExportError.cannotCreateExporter
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = true

        let exported = try await withCheckedThrowingContinuation { continuation in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume(returning: outputURL)
                case .failed, .cancelled:
                    let message = exporter.error?.localizedDescription
                        ?? String(localized: "error.unknown")
                    continuation.resume(throwing: VideoSpeedExportError.exportFailed(message))
                default:
                    continuation.resume(throwing: VideoSpeedExportError.exportFailed(
                        String(localized: "video.error.export_incomplete")
                    ))
                }
            }
        }
        try verifySpeed(inputURL: inputURL, outputURL: outputURL, speed: speed)
        return exported
    }

    private static func verifySpeed(inputURL: URL, outputURL: URL, speed: Double) throws {
        let inputDuration = durationSeconds(of: inputURL)
        let outputDuration = durationSeconds(of: outputURL)
        guard inputDuration.isFinite, outputDuration.isFinite, inputDuration > 0, outputDuration > 0 else { return }

        let expected = inputDuration / speed
        let tolerance = max(0.35, expected * 0.08)
        guard abs(outputDuration - expected) <= tolerance else {
            throw VideoSpeedExportError.speedVerificationFailed(expected: expected, actual: outputDuration)
        }
    }

    private static func durationSeconds(of url: URL) -> Double {
        AVURLAsset(url: url).duration.seconds
    }

}
