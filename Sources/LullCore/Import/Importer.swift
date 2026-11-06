@preconcurrency import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a GIF or video into a prepared wallpaper, and makes its Smooth Motion and frame limit versions.
public final class Importer: Sendable {
    public typealias Progress = @Sendable (Double) -> Void

    private let store: WallpaperStore
    private static let thumbnailWidth = 240

    public init(store: WallpaperStore) {
        self.store = store
    }

    // MARK: Importing

    public func importFile(_ url: URL, id: UUID = UUID(), progress: @escaping Progress) async throws -> WallpaperInfo {
        do {
            try Task.checkCancellation()
            let kind = try await detectKind(url)
            try store.createFolder(for: id)
            try requireDiskSpace(for: url)
            let name = url.deletingPathExtension().lastPathComponent
            let info = switch kind {
            case .gif: try await importGIF(url, id: id, name: name, progress: progress)
            case .video: try await importVideo(url, id: id, name: name, progress: progress)
            }
            try await writeStillAndThumbnail(for: info)
            // Written last: a folder without info.json is an unfinished import.
            try store.save(info)
            progress(1)
            return info
        } catch {
            store.discard(id: id)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ImportError.classify(error)
        }
    }

    private func detectKind(_ url: URL) async throws -> WallpaperInfo.Kind {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ImportError.cantOpen }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) as String? {
            guard type == UTType.gif.identifier else { throw ImportError.cantOpen }
            return .gif
        }
        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let duration = try await asset.load(.duration)
            guard !tracks.isEmpty, duration.seconds > 0 else { throw ImportError.cantOpen }
            return .video
        } catch {
            throw ImportError.cantOpen
        }
    }

    /// Whole seconds, so the date survives being written to and read back from `info.json` exactly.
    private static func addedDate() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    private func requireDiskSpace(for url: URL) throws {
        let values = try? store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if available < Int64(size) * 2 + 50_000_000 { throw ImportError.notEnoughDisk }
    }

    private func importGIF(_ url: URL, id: UUID, name: String, progress: @escaping Progress) async throws -> WallpaperInfo {
        let details = try GIFDetails(url: url)
        let originalName = "original.gif"
        try FileManager.default.copyItem(at: url, to: store.url(originalName, in: id))
        let plan = try await prepareGIF(store.url(originalName, in: id), details: details, id: id, progress: progress)
        let frameCount = details.delays.count
        return WallpaperInfo(
            id: id,
            name: name,
            kind: .gif,
            addedAt: Self.addedDate(),
            originalFilename: originalName,
            width: plan.outputWidth,
            height: plan.outputHeight,
            duration: details.duration,
            sourceFPS: Double(frameCount) / details.duration,
            frameCount: frameCount,
            frameTimes: FrameTiming.isUniform(delays: details.delays) ? nil : FrameTiming.startTimes(delays: details.delays),
            mode: frameCount <= 1 ? .still : .animated
        )
    }

    private func prepareGIF(_ url: URL, details: GIFDetails, id: UUID, progress: @escaping Progress) async throws -> EnlargePlan {
        let plan = enlargePlan(for: details)
        let source = try GIFFrameSource(
            url: url, details: details, outputWidth: plan.outputWidth, outputHeight: plan.outputHeight, sharpPixels: plan.sharpPixels
        )
        try await writeVersion(WallpaperFile.prepared, in: id, from: source, fps: source.fps) { writer in
            let count = Double(details.delays.count)
            var written = 0.0
            while let frame = try source.nextFrame() {
                try Task.checkCancellation()
                try await writer.append(frame.buffer, time: frame.time)
                written += 1
                // Leaves room at the end for the still, thumbnail and save.
                progress(written / count * 0.95)
            }
        }
        return plan
    }

    private func enlargePlan(for details: GIFDetails) -> EnlargePlan {
        EnlargePolicy.plan(
            width: details.width,
            height: details.height,
            isPixelArt: PixelArtDetector.isPixelArt(details.sampleFrame)
        )
    }

    private func importVideo(_ url: URL, id: UUID, name: String, progress: @escaping Progress) async throws -> WallpaperInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ImportError.cantOpen }
        let (size, transform, nominal, formats, range) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions, .timeRange
        )
        guard range.duration.seconds > 0, let format = formats.first else { throw ImportError.cantOpen }

        let codec = CMFormatDescriptionGetMediaSubType(format)
        let canPassThrough = codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC
        var originalName: String?
        if canPassThrough {
            // Already plays well on the hardware: drop the audio without touching the video.
            try await exportWithoutAudio(track: track, range: range, transform: transform, id: id)
        } else {
            let pathExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
            let original = "original.\(pathExtension)"
            try FileManager.default.copyItem(at: url, to: store.url(original, in: id))
            originalName = original
            try await transcodeVideo(store.url(original, in: id), id: id, progress: progress)
        }

        let fps = nominal > 0 ? Double(nominal) : 30
        let frameCount = max(1, Int((range.duration.seconds * fps).rounded()))
        let displayed = size.applying(transform)
        var width = Int(abs(displayed.width).rounded()), height = Int(abs(displayed.height).rounded())
        if !canPassThrough {
            width += width % 2
            height += height % 2
        }
        return WallpaperInfo(
            id: id,
            name: name,
            kind: .video,
            addedAt: Self.addedDate(),
            originalFilename: originalName,
            width: width,
            height: height,
            duration: range.duration.seconds,
            sourceFPS: fps,
            frameCount: frameCount,
            mode: frameCount <= 1 ? .still : .animated
        )
    }

    private func exportWithoutAudio(track: AVAssetTrack, range: CMTimeRange, transform: CGAffineTransform, id: UUID) async throws {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ImportError.failed
        }
        try videoTrack.insertTimeRange(range, of: track, at: .zero)
        videoTrack.preferredTransform = transform
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ImportError.failed
        }
        let final = store.url(WallpaperFile.prepared, in: id)
        let partial = partialURL(for: WallpaperFile.prepared, in: id)
        try? FileManager.default.removeItem(at: partial)
        try await session.export(to: partial, as: .mp4)
        try replace(final, with: partial)
    }

    private func transcodeVideo(_ url: URL, id: UUID, progress: @escaping Progress) async throws {
        let source = try await VideoFrameSource.open(url)
        defer { source.cancel() }
        try await writeVersion(WallpaperFile.prepared, in: id, from: source, fps: source.fps) { writer in
            while let frame = try source.nextFrame() {
                try Task.checkCancellation()
                try await writer.append(frame.buffer, time: frame.time)
                progress(min(frame.time / source.duration, 1) * 0.95)
            }
        }
    }

    // MARK: Versions

    /// Makes the Smooth Motion version for a rate. The result is saved beside the others and kept.
    public func makeSmoothVersion(of info: WallpaperInfo, rate: Int, progress: @escaping Progress) async throws {
        do {
            try Task.checkCancellation()
            let source = try await frameSource(for: info)
            try await writeVersion(WallpaperFile.smooth(rate), in: info.id, from: source, fps: Double(rate)) { writer in
                try await SmoothMotion.generate(from: source, to: writer, fps: rate, progress: progress)
            }
            progress(1)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let classified = ImportError.classify(error)
            throw classified == .failed ? ImportError.smoothMotionFailed : classified
        }
    }

    /// Makes a lower frame rate version by dropping frames.
    public func makeLimitedVersion(of info: WallpaperInfo, limit: Int, progress: @escaping Progress) async throws {
        do {
            try Task.checkCancellation()
            let source = try await VideoFrameSource.open(store.url(WallpaperFile.prepared, in: info.id))
            defer { source.cancel() }
            try await writeVersion(WallpaperFile.limit(limit), in: info.id, from: source, fps: Double(limit)) { writer in
                var limiter = FrameLimiter(limit: limit)
                while let frame = try source.nextFrame() {
                    try Task.checkCancellation()
                    if limiter.shouldKeep(time: frame.time) {
                        try await writer.append(frame.buffer, time: frame.time)
                    }
                    progress(min(frame.time / source.duration, 1) * 0.95)
                }
            }
            progress(1)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ImportError.classify(error)
        }
    }

    /// Rebuilds a missing or damaged `prepared.mp4` from the original. Settings are preserved.
    public func rebuildPrepared(_ info: WallpaperInfo, progress: @escaping Progress) async throws -> WallpaperInfo {
        guard let originalName = info.originalFilename, store.fileExists(originalName, in: info.id) else {
            throw ImportError.cantOpen
        }
        let original = store.url(originalName, in: info.id)
        do {
            switch info.kind {
            case .gif:
                let details = try GIFDetails(url: original)
                _ = try await prepareGIF(original, details: details, id: info.id, progress: progress)
            case .video:
                try await transcodeVideo(original, id: info.id, progress: progress)
            }
            if !store.fileExists(WallpaperFile.still, in: info.id) || !store.fileExists(WallpaperFile.thumbnail, in: info.id) {
                try await writeStillAndThumbnail(for: info)
            }
            progress(1)
            return info
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ImportError.classify(error)
        }
    }

    /// The best available source for making a version. A GIF's own frames beat its encoded copy.
    private func frameSource(for info: WallpaperInfo) async throws -> FrameSource {
        if info.kind == .gif, let name = info.originalFilename, store.fileExists(name, in: info.id) {
            let url = store.url(name, in: info.id)
            let details = try GIFDetails(url: url)
            return try GIFFrameSource(
                url: url,
                details: details,
                outputWidth: info.width,
                outputHeight: info.height,
                sharpPixels: enlargePlan(for: details).sharpPixels
            )
        }
        return try await VideoFrameSource.open(store.url(WallpaperFile.prepared, in: info.id))
    }

    /// Runs `body` against a writer on a partial file, and only moves it into place when complete.
    private func writeVersion(
        _ filename: String,
        in id: UUID,
        from source: FrameSource,
        fps: Double,
        body: (HEVCWriter) async throws -> Void
    ) async throws {
        let partial = partialURL(for: filename, in: id)
        let writer = try HEVCWriter(url: partial, width: source.width, height: source.height, fps: fps, transform: source.transform)
        do {
            try await body(writer)
            try await writer.finish(duration: source.duration)
            try replace(store.url(filename, in: id), with: partial)
        } catch {
            writer.cancel()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    private func partialURL(for filename: String, in id: UUID) -> URL {
        store.url(filename + WallpaperFile.partialSuffix, in: id)
    }

    private func replace(_ destination: URL, with file: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: file, to: destination)
    }

    // MARK: Still frames

    /// Decodes one frame of the base prepared file, so a generated in-between frame can never be chosen.
    public func image(for info: WallpaperInfo, frame: Int) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: store.url(WallpaperFile.prepared, in: info.id)))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Nudged past the frame's start so rounding can't land on the frame before.
        let time = CMTime(seconds: info.time(forFrame: frame) + 0.0005, preferredTimescale: 600_000)
        return try await generator.image(at: time).image
    }

    /// Saves the chosen frame as the still shown on launch, and refreshes the thumbnail.
    public func saveStill(_ image: CGImage, for info: WallpaperInfo) throws {
        try ImageFiles.writePNG(image, to: store.url(WallpaperFile.still, in: info.id))
        if let thumbnail = ImageFiles.thumbnail(of: image, width: Self.thumbnailWidth) {
            try ImageFiles.writeJPEG(thumbnail, to: store.url(WallpaperFile.thumbnail, in: info.id))
        }
    }

    private func writeStillAndThumbnail(for info: WallpaperInfo) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: store.url(WallpaperFile.prepared, in: info.id)))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
        try saveStill(try await generator.image(at: .zero).image, for: info)
    }
}
