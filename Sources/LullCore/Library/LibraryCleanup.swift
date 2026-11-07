import Foundation

/// The words for cleaning up the library.
public enum LibraryCleanup {
    public static func summary(selected: Int, total: Int, selectedBytes: Int64, totalBytes: Int64) -> String {
        if selected == 0 {
            return "\(total) \(total == 1 ? "wallpaper" : "wallpapers"), \(format(totalBytes))"
        }
        return "\(selected) of \(total) selected, \(format(selectedBytes))"
    }

    public static func deleteTitle(selected: Int) -> String {
        selected == 0 ? "Delete" : "Delete \(selected)"
    }

    public static func movedMessage(count: Int) -> String {
        "Moved \(count) \(count == 1 ? "wallpaper" : "wallpapers") to the Trash."
    }

    public static func failedMessage(moved: Int, failed: Int) -> String {
        moved == 0
            ? "These wallpapers couldn't be moved to the Trash."
            : "Moved \(moved) to the Trash, but \(failed) couldn't be moved."
    }

    public static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        // Some systems put a non-breaking space before the unit.
        return formatter.string(fromByteCount: bytes).replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
