import Foundation

/// Day-level calendar maths in the user's time zone. All wall-clock
/// conversions go through `Calendar`, so days are 23 or 25 hours long on
/// DST change days and 09:00 stays 09:00. Weeks start on Monday (UK).
public struct DayCalendar: Sendable {
    public let calendar: Calendar

    public init(timeZone: TimeZone = TimeZone(identifier: "Europe/London")!) {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: "en_GB")
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        calendar = c
    }

    public init(prefs: UserPrefs) { self.init(timeZone: prefs.timeZone) }

    public var timeZone: TimeZone { calendar.timeZone }

    public func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    /// Same wall-clock time `n` calendar days later (DST-safe).
    public func addingDays(_ n: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: n, to: date) ?? date.addingTimeInterval(Double(n) * 86400)
    }

    /// The start of the next day.
    public func endOfDay(_ date: Date) -> Date { addingDays(1, to: startOfDay(date)) }

    /// The instant at `minute` past local midnight on `day`. 1440 means the next midnight.
    public func date(minute: MinuteOfDay, of day: Date) -> Date {
        let start = startOfDay(day)
        if minute >= 24 * 60 { return addingDays(1, to: start) }
        let m = max(0, minute)
        return calendar.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: start)
            ?? start.addingTimeInterval(Double(m) * 60)
    }

    public func minuteOfDay(_ date: Date) -> MinuteOfDay {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// 1 = Sunday … 7 = Saturday (same numbering as `UserPrefs.restDays`).
    public func weekday(_ date: Date) -> Int { calendar.component(.weekday, from: date) }

    public func isSameDay(_ a: Date, _ b: Date) -> Bool { calendar.isDate(a, inSameDayAs: b) }

    /// Whole calendar days from `a`'s day to `b`'s day (negative if `b` is earlier).
    public func days(from a: Date, to b: Date) -> Int {
        calendar.dateComponents([.day], from: startOfDay(a), to: startOfDay(b)).day ?? 0
    }

    /// Local midnights of each day overlapping [start, end).
    public func dayStarts(from start: Date, to end: Date) -> [Date] {
        var out: [Date] = []
        var d = startOfDay(start)
        while d < end {
            out.append(d)
            d = addingDays(1, to: d)
        }
        return out
    }

    /// Monday 00:00 of the week containing `date`.
    public func startOfWeek(_ date: Date) -> Date {
        let sinceMonday = (weekday(date) + 5) % 7
        return addingDays(-sinceMonday, to: startOfDay(date))
    }

    public func date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date? {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
        c.timeZone = timeZone
        guard let d = calendar.date(from: c) else { return nil }
        // Reject overflowed dates such as 31 February.
        let back = calendar.dateComponents([.year, .month, .day], from: d)
        return back.year == year && back.month == month && back.day == day ? d : nil
    }

    /// "Mon 5 Oct" style label used in warnings.
    public func shortDay(_ date: Date) -> String { format(date, "EEE d MMM") }

    /// "14:30".
    public func time(_ date: Date) -> String { format(date, "HH:mm") }

    public func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

/// Helpers for lists of `DateInterval`s.
enum IntervalMath {
    /// Sorts and merges overlapping or touching intervals.
    static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        var out: [DateInterval] = []
        for i in sorted {
            if let last = out.last, i.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, i.end))
            } else {
                out.append(i)
            }
        }
        return out
    }

    /// `base` minus every interval in `cuts`.
    static func subtract(_ base: [DateInterval], _ cuts: [DateInterval]) -> [DateInterval] {
        let cuts = merge(cuts)
        var out: [DateInterval] = []
        for b in base {
            var pieces = [b]
            for c in cuts where c.end > b.start && c.start < b.end {
                pieces = pieces.flatMap { p -> [DateInterval] in
                    guard c.end > p.start && c.start < p.end else { return [p] }
                    var r: [DateInterval] = []
                    if c.start > p.start { r.append(DateInterval(start: p.start, end: c.start)) }
                    if c.end < p.end { r.append(DateInterval(start: c.end, end: p.end)) }
                    return r
                }
            }
            out += pieces
        }
        return out.sorted { $0.start < $1.start }
    }

    static func minutes(_ i: DateInterval) -> Int { Int((i.duration / 60).rounded(.down)) }

    /// Rounds up to the next 5-minute boundary (local and UTC agree for UK offsets).
    static func roundUp5(_ d: Date) -> Date {
        let t = d.timeIntervalSince1970
        return Date(timeIntervalSince1970: (t / 300).rounded(.up) * 300)
    }

    static func roundDown5(_ minutes: Int) -> Int { minutes - ((minutes % 5) + 5) % 5 }
    static func roundUp5(_ minutes: Int) -> Int { minutes <= 0 ? 0 : ((minutes + 4) / 5) * 5 }
}
