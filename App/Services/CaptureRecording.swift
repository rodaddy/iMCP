import AVFoundation
import Foundation
import OSLog
import ScreenCaptureKit

private let log = Logger.service("capture")

/// Receives screen recording frames and writes them via AVAssetWriter.
private class ScreenRecordingOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let assetWriter: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput?
    private var sessionStarted = false

    init(
        assetWriter: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        audioInput: AVAssetWriterInput?
    ) {
        self.assetWriter = assetWriter
        self.videoInput = videoInput
        self.audioInput = audioInput
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard assetWriter.status == .writing else { return }

        if !sessionStarted {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            assetWriter.startSession(atSourceTime: timestamp)
            sessionStarted = true
        }

        switch type {
        case .screen:
            if videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
        case .audio:
            if let audioInput, audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        case .microphone:
            if let audioInput, audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        @unknown default:
            break
        }
    }
}

extension CaptureService {
    @ToolBuilder var recordingTools: [Tool] {
        Tool(
            name: "capture_record_screen",
            description:
                "Record a video of the screen for a specified duration, returned as MP4. Use lower quality or shorter durations for smaller file sizes.",
            inputSchema: .object(
                properties: [
                    "duration": .number(
                        description: "Recording duration in seconds",
                        default: 5,
                        minimum: 1,
                        maximum: 60
                    ),
                    "quality": .string(
                        description: "Recording quality (low=50%, medium=75%, high=100% resolution)",
                        default: "medium",
                        enum: ["low", "medium", "high"]
                    ),
                    "displayId": .number(
                        description:
                            "Display ID to record (uses main display if omitted)",
                        minimum: 0
                    ),
                    "includesCursor": .boolean(
                        description: "Include cursor in recording",
                        default: true
                    ),
                    "captureAudio": .boolean(
                        description: "Include system audio in recording",
                        default: false
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Record Screen",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            // Skip preflight -- CGPreflightScreenCaptureAccess can return stale
            // results after binary replacement. Let SCShareableContent throw if
            // permission is truly missing.
            if !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()
            }

            let duration = arguments["duration"]?.doubleValue ?? 5.0
            let qualityStr = arguments["quality"]?.stringValue ?? "medium"
            let includesCursor = arguments["includesCursor"]?.boolValue ?? true
            let captureAudio = arguments["captureAudio"]?.boolValue ?? false

            let availableContent = try await SCShareableContent.getAvailableContent()

            let display: SCDisplay
            if let displayId = arguments["displayId"]?.intValue {
                guard
                    let d = availableContent.displays.first(where: {
                        $0.displayID == CGDirectDisplayID(displayId)
                    })
                else {
                    throw NSError(
                        domain: "CaptureServiceError", code: 31,
                        userInfo: [NSLocalizedDescriptionKey: "Display not found"])
                }
                display = d
            } else {
                guard let d = availableContent.displays.first else {
                    throw NSError(
                        domain: "CaptureServiceError", code: 32,
                        userInfo: [NSLocalizedDescriptionKey: "No displays available"])
                }
                display = d
            }

            let contentFilter = SCContentFilter(display: display, excludingWindows: [])

            let scaleFactor: CGFloat
            switch qualityStr {
            case "low": scaleFactor = 0.5
            case "high": scaleFactor = 1.0
            default: scaleFactor = 0.75
            }

            let width = Int(CGFloat(display.width) * scaleFactor)
            let height = Int(CGFloat(display.height) * scaleFactor)

            let streamConfig = SCStreamConfiguration()
            streamConfig.width = width
            streamConfig.height = height
            streamConfig.showsCursor = includesCursor
            streamConfig.capturesAudio = captureAudio
            streamConfig.pixelFormat = kCVPixelFormatType_32BGRA

            // Output file
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp4")

            let assetWriter = try AVAssetWriter(url: tempURL, fileType: .mp4)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            let videoInput = AVAssetWriterInput(
                mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            assetWriter.add(videoInput)

            var audioInput: AVAssetWriterInput?
            if captureAudio {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                ]
                let ai = AVAssetWriterInput(
                    mediaType: .audio, outputSettings: audioSettings)
                ai.expectsMediaDataInRealTime = true
                assetWriter.add(ai)
                audioInput = ai
            }

            assetWriter.startWriting()

            let stream = SCStream(
                filter: contentFilter, configuration: streamConfig, delegate: nil)
            let recordingOutput = ScreenRecordingOutput(
                assetWriter: assetWriter,
                videoInput: videoInput,
                audioInput: audioInput
            )

            // Use serial queue to avoid concurrent access to recording state
            let recordingQueue = DispatchQueue(label: "com.rodaddy.iMCP.recording")
            try stream.addStreamOutput(
                recordingOutput, type: .screen, sampleHandlerQueue: recordingQueue)
            if captureAudio {
                try stream.addStreamOutput(
                    recordingOutput, type: .audio, sampleHandlerQueue: recordingQueue)
            }

            // Record for the specified duration
            try await stream.startCapture()
            try await Task.sleep(for: .seconds(duration))
            try await stream.stopCapture()

            // Finish writing
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            await assetWriter.finishWriting()

            guard assetWriter.status == .completed else {
                let errorMsg =
                    assetWriter.error?.localizedDescription ?? "Unknown error"
                throw NSError(
                    domain: "CaptureServiceError", code: 33,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Screen recording failed: \(errorMsg)"
                    ])
            }

            defer { try? FileManager.default.removeItem(at: tempURL) }
            let videoData = try Data(contentsOf: tempURL)

            log.info(
                "Screen recording complete: \(videoData.count) bytes, \(duration)s @ \(width)x\(height)"
            )
            return Value.data(mimeType: "video/mp4", videoData)
        }
    }
}
