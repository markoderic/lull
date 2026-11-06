@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import LullCore

private func noProgress(_: Double) {}

@Suite("GIF import")
struct GIFImportTests {
    @Test func gifImportProducesPlayableFile() async throws {
        let store = try TestMedia.makeStore()
        let info = try await Importer(store: store).importFile(try TestMedia.movingBlockGIF(), progress: noProgress)

        let prepared = store.url(WallpaperFile.prepared, in: info.id)
        #expect(FileManager.default.fileExists(atPath: prepared.path))
        #expect(try await TestMedia.codec(prepared) == kCMVideoCodecType_HEVC)
        #expect(try await TestMedia.sampleCount(prepared) == 10)
        let duration = try await AVURLAsset(url: prepared).load(.duration).seconds
        #expect(abs(duration - 1.0) < 0.01)
        #expect(info.kind == .gif)
        #expect(info.frameCount == 10)
        #expect(abs(info.sourceFPS - 10) < 0.01)
        #expect(info.mode == .animated)
    }

    @Test func importIsSavedSoItAppearsInTheLibrary() async throws {
        let store = try TestMedia.makeStore()
        let info = try await Importer(store: store).importFile(try TestMedia.movingBlockGIF(), progress: noProgress)
        #expect(store.loadAll() == [info])
    }

    @Test func importKeepsTheOriginalAndNamesItAfterTheFile() async throws {
        let store = try TestMedia.makeStore()
        let info = try await Importer(store: store).importFile(try TestMedia.movingBlockGIF(), progress: noProgress)
        #expect(info.name == "test")
        #expect(info.originalFilename == "original.gif")
        #expect(store.fileExists("original.gif", in: info.id))
    }

    @Test func importWritesStillAndThumbnail() async throws {
        let store = try TestMedia.makeStore()
        let info = try await Importer(store: store).importFile(try TestMedia.movingBlockGIF(), progress: noProgress)
        #expect(store.fileExists(WallpaperFile.still, in: info.id))
        #expect(store.fileExists(WallpaperFile.thumbnail, in: info.id))
    }

    @Test func smallPixelArtIsEnlargedFourTimes() async throws {
        let store = try TestMedia.makeStore()
        let info = try await Importer(store: store).importFile(try TestMedia.movingBlockGIF(width: 320, height: 180), progress: noProgress)
        #expect(info.width == 1280)
        #expect(info.height == 720)
    }

    @Test func enlargedPixelArtKeepsHardEdges() async throws {
        let store = try TestMedia.makeStore()
        let info = try await Importer(store: store).importFile(try TestMedia.movingBlockGIF(width: 320, height: 180), progress: noProgress)
        let image = try await TestMedia.frame(store.url(WallpaperFile.prepared, in: info.id), at: 0.05)
        let pixels = TestMedia.rgbaPixels(image)
        // Sample across the block's left edge, 4 enlarged pixels from it on each side. The block
        // starts at x = 10 in the source and the row is safely inside it vertically.
        let row = image.height / 2
        let inside = Int(pixels[(row * image.width + 44) * 4])
        let outside = Int(pixels[(row * image.width + 36) * 4])
        #expect(inside > 200)
        #expect(outside < 60)
    }

    @Test func oddSizedGIFImports() async throws {
        let store = try TestMedia.makeStore()
        let gif = try TestMedia.makeGIF(width: 333, height: 187, delays: [0.1, 0.1, 0.1]) { context, index in
            context.setFillColor(CGColor(srgbRed: CGFloat(index) / 3, green: 0.2, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 333, height: 187))
        }
        let info = try await Importer(store: store).importFile(gif, progress: noProgress)
        #expect(info.width % 2 == 0)
        #expect(info.height % 2 == 0)
        #expect(try await TestMedia.sampleCount(store.url(WallpaperFile.prepared, in: info.id)) == 3)
    }

    @Test func tinyGIFImports() async throws {
        let store = try TestMedia.makeStore()
        let gif = try TestMedia.flatColorGIF(colors: [(1, 0, 0), (0, 1, 0)], width: 4, height: 4)
        let info = try await Importer(store: store).importFile(gif, progress: noProgress)
        #expect(info.width >= 64)
    }

