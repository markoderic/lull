@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import LullCore

/// Builds real media files for the import tests.
enum TestMedia {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lull-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeStore() throws -> WallpaperStore {
        WallpaperStore(root: try temporaryDirectory(), moveToTrash: { url in
            try FileManager.default.removeItem(at: url)
        })
    }

    static func makeGIF(
        _ name: String = "test.gif",
        width: Int = 160,
        height: Int = 90,
        delays: [Double],
        draw: (CGContext, Int) -> Void
    ) throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, delays.count, nil)!
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for (index, delay) in delays.enumerated() {
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            draw(context, index)
            CGImageDestinationAddImage(destination, context.makeImage()!, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination), "CGImageDestinationFinalize failed")
        return url
    }

    /// A white block on a dark background that moves right each frame.
    static func movingBlockGIF(frames: Int = 10, delay: Double = 0.1, width: Int = 320, height: Int = 180, step: Int = 20) throws -> URL {
        try makeGIF(width: width, height: height, delays: Array(repeating: delay, count: frames)) { context, index in
            context.setShouldAntialias(false)
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.15, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 10 + index * step, y: 60, width: 60, height: 60))
        }
    }

    static func flatColorGIF(colors: [(CGFloat, CGFloat, CGFloat)], delays: [Double]? = nil, width: Int = 160, height: Int = 90) throws -> URL {
        try makeGIF(width: width, height: height, delays: delays ?? Array(repeating: 0.1, count: colors.count)) { context, index in
            let (r, g, b) = colors[index]
            context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    static func makeVideo(
        _ name: String = "test.mp4",
        fileType: AVFileType = .mp4,
        codec: AVVideoCodecType = .hevc,
        width: Int = 320,
        height: Int = 180,
        fps: Int = 30,
        frames: Int = 30,
        withAudio: Bool = false,
        transform: CGAffineTransform = .identity
    ) async throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)

        var audioInput: AVAssetWriterInput?
        if withAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ])
            audio.expectsMediaDataInRealTime = false
            writer.add(audio)
            audioInput = audio
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let buffer = try makeBuffer(width: width, height: height) { context in
                context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.15, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                context.fill(CGRect(x: index * 2, y: 40, width: 40, height: 40))
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()

        if let audioInput {
            let sampleRate = 44_100
            let total = sampleRate * frames / fps
            var format = AudioStreamBasicDescription(
                mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
            )
            var description: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &description
            )
            let bytes = total * 2
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block
            )
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block!, formatDescription: description!, sampleCount: total,
                presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample
            )
            while !audioInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            audioInput.append(sample!)
            audioInput.markAsFinished()
        }

        await writer.finishWriting()
        if let error = writer.error { throw error }
        return url
    }

    static func makeBuffer(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer!), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
        draw(context)
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        return buffer!
    }

    // MARK: Reading results back

    static func videoTrack(_ url: URL) async throws -> AVAssetTrack {
        try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0]
    }

    static func sampleCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { count += 1 }
        }
        return count
    }

    static func firstSampleBytes(_ url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var firstBlock: CMBlockBuffer?
        while firstBlock == nil, let sample = output.copyNextSampleBuffer() {
            firstBlock = CMSampleBufferGetDataBuffer(sample)
        }
        guard let block = firstBlock else {
            throw reader.error ?? ImportError.failed
        }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        data.withUnsafeMutableBytes { bytes in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        return data
    }

    static func codec(_ url: URL) async throws -> FourCharCode {
        let track = try await videoTrack(url)
        let formats = try await track.load(.formatDescriptions)
        return CMFormatDescriptionGetMediaSubType(formats[0])
    }

    static func frame(_ url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600_000)).image
    }

    /// Averages an image's center area, in sRGB, as values from 0 to 255.
    static func averageColor(_ image: CGImage) -> (r: Double, g: Double, b: Double) {
        let pixels = rgbaPixels(image)
        let (w, h) = (image.width, image.height)
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for y in (h / 4)..<(h * 3 / 4) {
            for x in (w / 4)..<(w * 3 / 4) {
                let p = (y * w + x) * 4
                r += Double(pixels[p]); g += Double(pixels[p + 1]); b += Double(pixels[p + 2]); n += 1
            }
        }
        return (r / n, g / n, b / n)
    }

    /// The horizontal center of the bright pixels, as a fraction of the width.
    static func brightCentroid(_ image: CGImage) -> Double? {
        let pixels = rgbaPixels(image)
        let (w, h) = (image.width, image.height)
        var sum = 0.0, n = 0.0
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4] > 180 {
                sum += Double(x); n += 1
            }
        }
        return n > 0 ? sum / n / Double(w) : nil
    }

    static func rgbaPixels(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }
}

/// Thread-safe holder for values reported from `@Sendable` progress callbacks.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    func add(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        stored.append(value)
    }
    var values: [Value] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
