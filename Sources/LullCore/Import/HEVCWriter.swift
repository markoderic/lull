@preconcurrency import AVFoundation
import VideoToolbox

/// Encodes frames with exact timestamps into an HEVC file.
final class HEVCWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    /// `width × height × fps × bpp`. High frame rates need fewer bits per frame, because each frame
    /// differs less from the last.
    static func bitrate(width: Int, height: Int, fps: Double) -> Int {
        let bitsPerPixel = fps <= 30 ? 0.15 : fps <= 60 ? 0.10 : 0.07
        let bitrate = Double(width * height) * fps * bitsPerPixel
        return Int(min(max(bitrate, 1_500_000), 100_000_000))
    }

    init(url: URL, width: Int, height: Int, fps: Double, transform: CGAffineTransform = .identity) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.bitrate(width: width, height: height, fps: fps),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw ImportError.failed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ImportError.failed }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ buffer: CVPixelBuffer, time: Double) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            if writer.status == .failed { throw writer.error ?? ImportError.failed }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600_000)) else {
            throw writer.error ?? ImportError.failed
        }
    }

    /// `duration` makes the last frame hold for its full time, so the file loops at the right length.
    func finish(duration: Double) async throws {
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600_000))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ImportError.failed }
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
    }
}
