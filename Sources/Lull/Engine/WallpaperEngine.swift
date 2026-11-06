import AppKit
@preconcurrency import AVFoundation
import QuartzCore

/// Draws the wallpaper: one desktop-level window per display, all fed by one shared player, so a
/// video is only decoded once however many screens show it.
///
/// It can show a still, play, or unload. It doesn't know why it's told to, which is `PlaybackMonitor`'s job.
@MainActor
final class WallpaperEngine {
    private final class DesktopWindow {
        let window: NSWindow
        let surface: WallpaperSurface
        init(window: NSWindow, surface: WallpaperSurface) {
            self.window = window
            self.surface = surface
        }
    }

    private var windows: [DesktopWindow] = []
    private var previews: [WallpaperSurface] = []
    private var surfaces: [WallpaperSurface] { windows.map(\.surface) + previews }

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var looperStatus: NSKeyValueObservation?
    private var stillGenerator: AVAssetImageGenerator?

    private var videoURL: URL?
    /// The file `player` was built for, which `videoURL` can move on from while paused.
    private var loadedURL: URL?
    private var savedTime = CMTime.zero
    private var lastStill: CGImage?
    private var hasContent = false
    private var seekFinished = false
    private var isFading = false

    private(set) var wantsPlaying = false
    /// Bumped by anything that invalidates a still frame capture still in flight.
    private var captureGeneration = 0
    /// Bumped by anything that replaces what's being shown.
    private var presentGeneration = 0

    /// Called when the player can't play its file.
    var onPlaybackFailed: (() -> Void)?

    // MARK: Showing things