    @Test func variableDelaysKeepTotalDuration() async throws {
        let store = try TestMedia.makeStore()
        let gif = try TestMedia.flatColorGIF(colors: [(1, 0, 0), (0, 1, 0), (0, 0, 1)], delays: [0.5, 0.1, 0.4])
        let info = try await Importer(store: store).importFile(gif, progress: noProgress)
        let prepared = store.url(WallpaperFile.prepared, in: info.id)
        #expect(abs(try await AVURLAsset(url: prepared).load(.duration).seconds - 1.0) < 0.01)
        #expect(info.frameTimes != nil)
        #expect(abs(info.frameTimes![1] - 0.5) < 0.001)
        #expect(abs(info.frameTimes![2] - 0.6) < 0.001)
    }

    @Test func uniformDelaysStoreNoFrameTable() async throws {
        let store = try TestMedia.makeStore()
        let info = try await Importer(store: store).importFile(try TestMedia.movingBlockGIF(), progress: noProgress)
        #expect(info.frameTimes == nil)
    }

    @Test func variableFramesShowForTheirFullDelay() async throws {
        let store = try TestMedia.makeStore()
        let gif = try TestMedia.flatColorGIF(colors: [(1, 0, 0), (0, 1, 0), (0, 0, 1)], delays: [0.5, 0.1, 0.4])
        let info = try await Importer(store: store).importFile(gif, progress: noProgress)
        let prepared = store.url(WallpaperFile.prepared, in: info.id)

        let during = TestMedia.averageColor(try await TestMedia.frame(prepared, at: 0.45))
        #expect(during.r > 200 && during.g < 60)
        let next = TestMedia.averageColor(try await TestMedia.frame(prepared, at: 0.55))
        #expect(next.g > 150 && next.r < 80)
    }

    @Test func singleFrameGIFImportsAsStill() async throws {
        let store = try TestMedia.makeStore()
        let gif = try TestMedia.flatColorGIF(colors: [(0.2, 0.6, 0.9)])
        let info = try await Importer(store: store).importFile(gif, progress: noProgress)
        #expect(info.isStillOnly)
        #expect(info.mode == .still)
        #expect(store.fileExists(WallpaperFile.still, in: info.id))
    }

    @Test func progressReachesCompletion() async throws {
        let recorder = Recorder<Double>()
        _ = try await Importer(store: try TestMedia.makeStore()).importFile(try TestMedia.movingBlockGIF()) { recorder.add($0) }
        #expect(recorder.values.last == 1)
        #expect(recorder.values.count > 2)
    }

    @Test func colorsSurviveRoundTrip() async throws {
        let store = try TestMedia.makeStore()
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (1, 0, 0), (0, 1, 0), (0, 0, 1), (0.5, 0.5, 0.5), (0.9, 0.7, 0.2), (0.1, 0.3, 0.6),
        ]
        let gif = try TestMedia.flatColorGIF(colors: colors)
        let info = try await Importer(store: store).importFile(gif, progress: noProgress)
        for (index, color) in colors.enumerated() {
            let image = try await Importer(store: store).image(for: info, frame: index)
            let average = TestMedia.averageColor(image)
            let tolerance = 12.0
            #expect(abs(average.r - Double(color.0) * 255) < tolerance, "frame \(index) red \(average.r)")
            #expect(abs(average.g - Double(color.1) * 255) < tolerance, "frame \(index) green \(average.g)")
            #expect(abs(average.b - Double(color.2) * 255) < tolerance, "frame \(index) blue \(average.b)")
        }
    }

    @Test func imageForFrameReturnsThatFrameWithVariableDelays() async throws {
        let store = try TestMedia.makeStore()
        let gif = try TestMedia.flatColorGIF(colors: [(1, 0, 0), (0, 1, 0), (0, 0, 1)], delays: [0.5, 0.1, 0.4])
        let info = try await Importer(store: store).importFile(gif, progress: noProgress)
        let average = TestMedia.averageColor(try await Importer(store: store).image(for: info, frame: 1))
        #expect(average.g > 150 && average.r < 80)
    }

    @Test func savingAStillReplacesTheStillFile() async throws {
        let store = try TestMedia.makeStore()
        let gif = try TestMedia.flatColorGIF(colors: [(1, 0, 0), (0, 0, 1)])
        let importer = Importer(store: store)
        let info = try await importer.importFile(gif, progress: noProgress)
        let image = try await importer.image(for: info, frame: 1)
        try importer.saveStill(image, for: info)

        let saved = try #require(ImageFiles.read(store.url(WallpaperFile.still, in: info.id)))
        let average = TestMedia.averageColor(saved)
        #expect(average.b > 150 && average.r < 80)
    }
}

