import CoreGraphics
import Testing
@testable import LullCore

private let usable = CGRect(x: 0, y: 33, width: 1512, height: 882)
private let me: Int32 = 100

private func window(
    pid: Int32 = 200,
    layer: Int = 0,
    alpha: Double = 1,
    _ bounds: CGRect
) -> WindowSnapshot {
    WindowSnapshot(ownerPID: pid, layer: layer, alpha: alpha, bounds: bounds)
}

@Suite("Coverage")
struct CoverageTests {
    @Test func noWindowsMeansOpen() {
        #expect(Coverage.desktopIsOpen(windows: [], screens: [usable], excludingPID: me))
    }

    @Test func maximizedWindowCountsAsCovering() {
        let maximized = window(CGRect(x: 0, y: 33, width: 1512, height: 882))
        #expect(!Coverage.desktopIsOpen(windows: [maximized], screens: [usable], excludingPID: me))
    }

    @Test func partialWindowLeavesDesktopOpen() {
        let partial = window(CGRect(x: 100, y: 100, width: 800, height: 500))
        #expect(Coverage.desktopIsOpen(windows: [partial], screens: [usable], excludingPID: me))
    }

    @Test func severalWindowsTogetherCanCover() {
        let left = window(CGRect(x: 0, y: 33, width: 756, height: 882))
        let right = window(CGRect(x: 756, y: 33, width: 756, height: 882))
        #expect(!Coverage.desktopIsOpen(windows: [left, right], screens: [usable], excludingPID: me))
    }

    @Test func windowManagerOverlayOnLayer18IsIgnored() {
        let overlay = window(layer: 18, CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(Coverage.desktopIsOpen(windows: [overlay], screens: [usable], excludingPID: me))
    }

    @Test func floatingWindowsAreIgnored() {
        let floating = window(layer: 3, CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(Coverage.desktopIsOpen(windows: [floating], screens: [usable], excludingPID: me))
    }

    @Test func transparentWindowsAreIgnored() {
        let faded = window(alpha: 0.5, CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(Coverage.desktopIsOpen(windows: [faded], screens: [usable], excludingPID: me))
    }

    @Test func ownWindowsAreIgnored() {
        let own = window(pid: me, CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(Coverage.desktopIsOpen(windows: [own], screens: [usable], excludingPID: me))
    }

    @Test func tinyWindowsAreIgnored() {
        let strip = window(CGRect(x: 0, y: 0, width: 1512, height: 99))
        let filler = window(CGRect(x: 0, y: 99, width: 1512, height: 900))
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(Coverage.desktopIsOpen(windows: [strip, filler], screens: [screen], excludingPID: me))
    }

    @Test func thinGapsAreTreatedAsCovered() {
        let almost = window(CGRect(x: 0, y: 33, width: 1507, height: 882))
        #expect(!Coverage.desktopIsOpen(windows: [almost], screens: [usable], excludingPID: me))
    }

    @Test func anyOpenScreenMeansOpen() {
        let second = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let maximized = window(CGRect(x: 0, y: 33, width: 1512, height: 882))
        #expect(Coverage.desktopIsOpen(windows: [maximized], screens: [usable, second], excludingPID: me))
    }

    @Test func allScreensCoveredMeansCovered() {
        let second = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let first = window(CGRect(x: 0, y: 33, width: 1512, height: 882))
        let other = window(CGRect(x: 1512, y: 0, width: 1920, height: 1080))
        #expect(!Coverage.desktopIsOpen(windows: [first, other], screens: [usable, second], excludingPID: me))
    }

    @Test func noScreensCountsAsOpenSoTheWallpaperNeverSticks() {
        #expect(Coverage.desktopIsOpen(windows: [], screens: [], excludingPID: me))
    }

    @Test func parsesWindowServerDictionaries() {
        let raw: [[String: Any]] = [[
            "kCGWindowOwnerPID": Int32(55),
            "kCGWindowLayer": 0,
            "kCGWindowAlpha": 1.0,
            "kCGWindowBounds": ["X": 10.0, "Y": 20.0, "Width": 300.0, "Height": 200.0],
        ]]
        #expect(Coverage.windows(from: raw) == [
            WindowSnapshot(ownerPID: 55, layer: 0, alpha: 1, bounds: CGRect(x: 10, y: 20, width: 300, height: 200)),
        ])
    }

    @Test func malformedWindowEntriesAreSkipped() {
        #expect(Coverage.windows(from: [["kCGWindowLayer": 0]]).isEmpty)
    }

    @Test func convertsAppKitFramesToTopLeftCoordinates() {
        let visible = CGRect(x: 0, y: 67, width: 1512, height: 882)
        #expect(Coverage.topLeftRect(from: visible, primaryScreenHeight: 982) == CGRect(x: 0, y: 33, width: 1512, height: 882))
    }
}
