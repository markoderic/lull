import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a GIF contains, read without decoding every frame.
struct GIFDetails {
    let width: Int
    let height: Int
    let delays: [Double]
    let sampleFrame: CGImage

    var duration: Double { delays.reduce(0, +) }

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.gif.identifier else { throw ImportError.cantOpen }
        let count = CGImageSourceGetCount(source)
        guard count > 0, let sample = CGImageSourceCreateImageAtIndex(source, count / 2, nil) else { throw ImportError.cantOpen }
        width = sample.width
        height = sample.height
        sampleFrame = sample
        delays = (0..<count).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif?[kCGImagePropertyGIFDelayTime] as? Double
                ?? 0
            return FrameTiming.normalizedDelay(delay)
        }
    }
}

/// Decodes a GIF frame by frame into BGRA at the planned size, composited onto black.
final class GIFFrameSource: FrameSource {
    let width: Int
    let height: Int
    let duration: Double
    let fps: Double
    let transform = CGAffineTransform.identity

    private let source: CGImageSource
    private let starts: [Double]
    private let sharpPixels: Bool
    private let pool: CVPixelBufferPool
    private var index = 0

    init(url: URL, details: GIFDetails, outputWidth: Int, outputHeight: Int, sharpPixels: Bool) throws {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { throw ImportError.cantOpen }
        self.source = source
        self.sharpPixels = sharpPixels
        width = outputWidth
        height = outputHeight
        duration = details.duration
        fps = Double(details.delays.count) / details.duration
        starts = FrameTiming.startTimes(delays: details.delays)
        pool = try PixelBuffers.makePool(width: outputWidth, height: outputHeight, format: kCVPixelFormatType_32BGRA)
    }

    func nextFrame() throws -> SourceFrame? {
        guard index < starts.count else { return nil }
        defer { index += 1 }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, index, options) else { throw ImportError.cantOpen }
        let buffer = try PixelBuffers.make(from: pool)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { throw ImportError.failed }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = sharpPixels ? .none : .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return SourceFrame(buffer: buffer, time: starts[index])
    }
}