@Suite("Bad input")
struct BadInputTests {
    @Test func unreadableFileThrowsCantOpen() async throws {
        let url = try TestMedia.temporaryDirectory().appendingPathComponent("nope.gif")
        try Data("this is not a gif".utf8).write(to: url)
        let store = try TestMedia.makeStore()
        await #expect(throws: ImportError.cantOpen) {
            _ = try await Importer(store: store).importFile(url, progress: noProgress)
        }
        #expect(store.loadAll().isEmpty)
    }

    @Test func missingFileThrowsCantOpen() async throws {
        let store = try TestMedia.makeStore()
        await #expect(throws: ImportError.cantOpen) {
            _ = try await Importer(store: store).importFile(URL(fileURLWithPath: "/no/such/file.gif"), progress: noProgress)
        }
    }

    @Test func stillImagesThatAreNotGIFsAreRejected() async throws {
        let url = try TestMedia.temporaryDirectory().appendingPathComponent("picture.png")
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        try ImageFiles.writePNG(context.makeImage()!, to: url)
        let store = try TestMedia.makeStore()
        await #expect(throws: ImportError.cantOpen) {
            _ = try await Importer(store: store).importFile(url, progress: noProgress)
        }
    }

    @Test func failedImportLeavesNoFolderBehind() async throws {
        let url = try TestMedia.temporaryDirectory().appendingPathComponent("nope.gif")
        try Data("this is not a gif".utf8).write(to: url)
        let store = try TestMedia.makeStore()
        let id = UUID()
        _ = try? await Importer(store: store).importFile(url, id: id, progress: noProgress)
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: id).path))
    }

    @Test func cancellingRemovesPartialFiles() async throws {
        let gif = try TestMedia.movingBlockGIF(frames: 30)
        let store = try TestMedia.makeStore()
        let id = UUID()
        let task = Task { try await Importer(store: store).importFile(gif, id: id, progress: noProgress) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: id).path))
    }

    @Test func userFacingMessagesAreFriendly() {
        #expect(ImportError.cantOpen.message == "Can't open this file. GIF, MP4 and MOV work.")
        #expect(ImportError.notEnoughDisk.message == "There isn't enough disk space for this.")
        #expect(ImportError.smoothMotionFailed.message == "Smooth Motion couldn't finish, so it's been turned off.")
    }

    @Test func diskFullErrorsBecomeFriendly() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let av = NSError(domain: AVFoundationErrorDomain, code: AVError.diskFull.rawValue)
        for error in [cocoa, posix, av] as [Error] {
            #expect(ImportError.classify(error) == .notEnoughDisk)
        }
        #expect(ImportError.classify(NSError(domain: "other", code: 1)) == .failed)
        #expect(ImportError.classify(ImportError.cantOpen) == .cantOpen)
    }
}

@Suite("Video import")
struct VideoImportTests {
    @Test func hevcVideoIsNotReencoded() async throws {
        let source = try await TestMedia.makeVideo(codec: .hevc)
        let store = try TestMedia.makeStore()
        let info = try await Importer(store: store).importFile(source, progress: noProgress)
        let prepared = store.url(WallpaperFile.prepared, in: info.id)
        #expect(try await TestMedia.firstSampleBytes(prepared) == TestMedia.firstSampleBytes(source))
        #expect(info.originalFilename == nil)
        #expect(info.kind == .video)
    }

    @Test func h264VideoIsNotReencoded() async throws {
        let source = try await TestMedia.makeVideo(codec: .h264)
        let store = try TestMedia.makeStore()
        let info = try await Importer(store: store).importFile(source, progress: noProgress)
        let prepared = store.url(WallpaperFile.prepared, in: info.id)
        #expect(try await TestMedia.codec(prepared) == kCMVideoCodecType_H264)
        #expect(try await TestMedia.firstSampleBytes(prepared) == TestMedia.firstSampleBytes(source))
    }

    @Test func audioIsStripped() async throws {
        let source = try await TestMedia.makeVideo(withAudio: true)
        #expect(try await !AVURLAsset(url: source).loadTracks(withMediaType: .audio).isEmpty)
        let store = try TestMedia.makeStore()
        let info = try await Importer(store: store).importFile(source, progress: noProgress)
        let prepared = store.url(WallpaperFile.prepared, in: info.id)
        #expect(try await AVURLAsset(url: prepared).loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await TestMedia.sampleCount(prepared) == 30)
    }

