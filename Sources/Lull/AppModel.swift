import AppKit
import LullCore
import Observation
import ServiceManagement

/// A file being added, shown as a tile with a progress ring until it's ready.
struct PendingImport: Identifiable, Equatable {
    let id: UUID
    let name: String
    var progress: Double
}

/// The app's single source of truth. Views read it, and it drives the engine and monitor.
@MainActor
@Observable
final class AppModel {
    private(set) var wallpapers: [WallpaperInfo] = []
    private(set) var pendingImports: [PendingImport] = []
    private(set) var currentID: UUID?
    private(set) var missingIDs: Set<UUID> = []
    /// Progress of a version being made for a wallpaper, by wallpaper ID.
    private(set) var versionProgress: [UUID: Double] = [:]
    private(set) var pauseRule: PauseRuleMode
    private(set) var schedule: DaySchedule
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var isPanelOpen = false
    private(set) var inputs = PlaybackInputs()
    private(set) var message: String?
    /// Loaded only while the panel is open, so a closed panel holds no images.
    private(set) var thumbnails: [UUID: NSImage] = [:]

    let engine = WallpaperEngine()

    @ObservationIgnored private let store: WallpaperStore
    @ObservationIgnored private let importer: Importer
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let jobs = JobQueue()
    @ObservationIgnored private var monitor: PlaybackMonitor?
    @ObservationIgnored private var scrubTarget: Int?
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var retriedPlayback: Set<UUID> = []
    /// Which job owns each wallpaper's progress. A cancelled job finishes after its replacement has
    /// started, so finishing must only clear the progress if it still belongs to that job.
    @ObservationIgnored private var versionWorkOwners: [UUID: UUID] = [:]
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var scheduleTimer: ScheduleTimer?

    init(store: WallpaperStore = WallpaperStore(), settings: AppSettings = AppSettings()) {
        self.store = store
        self.settings = settings
        importer = Importer(store: store)
        pauseRule = settings.pauseRule
        schedule = settings.daySchedule
    }

    var current: WallpaperInfo? {
        wallpapers.first { $0.id == currentID }
    }

    var displayMaxFPS: Int {
        NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
    }

    var screenAspectRatio: CGFloat {
        guard let frame = NSScreen.main?.frame, frame.height > 0 else { return 16.0 / 10.0 }
        return frame.width / frame.height
    }

    var isSmoothMotionSupported: Bool { SmoothMotion.isAvailable }

    /// The main display's real resolution, which is what "the right size" means to a person.
    var screenPixelSize: (width: Int, height: Int) {
        guard let screen = NSScreen.main else { return (0, 0) }
        return (Int(screen.frame.width * screen.backingScaleFactor), Int(screen.frame.height * screen.backingScaleFactor))
    }

    var bestSizeText: String? {
        WallpaperFit.bestSizeText(screenWidth: screenPixelSize.width, screenHeight: screenPixelSize.height)
    }

    var fitNote: String? {
        current.flatMap { WallpaperFit.note(for: $0, screenWidth: screenPixelSize.width, screenHeight: screenPixelSize.height) }
    }

    var canFitCurrent: Bool {
        current.map { WallpaperFit.canFit($0, screenWidth: screenPixelSize.width, screenHeight: screenPixelSize.height) } ?? false
    }

    /// What the panel's status line says.
    var statusText: String {
        guard let current else { return "" }
        if current.mode == .still { return "Still wallpaper" }
        if inputs.lowPowerMode { return "Paused: Low Power Mode is on" }
        return switch pauseRule {
        case .desktopFocus: "Plays when you click the desktop"
        case .wheneverVisible: "Plays when the desktop is visible"
        }
    }

    // MARK: Starting up

