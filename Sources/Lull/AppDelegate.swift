import AppKit
import LullCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?
    #if DEBUG
    private var debugBridge: DebugBridge?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !anotherCopyIsRunning() else {
            NSApp.terminate(nil)
            return
        }
        if offerToMoveToApplications() { return }

        let settings = makeSettings()
        let model = AppModel(store: makeStore(), settings: settings)
        model.start()
        self.model = model
        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem
        #if DEBUG
        debugBridge = DebugBridge(model: model, statusItem: statusItem)
        #endif
        welcomeIfNeeded(settings: settings, wallpaperCount: model.wallpapers.count)
    }

    /// Opening the app again, say from Applications, is someone looking for it. Show them.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.open()
        return false
    }

    private func welcomeIfNeeded(settings: AppSettings, wallpaperCount: Int) {
        #if DEBUG
        // End-to-end checks ask for this explicitly, so it doesn't get in the way of the others.
        let environment = ProcessInfo.processInfo.environment
        if environment["LULL_DEBUG_ROOT"] != nil, environment["LULL_DEBUG_WELCOME"] == nil { return }
        #endif
        guard AppLocation.shouldWelcome(hasBeenWelcomed: settings.hasBeenWelcomed, wallpaperCount: wallpaperCount) else { return }
        settings.hasBeenWelcomed = true
        // The menu bar icon takes a moment to appear, and the panel opens from it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.statusItem?.open() }
        }
    }

    /// Returns whether the app is quitting because it's moved.
    private func offerToMoveToApplications() -> Bool {
        let bundlePath = Bundle.main.bundlePath
        guard AppLocation.shouldOfferMove(bundlePath: bundlePath) else { return false }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move Lull to your Applications folder?"
        alert.informativeText = "Lull is running from the installer, so it would stop working once that's closed."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let applications = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)[0]
        do {
            let installed = try AppLocation.install(
                bundleAt: Bundle.main.bundleURL,
                into: applications,
                moveExistingToTrash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
            )
            relaunch(installed, ejecting: AppLocation.volumeRoot(of: bundlePath))
            return true
        } catch {
            let failure = NSAlert()
            failure.messageText = "Lull couldn't move itself."
            failure.informativeText = "Drag Lull to your Applications folder in the installer window, then open it from there."
            failure.runModal()
            return false
        }
    }

    /// Quits, then opens the installed copy and puts the installer away once this copy has gone.
    private func relaunch(_ app: URL, ejecting volume: String?) {
        let script = #"sleep 0.6; [ -n "$1" ] && hdiutil detach "$1" -quiet; open "$2""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", volume ?? "", app.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func anotherCopyIsRunning() -> Bool {
        #if DEBUG
        // End-to-end checks use their own library, so they can run beside a real copy.
        if ProcessInfo.processInfo.environment["LULL_DEBUG_ROOT"] != nil { return false }
        #endif
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    private func makeSettings() -> AppSettings {
        #if DEBUG
        // End-to-end checks run against a throwaway library, never the real one.
        let environment = ProcessInfo.processInfo.environment
        if environment["LULL_DEBUG_ROOT"] != nil {
            return AppSettings(defaults: UserDefaults(suiteName: environment["LULL_DEBUG_DEFAULTS"] ?? "lull-debug") ?? .standard)
        }
        #endif
        return AppSettings()
    }

    private func makeStore() -> WallpaperStore {
        #if DEBUG
        if let root = ProcessInfo.processInfo.environment["LULL_DEBUG_ROOT"] {
            return WallpaperStore(root: URL(fileURLWithPath: root), moveToTrash: { url in
                try FileManager.default.removeItem(at: url)
            })
        }
        #endif
        return WallpaperStore()
    }
}
