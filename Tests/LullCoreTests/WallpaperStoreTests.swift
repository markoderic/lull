import Foundation
import Testing
@testable import LullCore

private func makeInfo(
    id: UUID = UUID(),
    addedAt: Date = Date(timeIntervalSince1970: 1_000),
    sourceFPS: Double = 25,
    frameCount: Int = 100,
    frameTimes: [Double]? = nil
) -> WallpaperInfo {
    WallpaperInfo(
        id: id,
        name: "Test",
        kind: .gif,
        addedAt: addedAt,
        originalFilename: "original.gif",
        width: 640,
        height: 360,
        duration: 4,
        sourceFPS: sourceFPS,
        frameCount: frameCount,
        frameTimes: frameTimes
    )
}

private func makeStore() throws -> (WallpaperStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lull-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = WallpaperStore(root: root, moveToTrash: { url in
        try FileManager.default.removeItem(at: url)
    })
    return (store, root)
}

@Suite("Wallpaper store")
struct WallpaperStoreTests {
    @Test func saveAndLoadRoundTrip() throws {
        let (store, _) = try makeStore()
        var info = makeInfo()
        info.mode = .still
        info.stillFrame = 12
        info.smoothMotion = true
        info.smoothRate = 60
        try store.createFolder(for: info.id)
        try store.save(info)

        #expect(store.loadAll() == [info])
    }

    @Test func corruptInfoHidesOnlyThatWallpaper() throws {
        let (store, _) = try makeStore()
        let good = makeInfo()
        let bad = makeInfo()
        try store.createFolder(for: good.id)
        try store.save(good)
        try store.createFolder(for: bad.id)
        try Data("{ not json".utf8).write(to: store.url(WallpaperFile.info, in: bad.id))

        #expect(store.loadAll() == [good])
    }

    @Test func corruptInfoFolderIsNotDeleted() throws {
        let (store, _) = try makeStore()
        let bad = makeInfo()
        try store.createFolder(for: bad.id)
        try Data("{ not json".utf8).write(to: store.url(WallpaperFile.info, in: bad.id))

        store.removeIncompleteItems()

        #expect(FileManager.default.fileExists(atPath: store.folder(for: bad.id).path))
    }

    @Test func foldersWithoutInfoAreDiscardedAsIncomplete() throws {
        let (store, _) = try makeStore()
        let id = UUID()
        try store.createFolder(for: id)

        store.removeIncompleteItems()

        #expect(!FileManager.default.fileExists(atPath: store.folder(for: id).path))
    }

    @Test func partialVersionsAreDiscardedButFinishedFilesKept() throws {
        let (store, _) = try makeStore()
        let info = makeInfo()
        try store.createFolder(for: info.id)
        try store.save(info)
        let partial = store.url(WallpaperFile.smooth(120) + WallpaperFile.partialSuffix, in: info.id)
        try Data("x".utf8).write(to: partial)
        let finished = store.url(WallpaperFile.prepared, in: info.id)
        try Data("x".utf8).write(to: finished)

        store.removeIncompleteItems()

        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(FileManager.default.fileExists(atPath: finished.path))
    }

    @Test func sortedByDateAdded() throws {
        let (store, _) = try makeStore()
        let newer = makeInfo(addedAt: Date(timeIntervalSince1970: 2_000))
        let older = makeInfo(addedAt: Date(timeIntervalSince1970: 1_000))
        for info in [newer, older] {
            try store.createFolder(for: info.id)
            try store.save(info)
        }

        #expect(store.loadAll().map(\.id) == [older.id, newer.id])
    }

    @Test func trashRemovesFolder() throws {
        let (store, _) = try makeStore()
        let info = makeInfo()
        try store.createFolder(for: info.id)
        try store.save(info)

        try store.trash(id: info.id)

        #expect(store.loadAll().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: info.id).path))
    }

