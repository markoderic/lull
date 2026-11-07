#if DEBUG
import AppKit
import LullCore

/// Lets the end-to-end checks drive the running app and read its state. Compiled only into debug
/// builds, so release builds carry no remote control of any kind.
///
/// Send a distributed notification named `com.markoderic.lull.debug` whose object is a command, such
/// as `select 0` or `mode still`. State is written after every command to `LULL_DEBUG_STATE`.
@MainActor
final class DebugBridge {
    private let model: AppModel
    private let statusItem: StatusItemController
    private let statePath: String
    private var token: NSObjectProtocol?
    private var timer: Timer?

    init(model: AppModel, statusItem: StatusItemController) {
        self.model = model
        self.statusItem = statusItem
        statePath = ProcessInfo.processInfo.environment["LULL_DEBUG_STATE"]
            ?? NSTemporaryDirectory() + "lull-debug-state.json"
        token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.markoderic.lull.debug"), object: nil, queue: .main
        ) { [weak self] notification in
            let command = notification.object as? String ?? ""
            MainActor.assumeIsolated { self?.run(command) }
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        writeState()
    }

    private func run(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "import": model.add(urls: [URL(fileURLWithPath: argument)])
        case "select":
            if let index = Int(argument), model.wallpapers.indices.contains(index) {
                model.select(model.wallpapers[index].id)
            }
        case "mode": model.setMode(argument == "still" ? .still : .animated)
        case "scrub": model.setStillFrame(Int(argument) ?? 0, commit: false)
        case "frame": model.setStillFrame(Int(argument) ?? 0, commit: true)
        case "smooth": model.setSmoothMotion(argument == "on")
        case "rate": model.setSmoothRate(Int(argument) ?? 120)
        case "limit": model.setFrameLimit(Int(argument))
        case "fit": model.setFitToScreen(argument == "on")
        case "rule": model.setPauseRule(argument == "visible" ? .wheneverVisible : .desktopFocus)
        case "panel":
            if argument == "open" { statusItem.open() } else { statusItem.close() }
        case "delete":
            if let index = Int(argument), model.wallpapers.indices.contains(index) {
                model.delete(model.wallpapers[index].id)
            }
        case "cancel":
            if let pending = model.pendingImports.first { model.cancelImport(pending.id) }
            else if let id = model.currentID { model.cancelVersion(id) }
        case "batch":
            // Runs commands back to back with no gap, to reach races a person could hit by chance.
            argument.split(separator: ";").forEach { run($0.trimmingCharacters(in: .whitespaces)) }
        case "engine": model.engine.setPlayback(desktop: argument == "on", preview: false)
        case "snapshot": snapshot(to: argument)
        case "appearance":
            NSApp.appearance = NSAppearance(named: argument == "dark" ? .darkAqua : .aqua)
        case "login":
            model.setLaunchAtLogin(argument == "on")
        case "quit": NSApp.terminate(nil)
        default: break
        }
        writeState()
    }

    /// Renders the panel's layers over a background matching the popover. Video layers can't be
    /// captured this way, so the preview only shows up for still wallpapers.
    private func snapshot(to path: String) {
        guard let view = statusItem.panelView, let layer = view.layer else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        var background = NSColor.windowBackgroundColor.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.cgColor
        }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        // Layers render top down, and bitmap contexts are bottom up.
        context.translateBy(x: 0, y: view.bounds.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func writeState() {
        let current = model.current
        let state: [String: Any] = [
            "wallpaperCount": model.wallpapers.count,
            "pendingImports": model.pendingImports.count,
            "currentName": current?.name ?? "",
            "mode": current?.mode.rawValue ?? "",
            "stillFrame": current?.stillFrame ?? -1,
            "frameCount": current?.frameCount ?? 0,
            "smoothMotion": current?.smoothMotion ?? false,
            "smoothRate": current?.smoothRate ?? 0,
            "frameLimit": current?.frameLimit ?? 0,
            "playbackFile": current?.playbackFilename ?? "",
            "sourceFPS": current?.sourceFPS ?? 0,
            "width": current?.width ?? 0,
            "height": current?.height ?? 0,
            "versionWorking": !model.versionProgress.isEmpty,
            "missing": model.missingIDs.count,
            "message": model.message ?? "",
            "status": model.statusText,
            "panelOpen": statusItem.isOpen,
            "rule": model.pauseRule.rawValue,
            "finderFront": model.inputs.finderIsFrontmost,
            "desktopOpen": model.inputs.desktopIsOpen,
            "engineWantsPlaying": model.engine.wantsPlaying,
            "enginePlayerLoaded": model.engine.isPlayerLoaded,
            "previewReady": model.engine.debugPreviewReady,
            "desktopMoving": model.engine.debugDesktopMoving,
            "fitNote": model.fitNote ?? "",
            "fitOn": current?.fitSize != nil,
            "canFit": model.canFitCurrent,
            "bestSize": model.bestSizeText ?? "",
            "engineStillVisible": model.engine.debugStillVisible,
            "launchAtLogin": model.launchAtLogin,
            "enginePlayerRate": model.engine.playerRate,
            "engineTime": model.engine.currentTime,
            "engineWindows": model.engine.windowCount,
            "displayMaxFPS": model.displayMaxFPS,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }
}

extension WallpaperEngine {
    var windowCount: Int { debugWindowCount }
    var isPlayerLoaded: Bool { debugPlayerRate != nil }
    var playerRate: Float { debugPlayerRate ?? -1 }
}
#endif
