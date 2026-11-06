import CoreGraphics
import Foundation

public struct EnlargePlan: Equatable, Sendable {
    public var scale: Int
    public var outputWidth: Int
    public var outputHeight: Int
    public var sharpPixels: Bool

    public init(scale: Int, outputWidth: Int, outputHeight: Int, sharpPixels: Bool) {
        self.scale = scale
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.sharpPixels = sharpPixels
    }
}

/// Small GIFs are enlarged before encoding. HEVC stores color at half resolution, which visibly
/// smears small pixel art, and enlarging first keeps it crisp for very little extra file size.
public enum EnlargePolicy {
    private static let enlargeBelowWidth = 1280
    private static let longestSide = 1920
    private static let maximumScale = 4
    private static let minimumEncoderSide = 64

    public static func plan(width: Int, height: Int, isPixelArt: Bool) -> EnlargePlan {
        let longest = max(width, height), shortest = max(min(width, height), 1)
        var scale = 1
        if width < enlargeBelowWidth {
            scale = (1...maximumScale).last { longest * $0 <= longestSide } ?? 1
        }
        // Encoders reject very small frames. Scale up further if that stays in bounds, and
        // otherwise the output size below is forced up instead.
        let neededForEncoder = Int((Double(minimumEncoderSide) / Double(shortest)).rounded(.up))
        if neededForEncoder > scale, longest * neededForEncoder <= longestSide {
            scale = neededForEncoder
        }
        return EnlargePlan(
            scale: scale,
            outputWidth: even(max(width * scale, minimumEncoderSide)),
            outputHeight: even(max(height * scale, minimumEncoderSide)),
            sharpPixels: isPixelArt
        )
    }

    private static func even(_ value: Int) -> Int {
        value % 2 == 0 ? value : value + 1
    }
}

public enum PixelArtDetector {
    private static let equalNeighborShare = 0.60
    private static let maximumDistinctColors = 128

    /// Pixel art has long runs of identical neighbors and few colors. A banded gradient also has
    /// long runs, so the color count is what separates them.
    public static func isPixelArt(pixels: [UInt32], width: Int, height: Int) -> Bool {
        guard width > 1, height > 0, pixels.count >= width * height else { return false }
        var equal = 0, compared = 0
        var colors = Set<UInt32>()
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let pixel = pixels[row + x]
                if colors.count <= maximumDistinctColors { colors.insert(pixel) }
                if x + 1 < width {
                    compared += 1
                    if pixel == pixels[row + x + 1] { equal += 1 }
                }
            }
        }
        return colors.count <= maximumDistinctColors && Double(equal) / Double(compared) >= equalNeighborShare
    }

    public static func isPixelArt(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return false }
        var pixels = [UInt32](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn && isPixelArt(pixels: pixels, width: width, height: height)
    }
}
