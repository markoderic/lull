import Foundation

/// App-wide choices. Each wallpaper's own settings live in its `info.json`.
public final class AppSettings: @unchecked Sendable {
    private enum Key {
        static let pauseRule = "pauseRule"
        static let currentWallpaperID = "currentWallpaperID"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var pauseRule: PauseRuleMode {
        get { defaults.string(forKey: Key.pauseRule).flatMap(PauseRuleMode.init(rawValue:)) ?? .desktopFocus }
        set { defaults.set(newValue.rawValue, forKey: Key.pauseRule) }
    }

    public var currentWallpaperID: UUID? {
        get { defaults.string(forKey: Key.currentWallpaperID).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Key.currentWallpaperID) }
    }
}
