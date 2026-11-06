// Helper for scripts/e2e/run.py: sends commands to the debug app and creates real desktop conditions.
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { exit(2) }

switch command {
case "send":
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.markoderic.lull.debug"),
        object: arguments.dropFirst().joined(separator: " "),
        userInfo: nil,
        deliverImmediately: true
    )
    // Let the notification leave before exiting.
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))

case "hide-apps":
    let visible = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && !$0.isHidden && $0.bundleIdentifier != "com.apple.finder"
    }
    let pids = visible.map { String($0.processIdentifier) }.joined(separator: "\n")
    try pids.write(toFile: arguments[1], atomically: true, encoding: .utf8)
    visible.forEach { _ = $0.hide() }
    RunLoop.current.run(until: Date().addingTimeInterval(1))

case "show-apps":
    let text = (try? String(contentsOfFile: arguments[1], encoding: .utf8)) ?? ""
    for pid in text.split(separator: "\n").compactMap({ Int32($0) }) {
        _ = NSRunningApplication(processIdentifier: pid)?.unhide()
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))

case "activate":
    NSRunningApplication.runningApplications(withBundleIdentifier: arguments[1]).first?.activate()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))

case "front":
    print(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")

case "windows":
    let pid = Int32(arguments[1]) ?? 0
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in list where (window[kCGWindowOwnerPID as String] as? Int32) == pid {
        let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
        print("layer=\(window[kCGWindowLayer as String] as? Int ?? 0) size=\(Int(bounds["Width"] ?? 0))x\(Int(bounds["Height"] ?? 0))")
    }

case "level":
    print("desktop=\(CGWindowLevelForKey(.desktopWindow)) icons=\(CGWindowLevelForKey(.desktopIconWindow))")

case "cover":
    // cover <full|maximized|partial|translucent|focus|fullscreen> <seconds>
    let mode = arguments[1]
    let seconds = Double(arguments[2]) ?? 3
    let app = NSApplication.shared
    let screen = NSScreen.main!
    let takesFocus = mode == "focus" || mode == "fullscreen"
    app.setActivationPolicy(takesFocus ? .regular : .accessory)

    let window: NSWindow
    if takesFocus {
        window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 400, height: 240),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.title = "Lull test window"
        window.collectionBehavior = [.fullScreenPrimary]
    } else {
        var frame = screen.frame
        if mode == "maximized" { frame = screen.visibleFrame }
        if mode == "partial" { frame = screen.frame.insetBy(dx: 200, dy: 200) }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        if mode == "translucent" {
            panel.isOpaque = false
            panel.backgroundColor = NSColor(white: 0.25, alpha: 0.6)
        } else {
            panel.isOpaque = true
            panel.backgroundColor = NSColor(white: 0.25, alpha: 1)
        }
        window = panel
    }
    window.orderFrontRegardless()
    if takesFocus {
        app.activate()
        window.makeKeyAndOrderFront(nil)
    }
    if mode == "fullscreen" {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { window.toggleFullScreen(nil) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        if mode == "fullscreen" {
            window.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
        } else {
            exit(0)
        }
    }
    app.run()

default:
    exit(2)
}
