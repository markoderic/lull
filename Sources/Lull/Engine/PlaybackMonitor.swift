import AppKit
import LullCore

/// Watches the system and applies the pause rule. Everything here is event driven, except the
/// coverage check, which runs only while its answer could change the decision.
@MainActor
final class PlaybackMonitor {
    private static let finderBundleID = "com.apple.finder"
    private static let coverageInterval: TimeInterval = 2

    private(set) var inputs: PlaybackInputs
    private var decision: PlaybackDecision?
    private var coverageTimer: Timer?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private let onDecision: (PlaybackDecision) -> Void
    /// Called whenever anything the rule looks at changes, even if the decision doesn't.
    var onInputsChange: ((PlaybackInputs) -> Void)?

    init(rule: PauseRuleMode, onDecision: @escaping (PlaybackDecision) -> Void) {
        self.onDecision = onDecision
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Lock notifications only report changes, so ask once in case of launching while locked.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        inputs = PlaybackInputs(
            rule: rule,
            finderIsFrontmost: front == Self.finderBundleID,
            screenLocked: session?["CGSSessionScreenIsLocked"] as? Bool ?? false,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        startObserving()
    }

    deinit {
        MainActor.assumeIsolated {
            observers.forEach { $0.center.removeObserver($0.token) }
            coverageTimer?.invalidate()
        }
    }

    func setRule(_ rule: PauseRuleMode) { update { $0.rule = rule } }
    func setAnimated(_ animated: Bool) { update { $0.hasAnimatedWallpaper = animated } }
    func setPanelOpen(_ open: Bool) { update { $0.panelIsOpen = open } }

    /// Re-checks coverage now, after something like a display change.
    func refresh() { update { _ in } }

    private func update(_ change: (inout PlaybackInputs) -> Void) {
        change(&inputs)
        if inputs.needsCoverageCheck {
            checkCoverage()
            startCoverageTimerIfNeeded()
        } else {
            stopCoverageTimer()
        }
        apply()
    }

    private func apply() {
        onInputsChange?(inputs)
        let newDecision = PauseRule.decide(inputs)
        guard newDecision != decision else { return }
        decision = newDecision
        onDecision(newDecision)
    }

    // MARK: Coverage

    private func checkCoverage() {
        // No answer from the window server means assume visible: the worst case is a little extra
        // playback, rather than a wallpaper that stays stuck.
        guard let windows = Coverage.captureWindows() else {
            inputs.desktopIsOpen = true
            return
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screens = NSScreen.screens.map {
            Coverage.topLeftRect(from: $0.visibleFrame, primaryScreenHeight: primaryHeight)
        }
        inputs.desktopIsOpen = Coverage.desktopIsOpen(
            windows: windows,
            screens: screens,
            excludingPID: ProcessInfo.processInfo.processIdentifier
        )
    }

    private func startCoverageTimerIfNeeded() {
        guard coverageTimer == nil else { return }
        let timer = Timer(timeInterval: Self.coverageInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.inputs.needsCoverageCheck else { return }
                self.checkCoverage()
                self.apply()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        coverageTimer = timer
    }

    private func stopCoverageTimer() {
        coverageTimer?.invalidate()
        coverageTimer = nil
    }

    // MARK: System events

    private func startObserving() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let ownBundleID = Bundle.main.bundleIdentifier

        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            // Opening Lull's own panel activates Lull, and that isn't the person leaving the desktop.
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier, id != ownBundleID else { return }
            MainActor.assumeIsolated { self?.update { $0.finderIsFrontmost = id == Self.finderBundleID } }
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        for (name, asleep) in [
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
            (NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false),
        ] {
            observe(workspace, name) { [weak self] _ in
                MainActor.assumeIsolated { self?.update { $0.screenAsleep = asleep } }
            }
        }
        for (name, inactive) in [
            (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false),
        ] {
            observe(workspace, name) { [weak self] _ in
                MainActor.assumeIsolated { self?.update { $0.sessionInactive = inactive } }
            }
        }
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observe(distributed, Notification.Name(name)) { [weak self] _ in
                MainActor.assumeIsolated { self?.update { $0.screenLocked = locked } }
            }
        }
        for (name, running) in [("com.apple.screensaver.didstart", true), ("com.apple.screensaver.didstop", false)] {
            observe(distributed, Notification.Name(name)) { [weak self] _ in
                MainActor.assumeIsolated { self?.update { $0.screenSaverRunning = running } }
            }
        }
        observe(NotificationCenter.default, Notification.Name.NSProcessInfoPowerStateDidChange) { [weak self] _ in
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            MainActor.assumeIsolated { self?.update { $0.lowPowerMode = lowPower } }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, handler: @escaping @Sendable (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main, using: handler)
        observers.append((center, token))
    }
}
