/// Which situations let the wallpaper play. The person chooses one.
public enum PauseRuleMode: String, Codable, Sendable, CaseIterable {
    case desktopFocus
    case wheneverVisible
}

/// Everything the pause rule needs to know, in one value.
public struct PlaybackInputs: Equatable, Sendable {
    public var rule: PauseRuleMode
    public var hasAnimatedWallpaper: Bool
    public var finderIsFrontmost: Bool
    public var desktopIsOpen: Bool
    public var panelIsOpen: Bool
    public var screenLocked: Bool
    public var screenAsleep: Bool
    public var screenSaverRunning: Bool
    public var sessionInactive: Bool
    public var lowPowerMode: Bool

    public init(
        rule: PauseRuleMode = .desktopFocus,
        hasAnimatedWallpaper: Bool = false,
        finderIsFrontmost: Bool = false,
        desktopIsOpen: Bool = true,
        panelIsOpen: Bool = false,
        screenLocked: Bool = false,
        screenAsleep: Bool = false,
        screenSaverRunning: Bool = false,
        sessionInactive: Bool = false,
        lowPowerMode: Bool = false
    ) {
        self.rule = rule
        self.hasAnimatedWallpaper = hasAnimatedWallpaper
        self.finderIsFrontmost = finderIsFrontmost
        self.desktopIsOpen = desktopIsOpen
        self.panelIsOpen = panelIsOpen
        self.screenLocked = screenLocked
        self.screenAsleep = screenAsleep
        self.screenSaverRunning = screenSaverRunning
        self.sessionInactive = sessionInactive
        self.lowPowerMode = lowPowerMode
    }

    var screenIsUnavailable: Bool {
        screenLocked || screenAsleep || screenSaverRunning || sessionInactive
    }

    /// Whether a coverage check could change the decision. Checking is the only recurring
    /// work the app does while idle, so it runs only when this is true.
    public var needsCoverageCheck: Bool {
        guard hasAnimatedWallpaper, !screenIsUnavailable, !lowPowerMode else { return false }
        return rule == .wheneverVisible || finderIsFrontmost
    }

    /// How soon to check coverage again, or nil when checking couldn't change the decision.
    ///
    /// While the desktop is covered, the next check is what starts the wallpaper, so it comes
    /// quickly: a window on its way out is often still there at the moment focus changes. Once
    /// the desktop is open, a late check only means a little playback nobody can see. Under
    /// Whenever Visible, being covered can last all day, so that case checks less often.
    public var coverageCheckInterval: Double? {
        guard needsCoverageCheck else { return nil }
        if desktopIsOpen { return 2 }
        return rule == .desktopFocus ? 0.1 : 0.25
    }

    /// The panel's preview stays live while it's open. This never moves the desktop: the desktop
    /// only ever follows `PauseRule`.
    public var previewShouldPlay: Bool {
        panelIsOpen && hasAnimatedWallpaper && !screenIsUnavailable && !lowPowerMode
    }
}

public enum PauseReason: Equatable, Sendable {
    case notAnimated
    case screenUnavailable
    case lowPowerMode
    case otherAppFocused
    case desktopCovered
}

public enum PlaybackDecision: Equatable, Sendable {
    case play
    case pause(PauseReason)
}

public enum PauseRule {
    public static func decide(_ inputs: PlaybackInputs) -> PlaybackDecision {
        guard inputs.hasAnimatedWallpaper else { return .pause(.notAnimated) }
        if inputs.screenIsUnavailable { return .pause(.screenUnavailable) }
        if inputs.lowPowerMode { return .pause(.lowPowerMode) }
        if inputs.rule == .desktopFocus, !inputs.finderIsFrontmost { return .pause(.otherAppFocused) }
        if !inputs.desktopIsOpen { return .pause(.desktopCovered) }
        return .play
    }
}
