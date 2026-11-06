import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The one menu bar icon, and the panel it opens. The panel's views exist only while it's open.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: AppModel
    private var popover: NSPopover?

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
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hosting
        popover.delegate = self
        // Left alone, it inherits from the menu bar, whose look depends on the real wallpaper.
        popover.appearance = NSApp.effectiveAppearance
        self.popover = popover
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if !popover.isShown {
            discardPopover()
            model.panelDidClose()
        }
    }

    private func discardPopover() {
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
        popover?.behavior = .applicationDefined
        let response = panel.runModal()
        popover?.behavior = .transient
        if response == .OK { model.add(urls: panel.urls) }
    }

    #if DEBUG
    /// The panel's window, so end-to-end checks can capture what it looks like.
    var panelView: NSView? { popover?.contentViewController?.view }
    #endif
}
