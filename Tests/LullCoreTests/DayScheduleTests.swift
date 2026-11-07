import Foundation
import Testing
@testable import LullCore

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    newYork.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// 7 AM to 7 PM is day, with both wallpapers chosen and the schedule on.
private func schedule(day: ClockTime = ClockTime(hour: 7, minute: 0), night: ClockTime = ClockTime(hour: 19, minute: 0)) -> DaySchedule {
    DaySchedule(isOn: true, dayWallpaperID: UUID(), nightWallpaperID: UUID(), dayStart: day, nightStart: night)
}

@Suite("Day and Night schedule")
struct DayScheduleTests {
    @Test(arguments: [
        (7, 0, ScheduleSlot.day), (12, 0, .day), (18, 59, .day),
        (19, 0, .night), (23, 30, .night), (0, 0, .night), (6, 59, .night),
    ] as [(Int, Int, ScheduleSlot)])
    func dayRunsFromItsStartToNightsStart(_ hour: Int, _ minute: Int, _ expected: ScheduleSlot) {
        #expect(schedule().slot(at: date(2026, 6, 10, hour, minute), calendar: newYork) == expected)
    }

    @Test(arguments: [
        (20, 0, ScheduleSlot.day), (23, 0, .day), (3, 0, .day),
        (6, 0, .night), (12, 0, .night), (19, 59, .night),
    ] as [(Int, Int, ScheduleSlot)])
    func dayCanRunOvernightForPeopleWhoWorkNights(_ hour: Int, _ minute: Int, _ expected: ScheduleSlot) {
        let nights = schedule(day: ClockTime(hour: 20, minute: 0), night: ClockTime(hour: 6, minute: 0))
        #expect(nights.slot(at: date(2026, 6, 10, hour, minute), calendar: newYork) == expected)
    }

    @Test func eachSlotUsesItsOwnWallpaper() {
        let plan = schedule()
        #expect(plan.wallpaperID(for: .day) == plan.dayWallpaperID)
        #expect(plan.wallpaperID(for: .night) == plan.nightWallpaperID)
    }

    @Test func theNextChangeIsLaterToday() {
        #expect(schedule().nextChange(after: date(2026, 6, 10, 8), calendar: newYork) == date(2026, 6, 10, 19))
    }

    @Test func theNextChangeCanBeTomorrow() {
        #expect(schedule().nextChange(after: date(2026, 6, 10, 20), calendar: newYork) == date(2026, 6, 11, 7))
    }

    @Test func aChangeHappeningNowDoesntCountAsTheNextOne() {
        #expect(schedule().nextChange(after: date(2026, 6, 10, 19), calendar: newYork) == date(2026, 6, 11, 7))
    }

    @Test func theMostRecentChangeIsEarlierToday() {
        #expect(schedule().mostRecentChange(atOrBefore: date(2026, 6, 10, 8), calendar: newYork) == date(2026, 6, 10, 7))
    }

    @Test func theMostRecentChangeCanBeYesterday() {
        #expect(schedule().mostRecentChange(atOrBefore: date(2026, 6, 10, 6), calendar: newYork) == date(2026, 6, 9, 19))
    }

    @Test func aChangeHappeningExactlyNowCounts() {
        #expect(schedule().mostRecentChange(atOrBefore: date(2026, 6, 10, 7), calendar: newYork) == date(2026, 6, 10, 7))
    }

    @Test func itAppliesTheFirstTime() {
        #expect(schedule().shouldApply(now: date(2026, 6, 10, 8), calendar: newYork))
    }

    @Test func itDoesntApplyTwiceForOneChange() {
        var plan = schedule()
        plan.lastAppliedChange = date(2026, 6, 10, 7)
        #expect(!plan.shouldApply(now: date(2026, 6, 10, 8), calendar: newYork))
    }

    @Test func itAppliesOnceTheNextChangeHasPassed() {
        var plan = schedule()
        plan.lastAppliedChange = date(2026, 6, 10, 7)
        #expect(plan.shouldApply(now: date(2026, 6, 10, 19), calendar: newYork))
    }

    @Test func aMacAsleepThroughTwoChangesCatchesUpEvenThoughTheSlotIsTheSame() {
        var plan = schedule()
        plan.lastAppliedChange = date(2026, 6, 10, 7)
        // Asleep from day through the whole night, waking during the next day.
        #expect(plan.shouldApply(now: date(2026, 6, 11, 8), calendar: newYork))
    }

    @Test func itNeedsToBeOn() {
        var plan = schedule()
        plan.isOn = false
        #expect(!plan.isActive)
        #expect(!plan.shouldApply(now: date(2026, 6, 10, 8), calendar: newYork))
    }