    /// Shows a new wallpaper. `video` is `nil` for a still.
    func present(still: CGImage?, video: URL?, startTime: Double, fade: Bool) {
        presentGeneration += 1
        captureGeneration += 1
        let generation = presentGeneration
        let shouldFade = fade && hasContent && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        hasContent = true
        ensureWindows()

        lastStill = still
        surfaces.forEach { $0.setStill(still, fade: shouldFade) }
        player?.pause()
        videoURL = video
        savedTime = CMTime(seconds: startTime, preferredTimescale: 600_000)

        guard shouldFade else {
            isFading = false
            unload()
            if wantsPlaying { buildPlayer() }
            return
        }
        // The old video stays visible under the fading still, then is swapped out behind it.
        isFading = true
        DispatchQueue.main.asyncAfter(deadline: .now() + WallpaperSurface.fadeDuration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.presentGeneration else { return }
                self.isFading = false
                self.unload()
                if self.wantsPlaying { self.buildPlayer() }
            }
        }
    }

    /// Changes the still immediately, for dragging the frame slider.
    func updateStill(_ image: CGImage) {
        lastStill = image
        surfaces.forEach { $0.setStill(image, fade: false) }
    }

    /// Swaps to another version of the same wallpaper, keeping its place. They share a timeline.
    func replaceVideo(with url: URL) {
        guard url != videoURL else { return }
        // A fade in progress loads whatever is current when it ends, from the place it was given.
        if isFading {
            videoURL = url
            return
        }
        let seconds = currentTime
        let time = CMTime(seconds: seconds, preferredTimescale: 600_000)
        guard wantsPlaying, let player, let oldURL = videoURL else {
            // Nothing visible depends on the new file yet. A pause still in progress finishes with
            // the old file, which shows the same frame, and the next resume loads this one.
            videoURL = url
            savedTime = time
            return
        }
        presentGeneration += 1
        captureGeneration += 1
        let generation = presentGeneration
        player.pause()
        captureStill(from: oldURL, at: seconds) { [weak self] image in
            guard let self, generation == self.presentGeneration else { return }
            if let image {
                self.lastStill = image
                self.surfaces.forEach { $0.setStill(image, fade: false) }
            }
            self.unload()
            self.videoURL = url
            self.savedTime = time
            if self.wantsPlaying { self.buildPlayer() }
        }
    }

    /// Removes every window, so the normal wallpaper shows and nothing is left running.
    func clear() {
        presentGeneration += 1
        captureGeneration += 1
        unload()
        videoURL = nil
        lastStill = nil
        savedTime = .zero
        hasContent = false
        isFading = false
        windows.forEach { $0.window.orderOut(nil) }
        windows.removeAll()
        previews.forEach { $0.setStill(nil, fade: false) }
    }

    /// The current place in the video's timeline.
    var currentTime: Double {
        if let player {
            let time = player.currentTime().seconds
            if time.isFinite { return time }
        }
        return savedTime.seconds
    }

    // MARK: Playing and pausing

    func setPlaying(_ playing: Bool) {
        guard playing != wantsPlaying else { return }
        wantsPlaying = playing
        captureGeneration += 1
        // A fade in progress finishes by checking `wantsPlaying` itself.
        guard !isFading else { return }
        if playing {
            resume()
        } else {
            pauseAndUnload()
        }
    }

    private func resume() {
        if let player, loadedURL == videoURL {
            player.play()
            lastStill = nil
            surfaces.forEach { $0.setStill(nil, fade: false) }
        } else {
            unload()
            buildPlayer()
        }
    }

    /// Pauses, puts the exact frame up as a still, then fully unloads the player so it costs nothing.
    private func pauseAndUnload() {
        guard let player, let url = videoURL else { return }
        player.pause()
        // Before its item loads, a player has no valid time. The place it was given is still right.
        let time = player.currentTime()
        if time.isNumeric { savedTime = time }
        let generation = captureGeneration
        captureStill(from: url, at: savedTime.seconds) { [weak self] image in
            guard let self, generation == self.captureGeneration, !self.wantsPlaying else { return }
            // With no frame to show, the paused player stays up. That beats a black desktop.
            guard let image else { return }
            self.lastStill = image
            self.surfaces.forEach { $0.setStill(image, fade: false) }
            self.unload()
        }
    }

    private func captureStill(from url: URL, at seconds: Double, then: @escaping @MainActor (CGImage?) -> Void) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        stillGenerator = generator
        let time = CMTime(seconds: seconds, preferredTimescale: 600_000)
        generator.generateCGImageAsynchronously(for: time) { image, _, _ in
            Task { @MainActor in then(image) }
        }
    }

    private func buildPlayer() {
        guard let url = videoURL else { return }
        let newPlayer = AVQueuePlayer()
        newPlayer.isMuted = true
        // Without this the Mac would never sleep its display while a wallpaper plays.
        newPlayer.preventsDisplaySleepDuringVideoPlayback = false
        newPlayer.automaticallyWaitsToMinimizeStalling = false
        newPlayer.allowsExternalPlayback = false
        let newLooper = AVPlayerLooper(player: newPlayer, templateItem: AVPlayerItem(asset: AVURLAsset(url: url)))
        looperStatus = newLooper.observe(\.status, options: [.new]) { [weak self] looper, _ in
            guard looper.status == .failed else { return }
            Task { @MainActor [weak self] in self?.onPlaybackFailed?() }
        }
        player = newPlayer
        looper = newLooper
        loadedURL = url
        seekFinished = false
        surfaces.forEach { $0.attach(newPlayer) }
        startWhenItemExists(newPlayer, at: savedTime, attemptsLeft: 200)
    }

    /// The looper creates its items lazily, and seeking before one exists does nothing.
    private func startWhenItemExists(_ candidate: AVQueuePlayer, at time: CMTime, attemptsLeft: Int) {
        guard candidate === player else { return }
        if candidate.currentItem == nil, attemptsLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
                MainActor.assumeIsolated {
                    self?.startWhenItemExists(candidate, at: time, attemptsLeft: attemptsLeft - 1)
                }
            }
            return
        }
        candidate.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, candidate === self.player else { return }
                self.seekFinished = true
                if self.wantsPlaying { candidate.play() }
                self.revealPlayerWhereReady()
            }
        }
    }

    /// Takes the still away only once the video underneath can show the right frame.
    private func revealPlayerWhereReady() {
        guard seekFinished, wantsPlaying else { return }
        for surface in surfaces where surface.isReadyForDisplay {
            surface.setStill(nil, fade: false)
        }
    }

    private func unload() {
        looperStatus = nil
        looper?.disableLooping()
        player?.pause()
        player?.removeAllItems()
        surfaces.forEach { $0.attach(nil) }
        looper = nil
        player = nil
        loadedURL = nil
        stillGenerator = nil
        seekFinished = false
    }

    // MARK: Windows and previews

    /// Matches windows to the current displays. Called when a display is connected, removed or changed.
    func rebuildWindows() {
        guard hasContent else { return }
        windows.forEach { $0.window.orderOut(nil) }
        windows.removeAll()
        ensureWindows()
    }

    private func ensureWindows() {
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.isOpaque = true
            window.hasShadow = false
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.canHide = false
            window.animationBehavior = .none
            window.setFrame(screen.frame, display: false)

            let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            window.contentView = view
            guard let host = view.layer else { continue }

            let surface = WallpaperSurface(host: host)
            surface.resize(to: view.bounds)
            configure(surface)
            window.orderFrontRegardless()
            windows.append(DesktopWindow(window: window, surface: surface))
        }
    }

    private func configure(_ surface: WallpaperSurface) {
        surface.onReady = { [weak self] _ in self?.revealPlayerWhereReady() }
        surface.setStill(lastStill, fade: false)
        surface.attach(player)
    }

    func add(preview: WallpaperSurface) {
        previews.append(preview)
        configure(preview)
    }

    func remove(preview: WallpaperSurface) {
        preview.attach(nil)
        previews.removeAll { $0 === preview }
    }

    #if DEBUG
    var debugWindowCount: Int { windows.count }
    var debugPlayerRate: Float? { player?.rate }
    /// Whether the panel's preview has video it can show.
    var debugPreviewReady: Bool { previews.contains { $0.isReadyForDisplay } }
    var debugStillVisible: Bool { windows.first?.surface.hasStill ?? false }
    #endif
}