    func start() {
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        store.removeIncompleteItems()
        wallpapers = store.loadAll()
        refreshMissing()

        engine.onPlaybackFailed = { [weak self] in self?.handlePlaybackFailure() }
        monitor = PlaybackMonitor(rule: pauseRule) { [weak self] inputs in
            self?.playbackInputsChanged(inputs)
        }
        inputs = monitor?.inputs ?? inputs

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.engine.rebuildWindows()
                self?.monitor?.refresh()
            }
        }

        // A change may have passed while the app wasn't running, so this comes before restoring.
        scheduleTimer = ScheduleTimer { [weak self] in self?.evaluateSchedule() }
        evaluateSchedule()

        if currentID == nil, let id = settings.currentWallpaperID, let info = wallpapers.first(where: { $0.id == id }) {
            currentID = id
            apply(info, fade: false)
        }
    }

    private func refreshMissing() {
        missingIDs = Set(wallpapers.filter { store.isOriginalMissing($0) && store.isPreparedMissing($0) }.map(\.id))
    }

    // MARK: Adding

    func add(urls: [URL]) {
        for url in urls {
            let id = UUID()
            pendingImports.append(PendingImport(id: id, name: url.deletingPathExtension().lastPathComponent, progress: 0))
            let importer = self.importer
            let report = progressReporter { $0.setImportProgress(id, $1) }
            jobs.enqueue(id: id, onCancelledBeforeStart: { [weak self] in
                self?.pendingImports.removeAll { $0.id == id }
            }) { [weak self] in
                do {
                    let info = try await importer.importFile(url, id: id, progress: report)
                    self?.finishImport(info)
                } catch is CancellationError {
                    self?.pendingImports.removeAll { $0.id == id }
                } catch {
                    self?.pendingImports.removeAll { $0.id == id }
                    self?.show(message: ImportError.classify(error).message)
                }
            }
        }
    }

    /// Importers report from background threads, and the model lives as long as the app does.
    private func progressReporter(_ update: @escaping @MainActor (AppModel, Double) -> Void) -> Importer.Progress {
        let model = self
        return { progress in
            Task { @MainActor in update(model, progress) }
        }
    }

    private func setImportProgress(_ id: UUID, _ progress: Double) {
        guard let index = pendingImports.firstIndex(where: { $0.id == id }) else { return }
        pendingImports[index].progress = progress
    }

    private func finishImport(_ info: WallpaperInfo) {
        pendingImports.removeAll { $0.id == info.id }
        wallpapers.append(info)
        if isPanelOpen { loadThumbnail(for: info) }
        select(info.id)
    }

    // MARK: Choosing

    func select(_ id: UUID) {
        guard id != currentID, let info = wallpapers.first(where: { $0.id == id }), !missingIDs.contains(id) else { return }
        currentID = id
        settings.currentWallpaperID = id
        apply(info, fade: true)
    }

    /// Puts a wallpaper on screen according to its saved settings.
    private func apply(_ info: WallpaperInfo, fade: Bool) {
        if store.isPreparedMissing(info) {
            rebuild(info)
            return
        }
        let still = ImageFiles.read(store.url(WallpaperFile.still, in: info.id))
        if still == nil {
            // The saved still is gone. Remake it rather than leaving a black screen.
            showStillFrame(of: info, commit: true) { [weak self] image in self?.engine.updateStill(image) }
        }
        if info.mode == .still || info.isStillOnly {
            engine.present(still: still, video: nil, startTime: 0, fade: fade)
            monitor?.setAnimated(false)
            syncInputs()
            makeMissingVersionIfNeeded(for: info)
            return
        }
        engine.present(still: still, video: playableURL(for: info), startTime: info.time(forFrame: info.stillFrame), fade: fade)
        monitor?.setAnimated(true)
        syncInputs()
        makeMissingVersionIfNeeded(for: info)
    }

    /// Reads the monitor's latest view of the system, for changes the app made itself.
    private func syncInputs() {
        if let inputs = monitor?.inputs { playbackInputsChanged(inputs) }
    }

    private func playbackInputsChanged(_ inputs: PlaybackInputs) {
        if self.inputs != inputs { self.inputs = inputs }
        engine.setPlayback(desktop: PauseRule.decide(inputs) == .play, preview: inputs.previewShouldPlay)
    }

    /// The wanted version if it exists, otherwise the base file while the wanted one is made.
    private func playableURL(for info: WallpaperInfo) -> URL {
        for filename in [info.playbackFilename, info.baseFilename] where store.fileExists(filename, in: info.id) {
            return store.url(filename, in: info.id)
        }
        return store.url(WallpaperFile.prepared, in: info.id)
    }

    private func rebuild(_ info: WallpaperInfo) {
        guard !store.isOriginalMissing(info), info.originalFilename != nil else {
            missingIDs.insert(info.id)
            if info.id == currentID { engine.clear(); monitor?.setAnimated(false); syncInputs() }
            return
        }
        let importer = self.importer
        let owner = beginVersionWork(on: info.id)
        let report = progressReporter { $0.setVersionProgress(info.id, $1, owner: owner) }
        jobs.enqueue(id: info.id, onCancelledBeforeStart: { [weak self] in
            self?.endVersionWork(on: info.id, owner: owner)
        }) { [weak self] in
            do {
                let rebuilt = try await importer.rebuildPrepared(info, progress: report)
                guard self?.endVersionWork(on: info.id, owner: owner) == true else { return }
                if self?.currentID == rebuilt.id { self?.apply(rebuilt, fade: false) }
            } catch is CancellationError {
                self?.endVersionWork(on: info.id, owner: owner)
            } catch {
                guard self?.endVersionWork(on: info.id, owner: owner) == true else { return }
                self?.show(message: ImportError.classify(error).message)
            }
        }
    }

    private func beginVersionWork(on id: UUID) -> UUID {
        let owner = UUID()
        versionWorkOwners[id] = owner
        versionProgress[id] = 0
        return owner
    }

    /// Returns whether this job still owned the work, which means its result still matters.
    @discardableResult
    private func endVersionWork(on id: UUID, owner: UUID) -> Bool {
        guard versionWorkOwners[id] == owner else { return false }
        clearVersionWork(on: id)
        return true
    }

    private func clearVersionWork(on id: UUID) {
        versionWorkOwners[id] = nil
        versionProgress[id] = nil
    }

    private func setVersionProgress(_ id: UUID, _ progress: Double, owner: UUID) {
        guard versionWorkOwners[id] == owner else { return }
        versionProgress[id] = progress
    }

    // MARK: Still or animated

    func setMode(_ mode: WallpaperInfo.Mode) {
        guard var info = current, info.mode != mode, !info.isStillOnly else { return }
        info.mode = mode
        if mode == .still {
            info.stillFrame = info.frame(forTime: engine.currentTime)
            save(info)
            monitor?.setAnimated(false)
            syncInputs()
            showStillFrame(of: info, commit: true) { [weak self] image in
                // The frame takes a moment to decode, and the person may have switched back.
                guard self?.current?.mode == .still else { return }
                self?.engine.present(still: image, video: nil, startTime: 0, fade: false)
            }
            makeMissingVersionIfNeeded(for: info)
        } else {
            save(info)
            apply(info, fade: false)
        }
    }

    /// Follows the frame slider. Requests arrive faster than frames can decode, so only the latest
    /// one waiting is kept. `commit` is the end of a drag, which also saves the frame.
    func setStillFrame(_ frame: Int, commit: Bool) {
        guard var info = current, info.mode == .still else { return }
        info.stillFrame = frame
        replaceInMemory(info)
        if commit {
            scrubTarget = nil
            save(info)
            showStillFrame(of: info, commit: true) { [weak self] image in
                guard self?.current?.mode == .still else { return }
                self?.engine.updateStill(image)
            }
            return
        }
        scrubTarget = frame
        guard !isScrubbing else { return }
        isScrubbing = true
        Task { [weak self] in await self?.runScrub() }
    }

    private func runScrub() async {
        while let frame = scrubTarget, let info = current {
            scrubTarget = nil
            let image = try? await importer.image(for: info, frame: frame)
            // A later drag or the end of the drag may have moved on while this frame decoded.
            if let image, let latest = current, latest.id == info.id, latest.mode == .still, latest.stillFrame == frame {
                engine.updateStill(image)
            }
        }
        isScrubbing = false
    }

    private func showStillFrame(of info: WallpaperInfo, commit: Bool, then: @escaping @MainActor (CGImage) -> Void) {
        let importer = self.importer
        Task { [weak self] in
            guard let image = try? await importer.image(for: info, frame: info.stillFrame) else { return }
            guard self?.currentID == info.id else { return }
            then(image)
            if commit {
                try? importer.saveStill(image, for: info)
                self?.reloadThumbnail(for: info)
            }
        }
    }

    // MARK: Smooth Motion and frame limit

    func setSmoothMotion(_ on: Bool) {
        guard var info = current else { return }
        info.smoothMotion = on
        if on {
            let rates = info.availableSmoothRates(displayMaxFPS: displayMaxFPS)
            guard let highest = rates.last else { return }
            if !rates.contains(info.smoothRate) { info.smoothRate = highest }
        } else {
            jobs.cancel(id: info.id)
            clearVersionWork(on: info.id)
        }
        save(info)
        settleVersion(info)
    }

    func setSmoothRate(_ rate: Int) {
        guard var info = current, info.smoothRate != rate else { return }
        jobs.cancel(id: info.id)
        clearVersionWork(on: info.id)
        info.smoothRate = rate
        save(info)
        settleVersion(info)
    }

    func setFrameLimit(_ limit: Int?) {
        guard var info = current, info.frameLimit != limit else { return }
        jobs.cancel(id: info.id)
        clearVersionWork(on: info.id)
        info.frameLimit = limit
        save(info)
        settleVersion(info)
    }

    /// Converts the wallpaper to this screen's exact resolution, or goes back to the original.
    func setFitToScreen(_ on: Bool) {
        guard var info = current else { return }
        jobs.cancel(id: info.id)
        clearVersionWork(on: info.id)
        let screen = screenPixelSize
        info.fitSize = on ? FitSize(screenWidth: screen.width, screenHeight: screen.height) : nil
        save(info)
        settleVersion(info)
        if store.fileExists(info.baseFilename, in: info.id) { refreshStill(for: info) }
    }

    /// Keeps the saved still and thumbnail in step when the picture's framing changes.
    private func refreshStill(for info: WallpaperInfo) {
        showStillFrame(of: info, commit: true) { [weak self] image in
            guard self?.current?.mode == .still else { return }
            self?.engine.updateStill(image)
        }
    }

    /// Switches to the version the settings ask for, making it first if needed.
    private func settleVersion(_ info: WallpaperInfo) {
        if store.fileExists(info.wantedFilename, in: info.id) {
            if info.mode == .animated { engine.replaceVideo(with: store.url(info.playbackFilename, in: info.id)) }
        } else {
            makeMissingVersionIfNeeded(for: info)
        }
    }

    private func makeMissingVersionIfNeeded(for info: WallpaperInfo) {
        guard !store.fileExists(info.wantedFilename, in: info.id), versionProgress[info.id] == nil else { return }
        let filename = info.wantedFilename
        let importer = self.importer
        let owner = beginVersionWork(on: info.id)
        let report = progressReporter { $0.setVersionProgress(info.id, $1, owner: owner) }
        jobs.enqueue(id: info.id, onCancelledBeforeStart: { [weak self] in
            self?.endVersionWork(on: info.id, owner: owner)
        }) { [weak self] in
            do {
                try await importer.makeVersion(of: info, progress: report)
                guard self?.endVersionWork(on: info.id, owner: owner) == true else { return }
                self?.versionFinished(filename, for: info.id)
            } catch is CancellationError {
                self?.endVersionWork(on: info.id, owner: owner)
            } catch {
                guard self?.endVersionWork(on: info.id, owner: owner) == true else { return }
                self?.versionFailed(info.id, error: error)
            }
        }
    }

    private func versionFinished(_ filename: String, for id: UUID) {
        guard let info = wallpapers.first(where: { $0.id == id }) else { return }
        // The person may have changed their mind while it was being made.
        guard info.wantedFilename == filename else {
            makeMissingVersionIfNeeded(for: info)
            return
        }
        guard id == currentID else { return }
        if info.mode == .animated { engine.replaceVideo(with: store.url(filename, in: id)) }
        if info.fitSize != nil { refreshStill(for: info) }
    }

    private func versionFailed(_ id: UUID, error: Error) {
        guard var info = wallpapers.first(where: { $0.id == id }) else { return }
        info.smoothMotion = false
        info.frameLimit = nil
        info.fitSize = nil
        save(info)
        show(message: ImportError.classify(error).message)
    }

    // MARK: Day and Night

    /// What the panel says will happen next.
    var scheduleCaption: String? {
        schedule.caption(now: Date(), calendar: .current, locale: .current)
    }

    /// Needs two wallpapers to choose between, but stays visible once on so it can be turned off.
    var canSchedule: Bool { wallpapers.count >= 2 || schedule.isOn }

    func setScheduleOn(_ on: Bool) {
        var plan = schedule
        plan.isOn = on
        if on {
            let ids = wallpapers.map(\.id)
            if plan.dayWallpaperID.map(ids.contains) != true {
                plan.dayWallpaperID = currentID ?? ids.first
            }
            if plan.nightWallpaperID.map(ids.contains) != true || plan.nightWallpaperID == plan.dayWallpaperID {
                plan.nightWallpaperID = ids.first { $0 != plan.dayWallpaperID }
            }
            plan.lastAppliedChange = nil
        }
        updateSchedule(plan)
    }

    func setScheduleWallpaper(_ id: UUID, for slot: ScheduleSlot) {
        var plan = schedule
        if slot == .day { plan.dayWallpaperID = id } else { plan.nightWallpaperID = id }
        // Changing the plan shows its result right away.
        plan.lastAppliedChange = nil
        updateSchedule(plan)
    }

    func setScheduleTime(_ time: ClockTime, for slot: ScheduleSlot) {
        var plan = schedule
        if slot == .day { plan.dayStart = time } else { plan.nightStart = time }
        plan.lastAppliedChange = nil
        updateSchedule(plan)
    }

    private func updateSchedule(_ plan: DaySchedule) {
        schedule = plan
        settings.daySchedule = plan
        evaluateSchedule()
    }

    /// Acts on any change that has come due, then waits for the next one with a single timer.
    private func evaluateSchedule(now: Date = Date()) {
        let calendar = Calendar.current
        guard schedule.isActive else {
            scheduleTimer?.arm(at: nil)
            return
        }
        if schedule.shouldApply(now: now, calendar: calendar) {
            if let id = schedule.wallpaperID(for: schedule.slot(at: now, calendar: calendar)) { select(id) }
            schedule.lastAppliedChange = schedule.mostRecentChange(atOrBefore: now, calendar: calendar)
            settings.daySchedule = schedule
        }
        scheduleTimer?.arm(at: schedule.nextChange(after: now, calendar: calendar))
    }

    // MARK: Removing

    func cancelImport(_ id: UUID) {
        jobs.cancel(id: id)
    }

    /// Stops making a Smooth Motion or frame limit version, and turns that setting back off.
    func cancelVersion(_ id: UUID) {
        jobs.cancel(id: id)
        clearVersionWork(on: id)
        guard var info = wallpapers.first(where: { $0.id == id }) else { return }
        info.smoothMotion = false
        info.frameLimit = nil
        info.fitSize = nil
        save(info)
    }

    func delete(_ id: UUID) {
        jobs.cancel(id: id)
        do {
            try store.trash(id: id)
        } catch {
            show(message: "This wallpaper couldn't be moved to the Trash.")
            return
        }
        wallpapers.removeAll { $0.id == id }
        missingIDs.remove(id)
        thumbnails[id] = nil
        clearVersionWork(on: id)
        var plan = schedule
        let turnedOff = plan.removeWallpaper(id)
        if plan != schedule { updateSchedule(plan) }
        if turnedOff { show(message: "Day and Night is off because one of its wallpapers was deleted.") }
        if id == currentID {
            currentID = nil
            settings.currentWallpaperID = nil
            engine.clear()
            monitor?.setAnimated(false)
            syncInputs()
        }
    }

    // MARK: Playback problems

    private func handlePlaybackFailure() {
        guard let info = current else { return }
        // First failure: the file may be damaged, so rebuild it if there's an original, otherwise
        // try once more. Second failure: stop trying. The still frame stays on screen.
        guard retriedPlayback.insert(info.id).inserted else {
            engine.setPlayback(desktop: false, preview: false)
            show(message: "This wallpaper can't play right now.")
            return
        }
        if info.originalFilename != nil, !store.isOriginalMissing(info), info.playbackFilename == WallpaperFile.prepared {
            try? FileManager.default.removeItem(at: store.url(WallpaperFile.prepared, in: info.id))
            rebuild(info)
        } else {
            apply(info, fade: false)
        }
    }

    // MARK: Settings

    func setPauseRule(_ rule: PauseRuleMode) {
        pauseRule = rule
        settings.pauseRule = rule
        monitor?.setRule(rule)
        syncInputs()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            show(message: "Launch at Login couldn't be changed.")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Panel

    func panelDidOpen() {
        isPanelOpen = true
        thumbnails = [:]
        wallpapers.forEach(loadThumbnail)
        monitor?.setPanelOpen(true)
        syncInputs()
    }

    func panelDidClose() {
        isPanelOpen = false
        thumbnails = [:]
        monitor?.setPanelOpen(false)
        syncInputs()
    }

    private func loadThumbnail(for info: WallpaperInfo) {
        thumbnails[info.id] = NSImage(contentsOf: store.url(WallpaperFile.thumbnail, in: info.id))
    }

    private func reloadThumbnail(for info: WallpaperInfo) {
        if isPanelOpen { loadThumbnail(for: info) }
    }

    // MARK: Saving and messages

    private func replaceInMemory(_ info: WallpaperInfo) {
        guard let index = wallpapers.firstIndex(where: { $0.id == info.id }) else { return }
        wallpapers[index] = info
    }

    private func save(_ info: WallpaperInfo) {
        replaceInMemory(info)
        do {
            try store.save(info)
        } catch {
            show(message: ImportError.classify(error).message)
        }
    }

    func show(message: String) {
        self.message = message
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}
