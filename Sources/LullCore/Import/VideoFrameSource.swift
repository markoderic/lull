@preconcurrency import AVFoundation
import CoreVideo
import VideoToolbox

/// Decodes a video frame by frame into BGRA, at an even size.
final class VideoFrameSource: FrameSource {
    let width: Int
    let height: Int
    let duration: Double
    let fps: Double
    let transform: CGAffineTransform

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let start: CMTime
    private let resizer: Resizer?

    static func open(_ url: URL) async throws -> VideoFrameSource {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ImportError.cantOpen }
        let (size, transform, nominal, range) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .timeRange)
        guard range.duration.seconds > 0 else { throw ImportError.cantOpen }
        return try VideoFrameSource(
            asset: asset, track: track, size: size, transform: transform, nominalFPS: Double(nominal), range: range
        )
    }

    private init(asset: AVURLAsset, track: AVAssetTrack, size: CGSize, transform: CGAffineTransform, nominalFPS: Double, range: CMTimeRange) throws {
        let sourceWidth = Int(size.width.rounded()), sourceHeight = Int(size.height.rounded())
        width = sourceWidth + sourceWidth % 2
        height = sourceHeight + sourceHeight % 2
        duration = range.duration.seconds
        fps = nominalFPS > 0 ? nominalFPS : 30
        self.transform = transform
        start = range.start
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw ImportError.cantOpen }
        resizer = (width, height) != (sourceWidth, sourceHeight) ? try Resizer(width: width, height: height) : nil
    }

    func nextFrame() throws -> SourceFrame? {
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = (CMSampleBufferGetPresentationTimeStamp(sample) - start).seconds
            return SourceFrame(buffer: try resizer?.resize(image) ?? image, time: max(time, 0))
        }
        if reader.status == .failed { throw reader.error ?? ImportError.cantOpen }
        return nil
    }

    func cancel() {
        reader.cancelReading()
    }
}

/// Rescales frames, for sources whose odd dimensions HEVC can't encode.
private final class Resizer {
    private let pool: CVPixelBufferPool
    private let session: VTPixelTransferSession

    init(width: Int, height: Int) throws {
        pool = try PixelBuffers.makePool(width: width, height: height, format: kCVPixelFormatType_32BGRA)
        var created: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created)
        guard let created else { throw ImportError.failed }
        session = created
    }

    func resize(_ image: CVPixelBuffer) throws -> CVPixelBuffer {
        let output = try PixelBuffers.make(from: pool)
        guard VTPixelTransferSessionTransferImage(session, from: image, to: output) == noErr else { throw ImportError.failed }
        return output
    }
}
