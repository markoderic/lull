import Foundation

/// A time of day, independent of any date.
public struct ClockTime: Codable, Equatable, Hashable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    var totalMinutes: Int { hour * 60 + minute }

    var components: DateComponents {
        DateComponents(hour: hour, minute: minute, second: 0)
    }
}

public enum ScheduleSlot: String, Codable, Sendable {
    case day
    case night
}

/// Swaps between two wallpapers at chosen times. Pure logic: the clock and calendar are passed in.
public struct DaySchedule: Codable, Equatable, Sendable {
    public var isOn: Bool
    public var dayWallpaperID: UUID?
    public var nightWallpaperID: UUID?
    public var dayStart: ClockTime
    public var nightStart: ClockTime
    /// The latest scheduled change already acted on. A wallpaper picked by hand stays until a
    /// change newer than this comes along, including across a relaunch.
    public var lastAppliedChange: Date?

    public init(
        isOn: Bool = false,
        dayWallpaperID: UUID? = nil,
        nightWallpaperID: UUID? = nil,
        dayStart: ClockTime = ClockTime(hour: 7, minute: 0),
        nightStart: ClockTime = ClockTime(hour: 19, minute: 0),
        lastAppliedChange: Date? = nil
    ) {
        self.isOn = isOn
        self.dayWallpaperID = dayWallpaperID
        self.nightWallpaperID = nightWallpaperID
        self.dayStart = dayStart
        self.nightStart = nightStart
        self.lastAppliedChange = lastAppliedChange
    }

    public var isActive: Bool {
        isOn && dayWallpaperID != nil && nightWallpaperID != nil && dayStart != nightStart
    }

    public func wallpaperID(for slot: ScheduleSlot) -> UUID? {
        slot == .day ? dayWallpaperID : nightWallpaperID
    }

    public func slot(at date: Date, calendar: Calendar) -> ScheduleSlot {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let day = dayStart.totalMinutes, night = nightStart.totalMinutes
        // Day can wrap past midnight, for someone who works nights.
        let isDay = day <= night ? (now >= day && now < night) : (now >= day || now < night)
        return isDay ? .day : .night
    }

    public func nextChange(after date: Date, calendar: Calendar) -> Date? {
        guard dayStart != nightStart else { return nil }
        return [dayStart, nightStart]
            .compactMap { occurrence(of: $0, after: date, calendar: calendar, direction: .forward) }
            .min()
    }

    public func mostRecentChange(atOrBefore date: Date, calendar: Calendar) -> Date? {
        guard dayStart != nightStart else { return nil }
        // The search excludes its starting moment, so start just past it to include a change right now.
        return [dayStart, nightStart]
            .compactMap { occurrence(of: $0, after: date.addingTimeInterval(1), calendar: calendar, direction: .backward) }
            .max()
    }

    private func occurrence(of time: ClockTime, after date: Date, calendar: Calendar, direction: Calendar.SearchDirection) -> Date? {
        // When clocks go forward, a skipped time lands on the next valid one. When they go back, a
        // repeated time only counts once.
        calendar.nextDate(
            after: date,
            matching: time.components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: direction
        )
    }

    /// Whether a scheduled change has passed that hasn't been acted on yet. Comparing changes rather
    /// than slots means a Mac asleep through both changes still catches up.
    public func shouldApply(now: Date, calendar: Calendar) -> Bool {
        guard isActive else { return false }
        guard let lastAppliedChange else { return true }
        guard let recent = mostRecentChange(atOrBefore: now, calendar: calendar) else { return false }
        return recent > lastAppliedChange
    }

    /// One line for the panel, saying what happens next.
    public func caption(now: Date, calendar: Calendar, locale: Locale) -> String? {
        guard isOn else { return nil }
        if dayStart == nightStart { return "Day and Night need different times." }
        guard isActive, let next = nextChange(after: now, calendar: calendar) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let upcoming = slot(at: now, calendar: calendar) == .day ? "Night" : "Day"
        return "Changes to \(upcoming) at \(formatter.string(from: next))."
    }

    /// Forgets a deleted wallpaper. Returns whether that just turned the schedule off, which is
    /// worth telling the person about.
    public mutating func removeWallpaper(_ id: UUID) -> Bool {
        var wasUsed = false
        if dayWallpaperID == id {
            dayWallpaperID = nil
            wasUsed = true
        }
        if nightWallpaperID == id {
            nightWallpaperID = nil
            wasUsed = true
        }
        guard wasUsed, isOn else { return false }
        isOn = false
        return true
    }
}