    @Test func itNeedsBothWallpapers() {
        var plan = schedule()
        plan.nightWallpaperID = nil
        #expect(!plan.isActive)
    }

    @Test func itNeedsTwoDifferentTimes() {
        let same = schedule(day: ClockTime(hour: 9, minute: 0), night: ClockTime(hour: 9, minute: 0))
        #expect(!same.isActive)
        #expect(same.nextChange(after: date(2026, 6, 10, 8), calendar: newYork) == nil)
    }

    @Test func clocksGoingForwardSkipATimeWithoutGettingStuck() {
        // 2:30 AM doesn't exist in New York on March 8, 2026.
        let plan = schedule(day: ClockTime(hour: 2, minute: 30), night: ClockTime(hour: 19, minute: 0))
        let next = plan.nextChange(after: date(2026, 3, 8, 1), calendar: newYork)
        #expect(next == date(2026, 3, 8, 3))
        #expect(plan.slot(at: date(2026, 3, 8, 3, 30), calendar: newYork) == .day)
    }

    @Test func clocksGoingBackDontChangeTwice() throws {
        // 1:30 AM happens twice in New York on November 1, 2026.
        let plan = schedule(day: ClockTime(hour: 1, minute: 30), night: ClockTime(hour: 19, minute: 0))
        let first = try #require(plan.nextChange(after: date(2026, 11, 1, 0), calendar: newYork))
        let following = try #require(plan.nextChange(after: first, calendar: newYork))
        #expect(following == date(2026, 11, 1, 19))
    }

    @Test func theCaptionSaysWhatChangesAndWhen() throws {
        let caption = try #require(schedule().caption(now: date(2026, 6, 10, 8), calendar: newYork, locale: Locale(identifier: "en_US")))
        #expect(caption.hasPrefix("Changes to Night at 7:00"))
        #expect(caption.hasSuffix("PM."))
    }

    @Test func theCaptionNamesDayDuringTheNight() throws {
        let caption = try #require(schedule().caption(now: date(2026, 6, 10, 20), calendar: newYork, locale: Locale(identifier: "en_US")))
        #expect(caption.hasPrefix("Changes to Day at 7:00"))
    }

    @Test func theCaptionExplainsMatchingTimes() {
        let same = schedule(day: ClockTime(hour: 9, minute: 0), night: ClockTime(hour: 9, minute: 0))
        #expect(same.caption(now: date(2026, 6, 10, 8), calendar: newYork, locale: Locale(identifier: "en_US")) == "Day and Night need different times.")
    }

    @Test func thereIsNoCaptionWhenItsOff() {
        var plan = schedule()
        plan.isOn = false
        #expect(plan.caption(now: date(2026, 6, 10, 8), calendar: newYork, locale: Locale(identifier: "en_US")) == nil)
    }

    @Test func removingAWallpaperTurnsTheScheduleOff() {
        var plan = schedule()
        let night = plan.nightWallpaperID!
        let turnedOff = plan.removeWallpaper(night)
        #expect(turnedOff)
        #expect(!plan.isOn)
        #expect(plan.nightWallpaperID == nil)
    }

    @Test func removingAnUnrelatedWallpaperChangesNothing() {
        var plan = schedule()
        let turnedOff = plan.removeWallpaper(UUID())
        #expect(!turnedOff)
        #expect(plan.isOn)
    }

    @Test func removingAWallpaperFromAnOffScheduleIsQuiet() {
        var plan = schedule()
        plan.isOn = false
        let day = plan.dayWallpaperID!
        let turnedOff = plan.removeWallpaper(day)
        #expect(!turnedOff)
        #expect(plan.dayWallpaperID == nil)
    }
}

@Suite("Saving the schedule")
struct DaySchedulePersistenceTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "lull-tests-\(UUID().uuidString)")!
    }

    @Test func itsOffByDefaultWithSensibleTimes() {
        let plan = AppSettings(defaults: defaults()).daySchedule
        #expect(!plan.isOn)
        #expect(plan.dayStart == ClockTime(hour: 7, minute: 0))
        #expect(plan.nightStart == ClockTime(hour: 19, minute: 0))
    }

    @Test func itSurvivesARestart() {
        let store = defaults()
        var plan = schedule()
        plan.lastAppliedChange = date(2026, 6, 10, 7)
        AppSettings(defaults: store).daySchedule = plan
        #expect(AppSettings(defaults: store).daySchedule == plan)
    }

    @Test func damagedSettingsFallBackToOff() {
        let store = defaults()
        store.set(Data("not json".utf8), forKey: "daySchedule")
        #expect(!AppSettings(defaults: store).daySchedule.isOn)
    }
}
