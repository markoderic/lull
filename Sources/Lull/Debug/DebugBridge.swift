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
        case "snapshot": snapshot(to: argument)
        case "quit": NSApp.terminate(nil)
        default: break
        }
        writeState()
    }

    private func snapshot(to path: String) {
        guard let view = statusItem.panelView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        try? representation.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
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
