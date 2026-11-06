import CoreGraphics
import Foundation

/// One on-screen window, as reported by the window server.
public struct WindowSnapshot: Equatable, Sendable {
    public var ownerPID: Int32
    public var layer: Int
    public var alpha: Double
    public var bounds: CGRect

    public init(ownerPID: Int32, layer: Int, alpha: Double, bounds: CGRect) {
        self.ownerPID = ownerPID
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
    }
}

/// Works out whether any of the desktop can be seen.
///
/// `NSWindow.occlusionState` isn't used: in testing it reported a fully covered window as visible
/// while a screen capture service ran, and it never counts a maximized window as covering.
public enum Coverage {
    private static let columns = 64
    private static let rows = 40
    private static let minimumWindowSide: CGFloat = 100
    private static let opaqueAlpha = 0.99

    /// `screens` are usable areas in top-left coordinates, so the Dock and menu bar strips don't count.
    public static func desktopIsOpen(windows: [WindowSnapshot], screens: [CGRect], excludingPID: Int32) -> Bool {
        guard !screens.isEmpty else { return true }
        let covering = windows
            .filter { window in
                // Layer 0 only: macOS's WindowManager puts a screen-sized window on layer 18 for
                // a moment when the wallpaper is clicked.
                window.ownerPID != excludingPID
                    && window.layer == 0
                    && window.alpha >= opaqueAlpha
                    && window.bounds.width >= minimumWindowSide
                    && window.bounds.height >= minimumWindowSide
            }
            .map(\.bounds)
        return screens.contains { hasOpenArea($0, covering: covering) }
    }

    private static func hasOpenArea(_ screen: CGRect, covering: [CGRect]) -> Bool {
        for row in 0..<rows {
            let y = screen.minY + (CGFloat(row) + 0.5) * screen.height / CGFloat(rows)
            for column in 0..<columns {
                let x = screen.minX + (CGFloat(column) + 0.5) * screen.width / CGFloat(columns)
                let point = CGPoint(x: x, y: y)
                if !covering.contains(where: { $0.contains(point) }) { return true }
            }
        }
        return false
    }

    /// Reads the current on-screen windows. `nil` means the window server gave no answer.
    public static func captureWindows() -> [WindowSnapshot]? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        return windows(from: list)
    }

    static func windows(from list: [[String: Any]]) -> [WindowSnapshot] {
        list.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsEntry = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsEntry) else { return nil }
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
            return WindowSnapshot(ownerPID: pid, layer: layer, alpha: alpha, bounds: bounds)
        }
    }

    /// Converts an AppKit (bottom-left origin) frame to window server (top-left origin) coordinates.
    public static func topLeftRect(from frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryScreenHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
