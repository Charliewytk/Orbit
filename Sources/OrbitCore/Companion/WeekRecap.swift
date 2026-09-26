import Foundation

/// Saturday and Sunday evening review: how the week went, next week's plan, what's slipping.
public struct WeekRecap: Codable, Hashable, Sendable {
    public struct PlanItem: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var date: Date
        public var moduleCode: String?
        public var kind: String
    }

    public var generatedAt: Date
    public var weekStart: Date
    public var tasksDone: Int
    public var tasksPlanned: Int
    public var studyMinutes: Int
    public var activeDays: Int
    public var marksReturned: [String]
    public var wins: [String]
    public var slipping: [String]
    public var nextWeek: [PlanItem]
    public var focusSuggestions: [String]

    public var completionRate: Double { tasksPlanned == 0 ? 1 : Double(tasksDone) / Double(tasksPlanned) }

    public var headline: String {
        switch (completionRate, slipping.count) {
        case (0.8..., 0): "Strong week. Nothing slipping."
        case (0.8..., _): "Good week, with \(slipping.count) thing\(slipping.count == 1 ? "" : "s") to catch."
        case (0.5..<0.8, _): "Steady week. Tighten up next week's plan."
        default: "Tough week. Reset with a lighter, focused plan."
        }
    }

    public func plainText() -> String {
        var lines = [headline,
                     "Done \(tasksDone)/\(tasksPlanned) to-dos, \(studyMinutes / 60)h \(studyMinutes % 60)m study over \(activeDays) active days."]
        if !marksReturned.isEmpty { lines.append("Marks back: " + marksReturned.joined(separator: "; ") + ".") }
        if !wins.isEmpty { lines.append("Wins: " + wins.joined(separator: "; ") + ".") }
        if !slipping.isEmpty { lines.append("Slipping: " + slipping.joined(separator: "; ") + ".") }
        if !nextWeek.isEmpty { lines.append("Next week: " + nextWeek.prefix(8).map(\.title).joined(separator: "; ") + ".") }
        if !focusSuggestions.isEmpty { lines.append("Focus: " + focusSuggestions.joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }
}

public struct WeekRecapSchedule: Codable, Hashable, Sendable {
    public var enabled: Bool
    /// Evening time on Saturday and Sunday.
    public var minute: MinuteOfDay
    public init(enabled: Bool = true, minute: MinuteOfDay = 19 * 60) { self.enabled = enabled; self.minute = minute }

    /// Saturday (7) and Sunday (1) evenings; once per day.
    public func isDue(now: Date, lastRun: Date?, calendar: DayCalendar) -> Bool {
        guard enabled, [1, 7].contains(calendar.weekday(now)), calendar.minuteOfDay(now) >= minute else { return false }
        return lastRun.map { !calendar.isSameDay($0, now) } ?? true
    }
}

public struct WeekRecapBuilder: Sendable {
    public var calendar: DayCalendar
    public init(calendar: DayCalendar = DayCalendar()) { self.calendar = calendar }

    /// `now` is Saturday or Sunday. The "week" is the last 7 days; next week is the following 7 days (weekends count).
    public func build(now: Date, tasks: [OrbitTask], assessments: [Assessment], events: [CalendarEvent],
                      days: [DayStats], moduleReview: WeeklyReview? = nil, groupDue: [String] = []) -> WeekRecap {
        let start = calendar.addingDays(-6, to: calendar.startOfDay(now))
        let end = calendar.endOfDay(now)
        let nextEnd = calendar.addingDays(8, to: calendar.startOfDay(now))
        let doneThisWeek = tasks.filter { t in t.completedAt.map { $0 >= start && $0 < end } ?? false }
        let dueThisWeek = tasks.filter { t in t.deadline.map { $0 >= start && $0 < end } ?? false }
        let planned = Set(doneThisWeek.map(\.id)).union(dueThisWeek.map(\.id)).count
        let overdue = tasks.filter { $0.completedAt == nil && ($0.deadline.map { $0 < now } ?? false) }
            .sorted { $0.deadline! < $1.deadline! }
        let dayKeys = Set(calendar.dayStarts(from: start, to: calendar.startOfDay(now)).map { calendar.format($0, "yyyy-MM-dd") })
        let weekStats = days.filter { dayKeys.contains($0.day) }
        let marks = assessments.filter { $0.mark != nil && ($0.due.map { $0 >= calendar.addingDays(-28, to: start) } ?? false) }
            .map { "\($0.moduleCode) \($0.title): \(Int($0.mark!))" }

        var slipping = overdue.prefix(5).map { "\($0.title) (overdue \(calendar.shortDay($0.deadline!)))" }
        if let review = moduleReview {
            for m in review.modules where m.status == .red {
                slipping.append("\(m.moduleCode): " + (m.reasons.first ?? "behind"))
            }
            for m in review.modules where !m.lecturesWithoutNotes.isEmpty {
                slipping.append("\(m.moduleCode): \(m.lecturesWithoutNotes.count) lecture(s) without notes")
            }
        }
        var wins: [String] = []
        let bestDay = weekStats.max { $0.studyMinutes < $1.studyMinutes }
        if let b = bestDay, b.studyMinutes >= 60 { wins.append("Best day \(b.day): \(b.studyMinutes) min study") }
        if doneThisWeek.count >= 10 { wins.append("\(doneThisWeek.count) to-dos done") }

        var next: [WeekRecap.PlanItem] = []
        for a in assessments where a.mark == nil && !a.submitted {
            if let d = a.due, d >= now, d < nextEnd {
                next.append(.init(id: a.id, title: "\(a.moduleCode) \(a.title) due \(calendar.shortDay(d))", date: d, moduleCode: a.moduleCode, kind: "deadline"))
            }
        }
        for t in tasks where t.completedAt == nil {
            if let d = t.deadline, d >= now, d < nextEnd {
                next.append(.init(id: t.id.uuidString, title: "\(t.title) (\(calendar.shortDay(d)))", date: d, moduleCode: t.moduleCode, kind: "task"))
            }
        }
        let fixed = events.filter { $0.start >= now && $0.start < nextEnd && !$0.isAllDay && $0.source != .orbit }
        next.sort { $0.date < $1.date }
        var focus: [String] = []
        if !overdue.isEmpty { focus.append("Clear the \(overdue.count) overdue item\(overdue.count == 1 ? "" : "s") first, Monday morning.") }
        if let soon = next.first(where: { $0.kind == "deadline" }) { focus.append("Front-load \(soon.title).") }
        focus.append("\(fixed.count) fixed events next week; protect 2 deep-work blocks a day including the weekend.")
        focus.append(contentsOf: groupDue.prefix(2).map { "Group: \($0)" })

        return WeekRecap(generatedAt: now, weekStart: start, tasksDone: doneThisWeek.count, tasksPlanned: planned,
                         studyMinutes: weekStats.reduce(0) { $0 + $1.studyMinutes }, activeDays: weekStats.filter(\.isActive).count,
                         marksReturned: marks, wins: wins, slipping: slipping, nextWeek: next, focusSuggestions: focus)
    }
}
