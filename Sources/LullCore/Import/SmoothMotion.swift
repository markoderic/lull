@preconcurrency import VideoToolbox
import CoreMedia
import CoreVideo
import Foundation

/// Generates in-between frames with Apple's frame rate conversion, one pair of source frames at a
/// time, so memory stays flat however long the file is.
public enum SmoothMotion {
    public static var isAvailable: Bool { VTFrameRateConversionConfiguration.isSupported }

    /// Long-held frames can need hundreds of outputs, so they're generated in batches. Each frame
    /// costs 12 bytes per pixel in flight, so larger frames get smaller batches.
    static func batchSize(width: Int, height: Int) -> Int {
        min(16, max(2, 17_000_000 / max(width * height, 1)))
    }

    static func generate(
        from source: FrameSource,
        to writer: HEVCWriter,
        fps: Int,
        progress: (Double) -> Void
    ) async throws {
        typealias Configuration = VTFrameRateConversionConfiguration
        guard Configuration.isSupported,
              let configuration = Configuration(
                  frameWidth: source.width,
                  frameHeight: source.height,
                  usePrecomputedFlow: false,
                  qualityPrioritization: .normal,
                  revision: Configuration.defaultRevision
              ),
              let format = configuration.supportedPixelFormats.first
        else { throw ImportError.smoothMotionUnavailable }

        let processor = VTFrameProcessor()
        try processor.startSession(configuration: configuration)
        defer { processor.endSession() }

        let sourcePool = try PixelBuffers.makePool(
            width: source.width, height: source.height, format: format,
            base: configuration.sourcePixelBufferAttributes
        )
        let destinationPool = try PixelBuffers.makePool(
            width: source.width, height: source.height, format: format,
            base: configuration.destinationPixelBufferAttributes
        )
        let outputPool = try PixelBuffers.makePool(width: source.width, height: source.height, format: kCVPixelFormatType_32BGRA)
        var createdSession: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &createdSession)
        guard let transfer = createdSession else { throw ImportError.smoothMotionFailed }

        func convert(_ buffer: CVPixelBuffer, using pool: CVPixelBufferPool) throws -> CVPixelBuffer {
            let output = try PixelBuffers.make(from: pool)
            guard VTPixelTransferSessionTransferImage(transfer, from: buffer, to: output) == noErr else {
                throw ImportError.smoothMotionFailed
            }
            return output
        }

        let batchSize = batchSize(width: source.width, height: source.height)
        let total = FrameTiming.outputFrameCount(duration: source.duration, fps: fps)
        guard var current = try source.nextFrame() else { throw ImportError.cantOpen }
        let firstFloat = try convert(current.buffer, using: sourcePool)
        var currentFloat = firstFloat
        var isFirstPair = true
        var written = 0

        while true {
            try Task.checkCancellation()
            let next = try source.nextFrame()
            let end = next?.time ?? source.duration
            // The last frame interpolates into the first, so the loop point is smooth too.
            let nextFloat = try next.map { try convert($0.buffer, using: sourcePool) } ?? firstFloat
            let ticks = FrameTiming.ticks(start: current.time, end: end, fps: fps, totalOutputFrames: total)

            for tick in ticks where tick.phase == 0 {
                try await writer.append(current.buffer, time: tick.time)
                written += 1
            }

            let generated = ticks.filter { $0.phase != 0 }
            var startMode: VTFrameRateConversionParameters.SubmissionMode = (isFirstPair || next == nil) ? .random : .sequential
            for batchStart in stride(from: 0, to: generated.count, by: batchSize) {
                try Task.checkCancellation()
                let batch = Array(generated[batchStart..<min(batchStart + batchSize, generated.count)])
                let buffers = try batch.map { _ in try PixelBuffers.make(from: destinationPool) }
                let destinations = zip(batch, buffers).compactMap { tick, buffer in
                    VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: time(tick.time))
                }
                guard let from = VTFrameProcessorFrame(buffer: currentFloat, presentationTimeStamp: time(current.time)),
                      let to = VTFrameProcessorFrame(buffer: nextFloat, presentationTimeStamp: time(end)),
                      let parameters = VTFrameRateConversionParameters(
                          sourceFrame: from,
                          nextFrame: to,
                          opticalFlow: nil,
                          interpolationPhase: batch.map(\.phase),
                          submissionMode: startMode,
                          destinationFrames: destinations
                      )
                else { throw ImportError.smoothMotionFailed }

                try await process(parameters, with: processor)

                for (tick, buffer) in zip(batch, buffers) {
                    try await writer.append(try convert(buffer, using: outputPool), time: tick.time)
                    written += 1
                }
                startMode = .sequentialReferencesUnchanged
            }

            progress(Double(written) / Double(total))
            guard let next else { break }
            current = next
            currentFloat = nextFloat
            isFirstPair = false
        }
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600_000)
    }

    /// In Swift, `process(parameters:)` without a handler returns a lazy stream that does nothing
    /// until consumed, which silently produces black frames. Always use the handler form.
    private static func process(_ parameters: VTFrameRateConversionParameters, with processor: VTFrameProcessor) async throws {
        nonisolated(unsafe) let parameters = parameters
        nonisolated(unsafe) let processor = processor
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            processor.process(parameters: parameters) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
