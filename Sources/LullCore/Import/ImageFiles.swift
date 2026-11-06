import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFiles {
    public static func read(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        try write(image, to: url, type: .png, options: nil)
    }

    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.85) throws {
        try write(image, to: url, type: .jpeg, options: [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    }

    /// Writes beside the destination and swaps it in, so a crash never leaves a half-written image.
    private static func write(_ image: CGImage, to url: URL, type: UTType, options: CFDictionary?) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImportError.failed
        }
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.failed }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    /// Scales to a width, keeping the aspect ratio.
    public static func thumbnail(of image: CGImage, width: Int) -> CGImage? {
        let height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
