import Darwin
import Foundation

/// Getting someone settled in on first launch, including people who open the app straight from the
/// installer without dragging it anywhere.
public enum AppLocation {
    /// Someone running from the installer loses the app when it closes. macOS runs some quarantined
    /// apps from a temporary "translocated" copy, which has the same problem.
    public static func shouldOfferMove(bundlePath: String) -> Bool {
        bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/")
    }

    /// The installer's mounted volume, so it can be put away after the move.
    public static func volumeRoot(of bundlePath: String) -> String? {
        let parts = bundlePath.split(separator: "/")
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/\(parts[1])"
    }

    /// The panel opens by itself once, because a menu bar app otherwise shows nothing when opened,
    /// which looks like it didn't work.
    public static func shouldWelcome(hasBeenWelcomed: Bool, wallpaperCount: Int) -> Bool {
        !hasBeenWelcomed && wallpaperCount == 0
    }

    /// Copies the app into a folder, replacing any older copy, and returns where it ended up.
    public static func install(
        bundleAt source: URL,
        into folder: URL,
        moveExistingToTrash: (URL) throws -> Void
    ) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try moveExistingToTrash(destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        // They've already approved this app by opening it, so the copy shouldn't ask them again.
        removexattr(destination.path, "com.apple.quarantine", 0)
        return destination
    }
}
