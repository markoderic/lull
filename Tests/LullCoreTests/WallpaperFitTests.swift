import Foundation
import Testing
@testable import LullCore

private let macBook = (width: 3024, height: 1964)

private func fit(_ width: Int, _ height: Int, kind: WallpaperInfo.Kind = .video) -> WallpaperFit {
    WallpaperFit.evaluate(
        mediaWidth: width, mediaHeight: height, kind: kind,
        screenWidth: macBook.width, screenHeight: macBook.height
    )
}

private func info(_ width: Int, _ height: Int, kind: WallpaperInfo.Kind = .video) -> WallpaperInfo {
    WallpaperInfo(
        id: UUID(), name: "Test", kind: kind, addedAt: Date(timeIntervalSince1970: 0),
        originalFilename: nil, width: width, height: height, duration: 1, sourceFPS: 30, frameCount: 30
    )
}

@Suite("Wallpaper fit")
struct WallpaperFitTests {
    @Test func aFileMatchingTheScreenFitsWell() {
        #expect(fit(3024, 1964) == .good)
    }

    @Test func aVerticalVideoIsCropped() {
        #expect(fit(1080, 1920) == .cropped(hiddenPercent: 63))
    }

    @Test func aSquareFileIsCropped() {
        #expect(fit(2000, 2000) == .cropped(hiddenPercent: 35))
    }

    @Test func commonLandscapeShapesAreCloseEnough() {
        #expect(fit(3840, 2160) == .good)
        #expect(fit(1920, 1080) == .good)
        #expect(fit(1600, 1200) == .good)
    }

    @Test func aVideoNeedingMoreThanDoubleEnlargingLooksSoft() {
        #expect(fit(1280, 720) == .soft)
    }

    @Test func smallGIFsArentFlaggedAsSoftBecauseThatsNormalForThem() {
        #expect(fit(1280, 720, kind: .gif) == .good)
    }

    @Test func verticalGIFsAreStillFlaggedAsCropped() {
        #expect(fit(1080, 1920, kind: .gif) == .cropped(hiddenPercent: 63))
    }

    @Test func aVerticalVideoFitsAVerticalScreen() {
        let result = WallpaperFit.evaluate(mediaWidth: 1080, mediaHeight: 1920, kind: .video, screenWidth: 1080, screenHeight: 1920)
        #expect(result == .good)
    }

    @Test func missingSizesDontProduceAWarning() {
        #expect(fit(0, 0) == .good)
        #expect(WallpaperFit.evaluate(mediaWidth: 100, mediaHeight: 100, kind: .video, screenWidth: 0, screenHeight: 0) == .good)
    }

    @Test func aGoodFitHasNoNote() {
        #expect(WallpaperFit.note(for: info(3024, 1964), screenWidth: 3024, screenHeight: 1964) == nil)
    }

    @Test func aCroppedFileSaysHowMuchIsHiddenAndWhatToUse() {
        #expect(
            WallpaperFit.note(for: info(1080, 1920), screenWidth: 3024, screenHeight: 1964)
                == "Zoomed in to fill your screen, hiding about 63% of this file. Turn on Fit to Screen to see all of it, or use a landscape file around 3024 × 1964."
        )
    }

    @Test func aSoftVideoSaysWhatSizeWouldLookSharpest() {
        #expect(
            WallpaperFit.note(for: info(1280, 720), screenWidth: 3024, screenHeight: 1964)
                == "This video is smaller than your screen, so it may look soft. A file around 3024 × 1964 would look sharpest."
        )
    }

    @Test func theAdviceFollowsAVerticalScreen() {
        let note = WallpaperFit.note(for: info(1920, 1080), screenWidth: 1080, screenHeight: 1920)
        #expect(note?.contains("or use a vertical file around 1080 × 1920.") == true)
    }

    @Test func aFittedFileHasNoNote() {
        var fitted = info(1080, 1920)
        fitted.fitSize = FitSize(screenWidth: 3024, screenHeight: 1964)
        #expect(WallpaperFit.note(for: fitted, screenWidth: 3024, screenHeight: 1964) == nil)
    }

    @Test func fitToScreenIsOfferedOnlyWhenPartOfThePictureIsHidden() {
        #expect(WallpaperFit.canFit(info(1080, 1920), screenWidth: 3024, screenHeight: 1964))
        #expect(!WallpaperFit.canFit(info(3024, 1964), screenWidth: 3024, screenHeight: 1964))
        #expect(!WallpaperFit.canFit(info(1280, 720), screenWidth: 3024, screenHeight: 1964))
    }

    @Test func fitToScreenStaysAvailableToTurnOff() {
        var fitted = info(3024, 1964)
        fitted.fitSize = FitSize(screenWidth: 3024, screenHeight: 1964)
        #expect(WallpaperFit.canFit(fitted, screenWidth: 3024, screenHeight: 1964))
    }

    @Test func fitSizesAreEvenBecauseHEVCRequiresIt() {
        let size = FitSize(screenWidth: 1921, screenHeight: 1081)
        #expect(size.width == 1922)
        #expect(size.height == 1082)
    }

    @Test func fitSizeSelectsItsOwnFiles() {
        var fitted = info(1080, 1920)
        let size = FitSize(screenWidth: 3024, screenHeight: 1964)
        fitted.fitSize = size
        #expect(fitted.baseFilename == "fit-3024x1964.mp4")
        #expect(fitted.playbackFilename == "fit-3024x1964.mp4")
        fitted.frameLimit = 30
        #expect(fitted.playbackFilename == "limit-30-fit-3024x1964.mp4")
        fitted.smoothMotion = true
        fitted.smoothRate = 120
        #expect(fitted.playbackFilename == "smooth-120-fit-3024x1964.mp4")
    }

    @Test func aStillOnlyNeedsTheBaseFile() {
        var fitted = info(1080, 1920)
        fitted.fitSize = FitSize(screenWidth: 3024, screenHeight: 1964)
        fitted.smoothMotion = true
        fitted.mode = .still
        #expect(fitted.wantedFilename == "fit-3024x1964.mp4")
        fitted.mode = .animated
        #expect(fitted.wantedFilename == "smooth-120-fit-3024x1964.mp4")
    }

    @Test func wallpapersSavedBeforeThisFeatureStillLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lull-old-\(UUID().uuidString)")
        let store = WallpaperStore(root: root)
        let old = info(640, 360)
        try store.createFolder(for: old.id)
        try store.save(old)
        let url = store.url(WallpaperFile.info, in: old.id)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json.removeValue(forKey: "fitSize")
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        #expect(store.loadAll().first?.fitSize == nil)
        #expect(store.loadAll().count == 1)
    }

    @Test func theBestSizeIsNamedForALandscapeScreen() {
        #expect(WallpaperFit.bestSizeText(screenWidth: 3024, screenHeight: 1964) == "Best fit for this screen: 3024 × 1964, landscape.")
    }

    @Test func theBestSizeIsNamedForAVerticalScreen() {
        #expect(WallpaperFit.bestSizeText(screenWidth: 1080, screenHeight: 1920) == "Best fit for this screen: 1080 × 1920, vertical.")
    }

    @Test func noScreenSizeMeansNoAdvice() {
        #expect(WallpaperFit.bestSizeText(screenWidth: 0, screenHeight: 0) == nil)
    }
}
