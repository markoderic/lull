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
        let model = makeModel()
        model.start()
        self.model = model
        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem
        #if DEBUG
        debugBridge = DebugBridge(model: model, statusItem: statusItem)
        #endif
    }

    private func anotherCopyIsRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    private func makeModel() -> AppModel {
        #if DEBUG
        // End-to-end checks run against a throwaway library, never the real one.
        let environment = ProcessInfo.processInfo.environment
        if let root = environment["LULL_DEBUG_ROOT"] {
            let defaults = UserDefaults(suiteName: environment["LULL_DEBUG_DEFAULTS"] ?? "lull-debug") ?? .standard
            let store = WallpaperStore(root: URL(fileURLWithPath: root), moveToTrash: { url in
                try FileManager.default.removeItem(at: url)
            })
            return AppModel(store: store, settings: AppSettings(defaults: defaults))
        }
        #endif
        return AppModel()
    }
}