    @Test func missingFilesAreReported() throws {
        let (store, _) = try makeStore()
        let info = makeInfo()
        try store.createFolder(for: info.id)
        try store.save(info)

        #expect(store.isPreparedMissing(info))
        #expect(store.isOriginalMissing(info))

        try Data("x".utf8).write(to: store.url(WallpaperFile.prepared, in: info.id))
        try Data("x".utf8).write(to: store.url("original.gif", in: info.id))

        #expect(!store.isPreparedMissing(info))
        #expect(!store.isOriginalMissing(info))
    }

    @Test func preparedFileCountsAsOriginalWhenNoSeparateCopyExists() throws {
        let (store, _) = try makeStore()
        var info = makeInfo()
        info.originalFilename = nil
        try store.createFolder(for: info.id)
        try store.save(info)

        #expect(store.isOriginalMissing(info))
        try Data("x".utf8).write(to: store.url(WallpaperFile.prepared, in: info.id))
        #expect(!store.isOriginalMissing(info))
    }
}

@Suite("Wallpaper info")
struct WallpaperInfoTests {
    @Test func playbackFilenameDefaultsToPrepared() {
        #expect(makeInfo().playbackFilename == "prepared.mp4")
    }

    @Test func playbackFilenamePrefersSmoothThenLimit() {
        var info = makeInfo()
        info.frameLimit = 30
        #expect(info.playbackFilename == "limit-30.mp4")
        info.smoothMotion = true
        info.smoothRate = 120
        #expect(info.playbackFilename == "smooth-120.mp4")
    }

    @Test func timeForFrameUsesRateWhenUniform() {
        let info = makeInfo(sourceFPS: 25, frameCount: 100)
        #expect(info.time(forFrame: 25) == 1.0)
    }

    @Test func timeForFrameUsesTableWhenVariable() {
        let info = makeInfo(frameCount: 3, frameTimes: [0, 0.5, 0.6])
        #expect(info.time(forFrame: 2) == 0.6)
    }

    @Test func timeForFrameClampsToValidFrames() {
        let info = makeInfo(sourceFPS: 25, frameCount: 100)
        #expect(info.time(forFrame: -5) == 0)
        #expect(info.time(forFrame: 500) == 99.0 / 25.0)
    }

    @Test func frameForTimeFindsTheFrameShowing() {
        let uniform = makeInfo(sourceFPS: 25, frameCount: 100)
        #expect(uniform.frame(forTime: 1.01) == 25)
        let variable = makeInfo(frameCount: 3, frameTimes: [0, 0.5, 0.6])
        #expect(variable.frame(forTime: 0.55) == 1)
        #expect(variable.frame(forTime: 99) == 2)
        #expect(variable.frame(forTime: -1) == 0)
    }

    @Test func smoothRatesAboveSourceAndWithinDisplay() {
        #expect(makeInfo(sourceFPS: 25).availableSmoothRates(displayMaxFPS: 120) == [60, 120])
        #expect(makeInfo(sourceFPS: 25).availableSmoothRates(displayMaxFPS: 60) == [60])
        #expect(makeInfo(sourceFPS: 60).availableSmoothRates(displayMaxFPS: 120) == [120])
        #expect(makeInfo(sourceFPS: 120).availableSmoothRates(displayMaxFPS: 120).isEmpty)
    }

    @Test func singleFrameHasNoSmoothRates() {
        #expect(makeInfo(sourceFPS: 10, frameCount: 1).availableSmoothRates(displayMaxFPS: 120).isEmpty)
    }

    @Test func frameLimitsOnlyForFastSources() {
        #expect(makeInfo(sourceFPS: 30).availableFrameLimits.isEmpty)
        #expect(makeInfo(sourceFPS: 59.94).availableFrameLimits == [30])
        #expect(makeInfo(sourceFPS: 60).availableFrameLimits == [30])
        #expect(makeInfo(sourceFPS: 120).availableFrameLimits == [60, 30])
    }

    @Test func singleFrameIsReportedAsStillOnly() {
        #expect(makeInfo(frameCount: 1).isStillOnly)
        #expect(!makeInfo(frameCount: 2).isStillOnly)
    }
}