    @Test func videoReportsItsFrameRateAndSize() async throws {
        let source = try await TestMedia.makeVideo(width: 640, height: 360, fps: 60, frames: 60)
        let info = try await Importer(store: try TestMedia.makeStore()).importFile(source, progress: noProgress)
        #expect(abs(info.sourceFPS - 60) < 0.5)
        #expect(info.width == 640)
        #expect(info.height == 360)
        #expect(info.frameCount == 60)
    }

    @Test func otherCodecsAreConvertedAndTheOriginalKept() async throws {
        let source = try await TestMedia.makeVideo("clip.mov", fileType: .mov, codec: .jpeg)
        let store = try TestMedia.makeStore()
        let info = try await Importer(store: store).importFile(source, progress: noProgress)
        #expect(try await TestMedia.codec(store.url(WallpaperFile.prepared, in: info.id)) == kCMVideoCodecType_HEVC)
        #expect(info.originalFilename == "original.mov")
        #expect(store.fileExists("original.mov", in: info.id))
        #expect(try await TestMedia.sampleCount(store.url(WallpaperFile.prepared, in: info.id)) == 30)
    }

    @Test func oddSizedVideoIsConvertedToEvenSize() async throws {
        let source = try await TestMedia.makeVideo("odd.mov", fileType: .mov, codec: .jpeg, width: 321, height: 181)
        let store = try TestMedia.makeStore()
        let info = try await Importer(store: store).importFile(source, progress: noProgress)
        #expect(info.width % 2 == 0)
        #expect(info.height % 2 == 0)
        #expect(try await TestMedia.sampleCount(store.url(WallpaperFile.prepared, in: info.id)) == 30)
    }
}

@Suite("Frame limit")
struct FrameLimitTests {
    @Test func frameLimitDropsFrames() async throws {
        let source = try await TestMedia.makeVideo(fps: 120, frames: 120)
        let store = try TestMedia.makeStore()
        let importer = Importer(store: store)
        let info = try await importer.importFile(source, progress: noProgress)
        try await importer.makeLimitedVersion(of: info, limit: 60, progress: noProgress)

        let limited = store.url(WallpaperFile.limit(60), in: info.id)
        #expect(try await TestMedia.sampleCount(limited) == 60)
        #expect(abs(try await AVURLAsset(url: limited).load(.duration).seconds - 1.0) < 0.02)
    }

    @Test func limitedVersionIsFinishedNotPartial() async throws {
        let source = try await TestMedia.makeVideo(fps: 60, frames: 30)
        let store = try TestMedia.makeStore()
        let importer = Importer(store: store)
        let info = try await importer.importFile(source, progress: noProgress)
        try await importer.makeLimitedVersion(of: info, limit: 30, progress: noProgress)
        #expect(store.fileExists(WallpaperFile.limit(30), in: info.id))
        #expect(!store.fileExists(WallpaperFile.limit(30) + WallpaperFile.partialSuffix, in: info.id))
    }
}

@Suite("Smooth Motion", .enabled(if: SmoothMotion.isAvailable))
struct SmoothMotionTests {
    @Test func smoothVersionHasExpectedFrameCountAndRealContent() async throws {
        let store = try TestMedia.makeStore()
        let importer = Importer(store: store)
        let info = try await importer.importFile(try TestMedia.movingBlockGIF(frames: 10, delay: 0.1), progress: noProgress)
        try await importer.makeSmoothVersion(of: info, rate: 60, progress: noProgress)

        let smooth = store.url(WallpaperFile.smooth(60), in: info.id)
        #expect(try await TestMedia.sampleCount(smooth) == 60)
        #expect(abs(try await AVURLAsset(url: smooth).load(.duration).seconds - 1.0) < 0.02)

        // Generated frames came out black when the API was misused, so check every kind of frame.
        for time in [0.0, 0.05, 0.31, 0.72] {
            let image = try await TestMedia.frame(smooth, at: time)
            #expect(TestMedia.brightCentroid(image) != nil, "no bright pixels at \(time)")
        }
    }

