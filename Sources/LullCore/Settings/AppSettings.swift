import Foundation

/// App-wide choices. Each wallpaper's own settings live in its `info.json`.
public final class AppSettings: @unchecked Sendable {
    private enum Key {
        static let pauseRule = "pauseRule"
        static let currentWallpaperID = "currentWallpaperID"
        static let daySchedule = "daySchedule"
        static let hasBeenWelcomed = "hasBeenWelcomed"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var pauseRule: PauseRuleMode {
        get { defaults.string(forKey: Key.pauseRule).flatMap(PauseRuleMode.init(rawValue:)) ?? .desktopFocus }
        set { defaults.set(newValue.rawValue, forKey: Key.pauseRule) }
    }

    public var hasBeenWelcomed: Bool {
        get { defaults.bool(forKey: Key.hasBeenWelcomed) }
        set { defaults.set(newValue, forKey: Key.hasBeenWelcomed) }
    }

    public var daySchedule: DaySchedule {
        get {
            guard let data = defaults.data(forKey: Key.daySchedule),
                  let schedule = try? JSONDecoder().decode(DaySchedule.self, from: data) else { return DaySchedule() }
            return schedule
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.daySchedule) }
    }

    public var currentWallpaperID: UUID? {
        get { defaults.string(forKey: Key.currentWallpaperID).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Key.currentWallpaperID) }
    }
}
