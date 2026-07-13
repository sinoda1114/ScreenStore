import Foundation
import AVFoundation

enum VideoSpeedExportError: LocalizedError {
    case invalidSpeed(Double)
    case noTracks
    case cannotCreateExporter
    case exportFailed(String)
    case ffmpegUnavailable
    case speedVerificationFailed(expected: Double, actual: Double)

    var errorDescription: String? {
        switch self {
        case .invalidSpeed(let speed):
            return "倍率が不正です: \(speed)"
        case .noTracks:
            return "動画または音声トラックを読み込めませんでした。"
        case .cannotCreateExporter:
            return "動画の書き出しを開始できませんでした。"
        case .exportFailed(let message):
            return "倍速動画の書き出しに失敗しました。\n\(message)"
        case .ffmpegUnavailable:
            return "ffmpeg が見つかりませんでした。"
        case .speedVerificationFailed(let expected, let actual):
            return "倍速変換後の長さが想定と合いませんでした。\n想定: 約 \(String(format: "%.2f", expected)) 秒\n実際: \(String(format: "%.2f", actual)) 秒"
        }
    }
}

enum VideoSpeedExportService {
    static func export(inputURL: URL, outputURL: URL, speed: Double) async throws -> URL {
        guard speed > 0.1, speed <= 10 else {
            throw VideoSpeedExportError.invalidSpeed(speed)
        }

        if let ffmpegURL = ffmpegExecutableURL() {
            try await exportWithFFmpeg(ffmpegURL: ffmpegURL, inputURL: inputURL, outputURL: outputURL, speed: speed)
            try verifySpeed(inputURL: inputURL, outputURL: outputURL, speed: speed)
            return outputURL
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
                    let message = exporter.error?.localizedDescription ?? "不明なエラー"
                    continuation.resume(throwing: VideoSpeedExportError.exportFailed(message))
                default:
                    continuation.resume(throwing: VideoSpeedExportError.exportFailed("書き出しが完了しませんでした。"))
                }
            }
        }
        try verifySpeed(inputURL: inputURL, outputURL: outputURL, speed: speed)
        return exported
    }

    private static func exportWithFFmpeg(ffmpegURL: URL, inputURL: URL, outputURL: URL, speed: Double) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVURLAsset(url: inputURL)
        let hasAudio = !asset.tracks(withMediaType: .audio).isEmpty

        var arguments = [
            "-y",
            "-i", inputURL.path
        ]

        let speedString = speedArgument(speed)
        if hasAudio {
            arguments += [
                "-filter_complex",
                "[0:v]setpts=PTS/\(speedString)[v];[0:a]\(atempoChain(for: speed))[a]",
                "-map", "[v]",
                "-map", "[a]"
            ]
        } else {
            arguments += [
                "-filter:v", "setpts=PTS/\(speedString)",
                "-an"
            ]
        }

        arguments += [
            "-movflags", "+faststart",
            outputURL.path
        ]

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "ffmpeg がエラーを返しました。"
            throw VideoSpeedExportError.exportFailed(message)
        }
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

    private static func ffmpegExecutableURL() -> URL? {
        [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        .map(URL.init(fileURLWithPath:))
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func speedArgument(_ speed: Double) -> String {
        String(format: "%.6f", speed)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private static func atempoChain(for speed: Double) -> String {
        var remaining = speed
        var parts: [String] = []

        while remaining > 2 {
            parts.append("atempo=2.0")
            remaining /= 2
        }
        while remaining < 0.5 {
            parts.append("atempo=0.5")
            remaining /= 0.5
        }
        parts.append("atempo=\(speedArgument(remaining))")
        return parts.joined(separator: ",")
    }
}
