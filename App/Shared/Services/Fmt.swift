import Foundation
import OrbitCore

/// Formatting used across the app (UK style, 24-hour times).
enum Fmt {
    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m)m"
        case (_, 0): return "\(h)h"
        default: return "\(h)h \(m)m"
        }
    }

    /// "Today", "Tomorrow", "Yesterday" or "Mon 5 Oct".
    static func day(_ date: Date, _ cal: DayCalendar, now: Date = Date()) -> String {
        switch cal.days(from: now, to: date) {
        case 0: "Today"
        case 1: "Tomorrow"
        case -1: "Yesterday"
        case 2...6: cal.format(date, "EEEE")
        default: cal.shortDay(date)
        }
    }

    static func dayTime(_ date: Date, _ cal: DayCalendar, now: Date = Date()) -> String {
        "\(day(date, cal, now: now)) \(cal.time(date))"
    }

    static func range(_ start: Date, _ end: Date, _ cal: DayCalendar) -> String {
        "\(cal.time(start))–\(cal.time(end))"
    }

    /// "Due today 14:00", "Due tomorrow", "Due in 5 days", "Overdue by 2 days".
    static func due(_ date: Date, _ cal: DayCalendar, now: Date = Date()) -> String {
        let days = cal.days(from: now, to: date)
        if date < now {
            return days == 0 ? "Overdue (was \(cal.time(date)))" : "Overdue by \(-days) day\(days == -1 ? "" : "s")"
        }
        switch days {
        case 0: return "Due today \(cal.time(date))"
        case 1: return "Due tomorrow \(cal.time(date))"
        case 2...6: return "Due \(cal.format(date, "EEEE"))"
        default: return "Due in \(days) days"
        }
    }

    static func minuteOfDay(_ m: MinuteOfDay) -> String { String(format: "%02d:%02d", (m / 60) % 24, m % 60) }

    static func greeting(_ name: String, now: Date = Date(), cal: DayCalendar) -> String {
        let hour = cal.minuteOfDay(now) / 60
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return name.isEmpty ? part : "\(part), \(name)"
    }
}
