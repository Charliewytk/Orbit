import Foundation

/// Free time on one day.
public struct DayFreeSlots: Codable, Hashable, Sendable {
    /// Local midnight.
    public var day: Date
    public var slots: [DateInterval]
    /// False on rest days.
    public var isWorkDay: Bool

    public init(day: Date, slots: [DateInterval], isWorkDay: Bool = true) {
        self.day = day; self.slots = slots; self.isWorkDay = isWorkDay
    }

    public var totalMinutes: Int { slots.reduce(0) { $0 + IntervalMath.minutes($1) } }
}

/// Finds free working time between your fixed commitments.
///
/// Working hours each day run from `dayStart` to the earlier of `dayEnd` and
/// `workCutoff`. Lunch and dinner are removed, busy timed events are removed
/// along with `bufferMinutes` either side, and rest days have no free time.
/// All-day events (deadlines, birthdays, "working from home") never block.
public struct FreeSlotFinder: Sendable {
    public var prefs: UserPrefs
    public var calendar: DayCalendar
    /// Slots shorter than this are dropped.
    public var minimumSlotMinutes: Int

    public init(prefs: UserPrefs, minimumSlotMinutes: Int = 15) {
        self.prefs = prefs
        self.calendar = DayCalendar(timeZone: prefs.timeZone)
        self.minimumSlotMinutes = minimumSlotMinutes
    }

    public func isRestDay(_ day: Date) -> Bool { prefs.restDays.contains(calendar.weekday(day)) }

    /// Working hours for the day containing `day`, or nil on a rest day.
    public func workingWindow(for day: Date) -> DateInterval? {
        guard !isRestDay(day) else { return nil }
        let start = calendar.date(minute: prefs.dayStart, of: day)
        let end = calendar.date(minute: min(prefs.dayEnd, prefs.workCutoff), of: day)
        return end > start ? DateInterval(start: start, end: end) : nil
    }

    /// Meal breaks on the day containing `day`.
    public func meals(on day: Date) -> [DateInterval] {
        [prefs.lunch, prefs.dinner].compactMap { r in
            guard let r else { return nil }
            let s = calendar.date(minute: r.lowerBound, of: day), e = calendar.date(minute: r.upperBound, of: day)
            return e > s ? DateInterval(start: s, end: e) : nil
        }
    }

    /// Busy time from events and extra blocked intervals, padded by the buffer and merged.
    public func busyIntervals(events: [CalendarEvent], blocked: [DateInterval] = []) -> [DateInterval] {
        let pad = TimeInterval(prefs.bufferMinutes * 60)
        let fromEvents = events
            .filter { $0.isBusy && !$0.isAllDay && $0.end > $0.start }
            .map { DateInterval(start: $0.start.addingTimeInterval(-pad), end: $0.end.addingTimeInterval(pad)) }
        let fromBlocked = blocked.filter { $0.duration > 0 }
            .map { DateInterval(start: $0.start.addingTimeInterval(-pad), end: $0.end.addingTimeInterval(pad)) }
        return IntervalMath.merge(fromEvents + fromBlocked)
    }

    /// Free slots per day for every day overlapping [start, end), clipped to that range.
    /// Slot starts are rounded up to 5 minutes.
    public func freeSlots(from start: Date, to end: Date, events: [CalendarEvent],
                          blocked: [DateInterval] = []) -> [DayFreeSlots] {
        guard end > start else { return [] }
        let busy = busyIntervals(events: events, blocked: blocked)
        return calendar.dayStarts(from: start, to: end).map { day in
            guard let window = workingWindow(for: day) else {
                return DayFreeSlots(day: day, slots: [], isWorkDay: false)
            }
            let s = max(window.start, start), e = min(window.end, end)
            guard e > s else { return DayFreeSlots(day: day, slots: []) }
            let free = IntervalMath.subtract([DateInterval(start: s, end: e)], busy + meals(on: day))
            let slots = free.compactMap { i -> DateInterval? in
                let a = IntervalMath.roundUp5(i.start)
                guard i.end > a else { return nil }
                let slot = DateInterval(start: a, end: i.end)
                return IntervalMath.minutes(slot) >= minimumSlotMinutes ? slot : nil
            }
            return DayFreeSlots(day: day, slots: slots)
        }
    }

    /// Free slots on the single day containing `day`.
    public func freeSlots(on day: Date, events: [CalendarEvent], blocked: [DateInterval] = []) -> [DateInterval] {
        let start = calendar.startOfDay(day)
        return freeSlots(from: start, to: calendar.endOfDay(start), events: events, blocked: blocked).first?.slots ?? []
    }
}
