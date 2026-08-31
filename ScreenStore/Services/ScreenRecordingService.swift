import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import os.log

private let screenRecordingLog = Logger(
    subsystem: "com.sinoda.ScreenStore",
    category: "screen-recording"
)

enum ScreenRecordingError: LocalizedError {
    case alreadyRecording
    case notRecording
    case displayNotFound
    case cannotAddOutput(Error)
    case writerSetupFailed(Error)
    case writerFailed(String)
    case noFrames

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return String(localized: "recording.error.already_recording")
        case .notRecording:
            return String(localized: "recording.error.not_recording")
        case .displayNotFound:
            return String(localized: "recording.error.display_not_found")
        case .cannotAddOutput(let error):
            return String.localizedStringWithFormat(
                String(localized: "recording.error.cannot_add_output"),
                error.localizedDescription
            )
        case .writerSetupFailed(let error):
            return String.localizedStringWithFormat(
                String(localized: "recording.error.writer_setup"),
                error.localizedDescription
            )
        case .writerFailed(let message):
            return String.localizedStringWithFormat(
                String(localized: "recording.error.writer_failed"),
                message
            )
        case .noFrames:
            return String(localized: "recording.error.no_frames")
        }
    }
}

final class ScreenRecordingService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let shared = ScreenRecordingService()

    private static let ownBundleIdentifier = "com.sinoda.ScreenStore"
    private let outputQueue = DispatchQueue(label: "com.sinoda.ScreenStore.screen-recording")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var startedSession = false
    private var streamError: Error?

    private override init() {
        super.init()
    }

    func start(
        selection: RegionSelection,
        displayID: CGDirectDisplayID,
        outputURL: URL
    ) async throws -> CGSize {
        guard stream == nil else { throw ScreenRecordingError.alreadyRecording }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.captureFailed(error)
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenRecordingError.displayNotFound
        }

        let excludedApplications = content.applications.filter {
            $0.bundleIdentifier == Self.ownBundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )

        let screenSize = selection.screen.frame.size
        let topLeftRect = RegionMath.screenCaptureKitSourceRect(
            windowLocalRect: selection.rect,
            windowSize: screenSize
        ).intersection(CGRect(origin: .zero, size: screenSize))
        guard !topLeftRect.isNull, topLeftRect.width >= 1, topLeftRect.height >= 1 else {
            throw CaptureError.emptyRegion
        }

        let scale = selection.screen.backingScaleFactor
        let pixelWidth = Self.evenPixelDimension(topLeftRect.width * scale)
        let pixelHeight = Self.evenPixelDimension(topLeftRect.height * scale)
        let pixelSize = CGSize(width: pixelWidth, height: pixelHeight)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = topLeftRect
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = true
        configuration.capturesAudio = false

        let writer: AVAssetWriter
        do {
            try? FileManager.default.removeItem(at: outputURL)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw ScreenRecordingError.writerSetupFailed(error)
        }
        var didStartCapture = false
        defer {
            if !didStartCapture {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        let bitsPerPixel = 6
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: pixelWidth * pixelHeight * bitsPerPixel,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw ScreenRecordingError.writerFailed(String(localized: "recording.error.cannot_add_video_track"))
        }
        writer.add(videoInput)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        } catch {
            throw ScreenRecordingError.cannotAddOutput(error)
        }

        outputQueue.sync {
            self.writer = writer
            self.videoInput = videoInput
            self.startedSession = false
            self.streamError = nil
        }
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            self.stream = nil
            outputQueue.sync {
                self.writer = nil
                self.videoInput = nil
            }
            throw CaptureError.captureFailed(error)
        }

        didStartCapture = true
        return pixelSize
    }

    func stop() async throws {
        guard let stream else { throw ScreenRecordingError.notRecording }
        self.stream = nil

        do {
            try await stream.stopCapture()
        } catch {
            outputQueue.async {
                self.streamError = error
            }
        }

        try await finishWriting()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let writer,
              let videoInput else { return }

        if !startedSession {
            guard writer.startWriting() else {
                streamError = writer.error
                    ?? ScreenRecordingError.writerFailed(String(localized: "recording.error.cannot_start_writing"))
                return
            }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            startedSession = true
        }

        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
        if !videoInput.append(sampleBuffer), streamError == nil {
            streamError = writer.error
                ?? ScreenRecordingError.writerFailed(String(localized: "recording.error.cannot_append_frame"))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        outputQueue.async {
            self.streamError = error
        }
    }

    private func finishWriting() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            outputQueue.async {
                guard let writer = self.writer,
                      let videoInput = self.videoInput else {
                    continuation.resume(throwing: ScreenRecordingError.notRecording)
                    return
                }

                let streamError = self.streamError
                let startedSession = self.startedSession
                self.writer = nil
                self.videoInput = nil
                self.startedSession = false
                self.streamError = nil

                guard startedSession else {
                    writer.cancelWriting()
                    continuation.resume(throwing: streamError ?? ScreenRecordingError.noFrames)
                    return
                }

                videoInput.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        if let streamError {
                            screenRecordingLog.warning(
                                "recording finalized after stream warning: \(String(describing: streamError), privacy: .private)"
                            )
                        }
                        continuation.resume()
                    } else if let streamError {
                        continuation.resume(throwing: streamError)
                    } else {
                        let message = writer.error?.localizedDescription
                            ?? String(localized: "error.unknown")
                        continuation.resume(throwing: ScreenRecordingError.writerFailed(message))
                    }
                }
            }
        }
    }

    private static func evenPixelDimension(_ value: CGFloat) -> Int {
        let rounded = max(2, Int(value.rounded()))
        return rounded.isMultiple(of: 2) ? rounded : rounded - 1
    }
}
