import Testing
@testable import LullCore

private func inputs(
    rule: PauseRuleMode = .desktopFocus,
    animated: Bool = true,
    finder: Bool = true,
    open: Bool = true,
    panel: Bool = false,
    locked: Bool = false,
    asleep: Bool = false,
    saver: Bool = false,
    inactive: Bool = false,
    lowPower: Bool = false
) -> PlaybackInputs {
    PlaybackInputs(
        rule: rule,
        hasAnimatedWallpaper: animated,
        finderIsFrontmost: finder,
        desktopIsOpen: open,
        panelIsOpen: panel,
        screenLocked: locked,
        screenAsleep: asleep,
        screenSaverRunning: saver,
        sessionInactive: inactive,
        lowPowerMode: lowPower
    )
}

@Suite("Pause rule")
struct PauseRuleTests {
    @Test func desktopFocusPlaysWhenFinderIsFrontAndDesktopIsOpen() {
        #expect(PauseRule.decide(inputs()) == .play)
    }

    @Test func desktopFocusPausesWhenAnotherAppIsFrontmost() {
        #expect(PauseRule.decide(inputs(finder: false)) == .pause(.otherAppFocused))
    }

    @Test func desktopFocusPausesWhenFinderWindowsCoverTheDesktop() {
        #expect(PauseRule.decide(inputs(open: false)) == .pause(.desktopCovered))
    }

    @Test func wheneverVisibleIgnoresFocus() {
        #expect(PauseRule.decide(inputs(rule: .wheneverVisible, finder: false)) == .play)
    }

    @Test func wheneverVisiblePausesWhenCovered() {
        #expect(PauseRule.decide(inputs(rule: .wheneverVisible, finder: false, open: false)) == .pause(.desktopCovered))
    }

    @Test(arguments: [
        inputs(locked: true), inputs(asleep: true), inputs(saver: true), inputs(inactive: true),
        inputs(rule: .wheneverVisible, locked: true), inputs(panel: true, locked: true),
    ])
    func screenStatesAlwaysPause(_ state: PlaybackInputs) {
        #expect(PauseRule.decide(state) == .pause(.screenUnavailable))
    }

    @Test func lowPowerAlwaysPauses() {
        #expect(PauseRule.decide(inputs(lowPower: true)) == .pause(.lowPowerMode))
    }

    @Test func lowPowerBeatsAnOpenPanel() {
        #expect(PauseRule.decide(inputs(panel: true, lowPower: true)) == .pause(.lowPowerMode))
    }

    @Test func anOpenPanelDoesntOverrideTheRuleForTheDesktop() {
        #expect(PauseRule.decide(inputs(finder: false, panel: true)) == .pause(.otherAppFocused))
        #expect(PauseRule.decide(inputs(open: false, panel: true)) == .pause(.desktopCovered))
        #expect(PauseRule.decide(inputs(panel: true)) == .play)
    }

    @Test func thePreviewPlaysWhileThePanelIsOpen() {
        #expect(inputs(finder: false, open: false, panel: true).previewShouldPlay)
    }

    @Test func thePreviewStopsWhenThePanelCloses() {
        #expect(!inputs(panel: false).previewShouldPlay)
    }

    @Test func thePreviewRespectsLockingAndLowPower() {
        #expect(!inputs(panel: true, locked: true).previewShouldPlay)
        #expect(!inputs(panel: true, lowPower: true).previewShouldPlay)
    }

    @Test func aStillWallpaperHasNoPreviewToPlay() {
        #expect(!inputs(animated: false, panel: true).previewShouldPlay)
    }

    @Test func stillWallpaperNeverPlays() {
        #expect(PauseRule.decide(inputs(animated: false)) == .pause(.notAnimated))
        #expect(PauseRule.decide(inputs(animated: false, panel: true)) == .pause(.notAnimated))
    }

    @Test func coverageIsCheckedOnlyWhenItCouldChangeTheDecision() {
        #expect(inputs().needsCoverageCheck)
        #expect(inputs(rule: .wheneverVisible, finder: false).needsCoverageCheck)
        #expect(!inputs(finder: false).needsCoverageCheck)
        #expect(!inputs(animated: false).needsCoverageCheck)
        #expect(inputs(panel: true).needsCoverageCheck)
        #expect(!inputs(finder: false, panel: true).needsCoverageCheck)
        #expect(!inputs(locked: true).needsCoverageCheck)
        #expect(!inputs(asleep: true).needsCoverageCheck)
        #expect(!inputs(saver: true).needsCoverageCheck)
        #expect(!inputs(inactive: true).needsCoverageCheck)
        #expect(!inputs(lowPower: true).needsCoverageCheck)
    }
}
