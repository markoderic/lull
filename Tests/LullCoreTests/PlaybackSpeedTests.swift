import Foundation
import Testing
@testable import LullCore

private func info(speed: Double? = nil) -> WallpaperInfo {
    WallpaperInfo(
        id: UUID(), name: "Test", kind: .gif, addedAt: Date(timeIntervalSince1970: 0),
        originalFilename: nil, width: 640, height: 360, duration: 4, sourceFPS: 25, frameCount: 100, speed: speed
    )
}

@Suite("Playback speed")
struct PlaybackSpeedTests {
    @Test func theScaleRunsFromAQuarterSpeedToDouble() {
        #expect(PlaybackSpeed.stops == [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2])
    }

    @Test func normalIsInTheMiddleOfTheSlider() {
        #expect(PlaybackSpeed.stops[PlaybackSpeed.stops.count / 2] == 1)
    }

    @Test func eachStopFindsItsOwnPosition() {
        for (index, stop) in PlaybackSpeed.stops.enumerated() {
            #expect(PlaybackSpeed.index(of: stop) == index)
        }
    }

    @Test func aValueBetweenStopsGoesToTheNearest() {
        #expect(PlaybackSpeed.index(of: 0.3) == 0)
        #expect(PlaybackSpeed.index(of: 1.9) == 6)
    }

    @Test func aDamagedValueStaysOnTheScale() {
        #expect(PlaybackSpeed.stops[PlaybackSpeed.index(of: 50)] == 2)
        #expect(PlaybackSpeed.stops[PlaybackSpeed.index(of: -3)] == 0.25)
    }

    @Test(arguments: [
        (0.25, "0.25×"), (0.5, "0.5×"), (0.75, "0.75×"), (1.0, "Normal"), (1.25, "1.25×"), (1.5, "1.5×"), (2.0, "2×"),
    ] as [(Double, String)])
    func labelsUseTheFamiliarForm(_ speed: Double, _ expected: String) {
        #expect(PlaybackSpeed.label(for: speed) == expected)
    }

    @Test func slowingAChoppyFileSuggestsSmoothMotion() {
        #expect(
            PlaybackSpeed.hint(speed: 0.5, sourceFPS: 12.5, smoothMotion: false, canUseSmoothMotion: true)
                == "That's about 6 frames a second. Smooth Motion keeps it fluid."
        )
    }

    @Test func thereIsNoHintAtNormalSpeed() {
        #expect(PlaybackSpeed.hint(speed: 1, sourceFPS: 10, smoothMotion: false, canUseSmoothMotion: true) == nil)
    }

    @Test func thereIsNoHintWhenItsStillFluid() {
        #expect(PlaybackSpeed.hint(speed: 0.5, sourceFPS: 60, smoothMotion: false, canUseSmoothMotion: true) == nil)
    }

    @Test func thereIsNoHintOnceSmoothMotionIsOn() {
        #expect(PlaybackSpeed.hint(speed: 0.25, sourceFPS: 12.5, smoothMotion: true, canUseSmoothMotion: true) == nil)
    }

    @Test func thereIsNoHintWhenSmoothMotionIsntAvailable() {
        #expect(PlaybackSpeed.hint(speed: 0.25, sourceFPS: 12.5, smoothMotion: false, canUseSmoothMotion: false) == nil)
    }

    @Test func aWallpaperPlaysAtNormalSpeedByDefault() {
        #expect(info().playbackSpeed == 1)
    }

    @Test func aWallpaperRemembersItsSpeed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lull-speed-\(UUID().uuidString)")
        let store = WallpaperStore(root: root)
        let saved = info(speed: 0.5)
        try store.createFolder(for: saved.id)
        try store.save(saved)
        #expect(store.loadAll().first?.playbackSpeed == 0.5)
    }

    @Test func wallpapersSavedBeforeThisFeatureStillLoad() throws {
        // People already have wallpapers saved without a speed, and they mustn't disappear.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lull-speed-\(UUID().uuidString)")
        let store = WallpaperStore(root: root)
        let old = info()
        try store.createFolder(for: old.id)
        try store.save(old)
        let url = store.url(WallpaperFile.info, in: old.id)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json.removeValue(forKey: "speed")
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        #expect(store.loadAll().count == 1)
        #expect(store.loadAll().first?.playbackSpeed == 1)
    }
}
