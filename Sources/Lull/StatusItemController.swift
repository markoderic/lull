import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The one menu bar icon, and the panel it opens. The panel's views exist only while it's open.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: AppModel
    private var popover: NSPopover?
    private var leaveMonitors: [Any] = []
    private var activationObserver: NSObjectProtocol?
    private var dragCountAtMouseDown = 0
    private var isChoosingFiles = false

    init(model: AppModel) {
        self.model = model
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Lull")
            button.target = self
            button.action = #selector(toggle)
        }
    }

    var isOpen: Bool { popover?.isShown == true }

    @objc func toggle() {
        if isOpen {
            close()
        } else {
            open()
        }
    }

    func open() {
        guard !isOpen, let button = statusItem.button, button.window != nil else { return }
        // A popover that failed to show never reports closing, so it mustn't block the next attempt.
        discardPopover()
        model.panelDidOpen()
        let hosting = NSHostingController(rootView: PanelView(model: model, onAdd: { [weak self] in self?.chooseFiles() }))
        hosting.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        // Closing is handled here instead of with `.transient`, which closes the moment another app
        // is clicked. That would make it impossible to drag a file in from Finder.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentViewController = hosting
        popover.delegate = self
        // Left alone, it inherits from the menu bar, whose look depends on the real wallpaper.
        popover.appearance = NSApp.effectiveAppearance
        self.popover = popover
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if popover.isShown {
            startWatchingForLeaving()
        } else {
            discardPopover()
            model.panelDidClose()
        }
    }

    /// The panel closes when the person goes elsewhere: a click outside that isn't the start of a
    /// drag, switching apps, or pressing Escape.
    private func startWatchingForLeaving() {
        stopWatchingForLeaving()
        dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSPasteboard(name: .drag).changeCount == self.dragCountAtMouseDown else { return }
                self.closeUnlessChoosingFiles()
            }
        }
        let other = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeUnlessChoosingFiles() }
        }
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEscape = event.keyCode == 53
            if isEscape { MainActor.assumeIsolated { self?.closeUnlessChoosingFiles() } }
            return isEscape ? nil : event
        }
        leaveMonitors = [down, up, other, escape].compactMap { $0 }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // A held mouse button means a click or drag in progress, which the mouse-up settles.
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  NSEvent.pressedMouseButtons == 0 else { return }
            MainActor.assumeIsolated { self?.closeUnlessChoosingFiles() }
        }
    }

    private func stopWatchingForLeaving() {
        leaveMonitors.forEach(NSEvent.removeMonitor)
        leaveMonitors = []
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private func closeUnlessChoosingFiles() {
        if !isChoosingFiles { close() }
    }

    private func discardPopover() {
        stopWatchingForLeaving()
        popover?.delegate = nil
        // Releasing the content frees the panel's views and thumbnails.
        popover?.contentViewController = nil
        popover = nil
    }

    func close() {
        popover?.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        discardPopover()
        model.panelDidClose()
        // Hand focus back to whatever was in front before the panel opened. The wallpaper windows
        // can't hide, so this doesn't touch them.
        if NSApp.isActive { NSApp.hide(nil) }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif, .mpeg4Movie, .quickTimeMovie, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        // Keeps the panel open behind the file picker.
        isChoosingFiles = true
        let response = panel.runModal()
        isChoosingFiles = false
        if response == .OK { model.add(urls: panel.urls) }
    }

    #if DEBUG
    /// The panel's window, so end-to-end checks can capture what it looks like.
    var panelView: NSView? { popover?.contentViewController?.view }
    #endif
}
