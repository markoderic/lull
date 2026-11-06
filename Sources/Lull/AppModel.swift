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
    @ObservationIgnored private var screenObserver: NSObjectProtocol?

    init(store: WallpaperStore = WallpaperStore(), settings: AppSettings = AppSettings()) {
        self.store = store
        self.settings = settings
        importer = Importer(store: store)
        pauseRule = settings.pauseRule
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
        monitor = PlaybackMonitor(rule: pauseRule) { [weak self] decision in
            guard let self else { return }
            self.engine.setPlaying(decision == .play)
            if let inputs = self.monitor?.inputs { self.inputs = inputs }
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

        if let id = settings.currentWallpaperID, let info = wallpapers.first(where: { $0.id == id }) {
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
        if info.mode == .still || info.isStillOnly {
            engine.present(still: still, video: nil, startTime: 0, fade: fade)
            monitor?.setAnimated(false)
            syncInputs()
            return
        }
        engine.present(still: still, video: playableURL(for: info), startTime: info.time(forFrame: info.stillFrame), fade: fade)
        monitor?.setAnimated(true)
        syncInputs()
        makeMissingVersionIfNeeded(for: info)
    }

    private func syncInputs() {
        if let inputs = monitor?.inputs { self.inputs = inputs }
    }

    /// The wanted version if it exists, otherwise the base file while the wanted one is made.
    private func playableURL(for info: WallpaperInfo) -> URL {
        if store.fileExists(info.playbackFilename, in: info.id) {
            return store.url(info.playbackFilename, in: info.id)
        }
        if !info.smoothMotion, let limit = info.frameLimit, store.fileExists(WallpaperFile.limit(limit), in: info.id) {
            return store.url(WallpaperFile.limit(limit), in: info.id)
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
        let report = progressReporter { $0.setVersionProgress(info.id, $1) }
        versionProgress[info.id] = 0
        jobs.enqueue(id: info.id, onCancelledBeforeStart: { [weak self] in
            self?.versionProgress[info.id] = nil
        }) { [weak self] in
            do {
                let rebuilt = try await importer.rebuildPrepared(info, progress: report)
                self?.versionProgress[info.id] = nil
                if self?.currentID == rebuilt.id { self?.apply(rebuilt, fade: false) }
            } catch is CancellationError {
                self?.versionProgress[info.id] = nil
            } catch {
                self?.versionProgress[info.id] = nil
                self?.show(message: ImportError.classify(error).message)
            }
        }
    }

    private func setVersionProgress(_ id: UUID, _ progress: Double) {
        guard versionProgress[id] != nil else { return }
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
                self?.engine.present(still: image, video: nil, startTime: 0, fade: false)
            }
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
            save(info)
            showStillFrame(of: info, commit: true) { [weak self] image in self?.engine.updateStill(image) }
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
            if let image = try? await importer.image(for: info, frame: frame), info.id == currentID, info.mode == .still {
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
            versionProgress[info.id] = nil
        }
        save(info)
        settleVersion(info)
    }

    func setSmoothRate(_ rate: Int) {
        guard var info = current, info.smoothRate != rate else { return }
        jobs.cancel(id: info.id)
        versionProgress[info.id] = nil
        info.smoothRate = rate
        save(info)
        settleVersion(info)
    }

    func setFrameLimit(_ limit: Int?) {
        guard var info = current, info.frameLimit != limit else { return }
        jobs.cancel(id: info.id)
        versionProgress[info.id] = nil
        info.frameLimit = limit
        save(info)
        settleVersion(info)
    }

    /// Switches to the version the settings ask for, making it first if needed.
    private func settleVersion(_ info: WallpaperInfo) {
        if store.fileExists(info.playbackFilename, in: info.id) {
            if info.mode == .animated { engine.replaceVideo(with: store.url(info.playbackFilename, in: info.id)) }
        } else {
            makeMissingVersionIfNeeded(for: info)
        }
    }

    private func makeMissingVersionIfNeeded(for info: WallpaperInfo) {
        guard !store.fileExists(info.playbackFilename, in: info.id), versionProgress[info.id] == nil else { return }
        let filename = info.playbackFilename
        let importer = self.importer
        versionProgress[info.id] = 0
        let report = progressReporter { $0.setVersionProgress(info.id, $1) }
        jobs.enqueue(id: info.id, onCancelledBeforeStart: { [weak self] in
            self?.versionProgress[info.id] = nil
        }) { [weak self] in
            do {
                if info.smoothMotion {
                    try await importer.makeSmoothVersion(of: info, rate: info.smoothRate, progress: report)
                } else if let limit = info.frameLimit {
                    try await importer.makeLimitedVersion(of: info, limit: limit, progress: report)
                }
                self?.versionProgress[info.id] = nil
                self?.versionFinished(filename, for: info.id)
            } catch is CancellationError {
                self?.versionProgress[info.id] = nil
            } catch {
                self?.versionProgress[info.id] = nil
                self?.versionFailed(info.id, error: error)
            }
        }
    }

    private func versionFinished(_ filename: String, for id: UUID) {
        guard let info = wallpapers.first(where: { $0.id == id }) else { return }
        // The person may have changed their mind while it was being made.
        if info.playbackFilename == filename, id == currentID, info.mode == .animated {
            engine.replaceVideo(with: store.url(filename, in: id))
        } else if info.playbackFilename != filename {
            makeMissingVersionIfNeeded(for: info)
        }
    }

    private func versionFailed(_ id: UUID, error: Error) {
        guard var info = wallpapers.first(where: { $0.id == id }) else { return }
        info.smoothMotion = false
        info.frameLimit = nil
        save(info)
        show(message: ImportError.classify(error).message)
    }

    // MARK: Removing

    func cancelImport(_ id: UUID) {
        jobs.cancel(id: id)
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
        versionProgress[id] = nil
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
            engine.setPlaying(false)
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
