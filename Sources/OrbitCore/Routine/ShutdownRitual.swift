import Foundation

/// What to do with an unfinished to-do at shutdown.
public enum RolloverChoice: Codable, Hashable, Sendable {
    case tomorrow
    case day(Date)
    case drop
}

/// The result of applying a choice.
public enum RolloverOutcome: Hashable, Sendable {
    /// The task, moved (earliest start and, for your own to-dos, the deadline).
    case moved(OrbitTask, warning: String?)
    case dropped(UUID)
}

/// One evening's shutdown, kept as history.
public struct ShutdownRecord: Codable, Hashable, Sendable, Identifiable {
    /// "yyyy-MM-dd".
    public var id: String
    public var completedAt: Date
    public var doneCount: Int
    public var rolledOver: Int
    public var dropped: Int
    public var journal: String?
    public var streakAfter: Int

    public init(id: String, completedAt: Date, doneCount: Int, rolledOver: Int, dropped: Int, journal: String?, streakAfter: Int) {
        self.id = id; self.completedAt = completedAt; self.doneCount = doneCount; self.rolledOver = rolledOver
        self.dropped = dropped; self.journal = journal; self.streakAfter = streakAfter
    }
}

/// The logic behind the evening shutdown sheet.
public struct ShutdownPlanner: Sendable {
    public var prefs: UserPrefs
    public var calendar: DayCalendar

    public init(prefs: UserPrefs) {
        self.prefs = prefs
        self.calendar = DayCalendar(timeZone: prefs.timeZone)
    }

    public func dayKey(_ date: Date) -> String { calendar.format(date, "yyyy-MM-dd") }

    /// Today's to-dos: finished today, or open and (planned today or due by tonight).
    public func review(tasks: [OrbitTask], blocks: [ScheduledBlock], on day: Date) -> (done: [OrbitTask], notDone: [OrbitTask]) {
        let end = calendar.endOfDay(day)
        let planned = Set(blocks.filter { calendar.isSameDay($0.start, day) }.map(\.taskID))
        var done: [OrbitTask] = [], open: [OrbitTask] = []
        for t in tasks {
            if let c = t.completedAt {
                if calendar.isSameDay(c, day) { done.append(t) }
            } else if planned.contains(t.id) || (t.deadline.map { $0 < end } ?? false) {
                open.append(t)
            }
        }
        return (done.sorted { $0.completedAt! < $1.completedAt! },
                open.sorted { ($0.deadline ?? .distantFuture, $0.title) < ($1.deadline ?? .distantFuture, $1.title) })
    }

    /// Moves an unfinished task. The earliest start becomes the chosen day's start; your
    /// own to-dos also get their deadline moved to that evening if it would be missed.
    /// Required work keeps its real deadline (with a warning).
    public func apply(_ choice: RolloverChoice, to task: OrbitTask, now: Date) -> RolloverOutcome {
        let target: Date
        switch choice {
        case .drop: return .dropped(task.id)
        case .tomorrow: target = calendar.addingDays(1, to: calendar.startOfDay(now))
        case .day(let d): target = calendar.startOfDay(max(d, calendar.addingDays(1, to: calendar.startOfDay(now))))
        }
        var t = task
        let routine = prefs.effectiveRoutine.adjusted(prefs)
        t.earliestStart = calendar.date(minute: routine.dayStart, of: target)
        var warning: String?
        if let d = t.deadline, d < calendar.endOfDay(target) {
            if d <= t.earliestStart! {
                if task.origin == .required {
                    t.earliestStart = nil
                    warning = "“\(task.title)” is due \(calendar.shortDay(d)) \(calendar.time(d)); it stays in today's plan."
                } else {
                    t.deadline = calendar.date(minute: routine.workCutoff, of: target)
                }
            }
        }
        return .moved(t, warning: warning)
    }

    /// Due once the shutdown time has passed today and today's shutdown isn't recorded.
    public func isDue(now: Date, history: [ShutdownRecord]) -> Bool {
        let r = prefs.effectiveRoutine
        guard r.enabled, r.shutdownEnabled else { return false }
        guard calendar.minuteOfDay(now) >= r.shutdownTime else { return false }
        return !history.contains { $0.id == dayKey(now) }
    }

    /// Adds (or replaces) today's record, keeping the last 400.
    public func record(_ rec: ShutdownRecord, into history: [ShutdownRecord]) -> [ShutdownRecord] {
        var h = history.filter { $0.id != rec.id }
        h.append(rec)
        h.sort { $0.id < $1.id }
        return Array(h.suffix(400))
    }

    /// The first thing tomorrow (event, study block or meal), for the preview.
    public func firstThing(tomorrowOf now: Date, events: [CalendarEvent], blocks: [ScheduledBlock],
                           routine: [RoutineBlock]) -> (title: String, start: Date)? {
        let day = calendar.addingDays(1, to: calendar.startOfDay(now))
        var items: [(String, Date)] = events.filter { !$0.isAllDay && calendar.isSameDay($0.start, day) }.map { ($0.title, $0.start) }
        items += blocks.filter { calendar.isSameDay($0.start, day) }.map { ($0.title, $0.start) }
        items += routine.filter { $0.kind != .sleep && $0.kind != .shutdown && calendar.isSameDay($0.start, day) }.map { ($0.title, $0.start) }
        return items.min { $0.1 < $1.1 }.map { (title: $0.0, start: $0.1) }
    }
}
