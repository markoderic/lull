import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Turns any frame into one at the screen's exact resolution: the whole picture, centered, with a
/// blurred copy of itself filling whatever's left. No part of the picture is cropped away.
final class FittedFrameSource: FrameSource {
    let width: Int
    let height: Int
    let transform = CGAffineTransform.identity
    var duration: Double { base.duration }
    var fps: Double { base.fps }

    private let base: FrameSource
    private let orientation: CGImagePropertyOrientation
    private let pool: CVPixelBufferPool
    private let context: CIContext

    init(base: FrameSource, size: FitSize) throws {
        self.base = base
        width = size.width
        height = size.height
        orientation = Self.orientation(of: base.transform)
        pool = try PixelBuffers.makePool(width: size.width, height: size.height, format: kCVPixelFormatType_32BGRA)
        // No color management: frames keep the values the rest of the pipeline expects.
        context = CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false,
            .priorityRequestLow: true,
        ])
    }

    func nextFrame() throws -> SourceFrame? {
        guard let frame = try base.nextFrame() else { return nil }
        let output = try PixelBuffers.make(from: pool)
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: frame.buffer, options: [.colorSpace: NSNull()]).oriented(orientation)
            context.render(
                Self.compose(image, width: CGFloat(width), height: CGFloat(height)),
                to: output,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                colorSpace: nil
            )
        }
        return SourceFrame(buffer: output, time: frame.time)
    }

    static func compose(_ source: CIImage, width: CGFloat, height: CGFloat) -> CIImage {
        let image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let size = image.extent.size
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)

        func placed(scale: CGFloat) -> CIImage {
            image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(
                    translationX: (width - size.width * scale) / 2,
                    y: (height - size.height * scale) / 2
                ))
        }

        let background = placed(scale: max(width / size.width, height / size.height))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(width, height) * 0.02)
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.6])
            .cropped(to: canvas)
        let foreground = placed(scale: min(width / size.width, height / size.height))
        return foreground.composited(over: background).cropped(to: canvas)
    }

    /// Phones store vertical video sideways with a rotation flag, which must be applied here because
    /// the fitted file is written upright.
    static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a.rounded(), transform.b.rounded(), transform.c.rounded(), transform.d.rounded()) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }
}