    @Test func smoothFramesActuallyMoveBetweenSourceFrames() async throws {
        let store = try TestMedia.makeStore()
        let importer = Importer(store: store)
        let info = try await importer.importFile(try TestMedia.movingBlockGIF(frames: 10, delay: 0.1, step: 20), progress: noProgress)
        try await importer.makeSmoothVersion(of: info, rate: 60, progress: noProgress)
        let smooth = store.url(WallpaperFile.smooth(60), in: info.id)

        let start = try #require(TestMedia.brightCentroid(try await TestMedia.frame(smooth, at: 0.2)))
        let middle = try #require(TestMedia.brightCentroid(try await TestMedia.frame(smooth, at: 0.25)))
        let end = try #require(TestMedia.brightCentroid(try await TestMedia.frame(smooth, at: 0.3)))
        #expect(start < middle)
        #expect(middle < end)
        // A duplicated frame would sit at one end. A real in-between frame sits near the middle.
        let fraction = (middle - start) / (end - start)
        #expect(fraction > 0.25 && fraction < 0.75, "fraction was \(fraction)")
    }

    @Test func oneTwentyFromVariableDelaysProducesEveryFrame() async throws {
        let store = try TestMedia.makeStore()
        let importer = Importer(store: store)
        let gif = try TestMedia.flatColorGIF(colors: [(1, 0, 0), (0, 1, 0), (0, 0, 1)], delays: [0.5, 0.1, 0.4])
        let info = try await importer.importFile(gif, progress: noProgress)
        try await importer.makeSmoothVersion(of: info, rate: 120, progress: noProgress)
        #expect(try await TestMedia.sampleCount(store.url(WallpaperFile.smooth(120), in: info.id)) == 120)
    }

    @Test func smoothVersionOfAVideoWorks() async throws {
        let source = try await TestMedia.makeVideo(fps: 30, frames: 30)
        let store = try TestMedia.makeStore()
        let importer = Importer(store: store)
        let info = try await importer.importFile(source, progress: noProgress)
        try await importer.makeSmoothVersion(of: info, rate: 60, progress: noProgress)
        #expect(try await TestMedia.sampleCount(store.url(WallpaperFile.smooth(60), in: info.id)) == 60)
    }

    @Test func progressReachesCompletion() async throws {
        let store = try TestMedia.makeStore()
        let importer = Importer(store: store)
        let info = try await importer.importFile(try TestMedia.movingBlockGIF(), progress: noProgress)
        let recorder = Recorder<Double>()
        try await importer.makeSmoothVersion(of: info, rate: 60) { recorder.add($0) }
        #expect(recorder.values.last == 1)
    }

    @Test func cancellingLeavesNoFinishedFile() async throws {
        let store = try TestMedia.makeStore()
        let importer = Importer(store: store)
        let info = try await importer.importFile(try TestMedia.movingBlockGIF(), progress: noProgress)
        let task = Task { try await importer.makeSmoothVersion(of: info, rate: 60, progress: noProgress) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!store.fileExists(WallpaperFile.smooth(60), in: info.id))
        #expect(!store.fileExists(WallpaperFile.smooth(60) + WallpaperFile.partialSuffix, in: info.id))
    }
}

@Suite("Rebuilding")
struct RebuildTests {
    @Test func rebuildRecreatesADeletedPreparedFile() async throws {
        let store = try TestMedia.makeStore()
        let importer = Importer(store: store)
        var info = try await importer.importFile(try TestMedia.movingBlockGIF(), progress: noProgress)
        info.mode = .still
        info.stillFrame = 3
        try store.save(info)
        try FileManager.default.removeItem(at: store.url(WallpaperFile.prepared, in: info.id))

        let rebuilt = try await importer.rebuildPrepared(info, progress: noProgress)

        #expect(!store.isPreparedMissing(rebuilt))
        #expect(rebuilt.mode == .still)
        #expect(rebuilt.stillFrame == 3)
        #expect(try await TestMedia.sampleCount(store.url(WallpaperFile.prepared, in: info.id)) == 10)
    }

    @Test func rebuildWithoutAnOriginalThrows() async throws {
        let store = try TestMedia.makeStore()
        let importer = Importer(store: store)
        let info = try await importer.importFile(try await TestMedia.makeVideo(), progress: noProgress)
        try FileManager.default.removeItem(at: store.url(WallpaperFile.prepared, in: info.id))
        await #expect(throws: ImportError.cantOpen) {
            _ = try await importer.rebuildPrepared(info, progress: noProgress)
        }
    }
}
