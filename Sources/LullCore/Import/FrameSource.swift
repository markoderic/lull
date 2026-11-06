import CoreGraphics
import CoreVideo

struct SourceFrame {
    let buffer: CVPixelBuffer
    let time: Double
}

/// Hands out decoded frames one at a time, so memory stays flat no matter how long the file is.
protocol FrameSource: AnyObject {
    var width: Int { get }
    var height: Int { get }
    var duration: Double { get }
    var fps: Double { get }
    var transform: CGAffineTransform { get }
    func nextFrame() throws -> SourceFrame?
}

enum PixelBuffers {
    static func makePool(width: Int, height: Int, format: OSType, base: [String: Any] = [:]) throws -> CVPixelBufferPool {
        var attributes = base
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = format
        attributes[kCVPixelBufferWidthKey as String] = width
        attributes[kCVPixelBufferHeightKey as String] = height
        if attributes[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        }
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { throw ImportError.failed }
        return pool
    }

    static func make(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw ImportError.failed }
        return buffer
    }
}
