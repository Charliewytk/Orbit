import Foundation
import SwiftData
import OrbitCore

/// One thing on the day's timeline: a calendar event or an Orbit work block.
struct AgendaItem: Identifiable, Hashable {
    enum Kind: String { case event, block, routine }
    var id: String
    var kind: Kind
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var moduleCode: String?
    var location: String?
    /// For blocks: the `StoredBlock` id.
    var blockID: String?
    var completed: Bool = false
    var skipped: Bool = false
    var started: Bool = false

    var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
    func contains(_ date: Date) -> Bool { start <= date && date < end }
}

/// Something due soon (task deadline or assessment).
struct DueEntry: Identifiable, Hashable {
    enum Kind: String { case task, assessment }
    var id: String
    var kind: Kind
    var title: String
    var due: Date
    var moduleCode: String?
    var weightPercent: Double?
    var isOverdue: Bool
}

/// Pure helpers that turn store records into what the Today screen, the menu
/// bar, widgets and intents show.
enum Agenda {
    static func items(events: [StoredEvent], blocks: [StoredBlock], on day: Date, calendar: DayCalendar) -> [AgendaItem] {
        let start = calendar.startOfDay(day), end = calendar.endOfDay(day)
        var out: [AgendaItem] = events.filter { $0.start < end && $0.end > start }.map { e in
            AgendaItem(id: "e-\(e.id)", kind: .event, title: e.title, start: e.start, end: e.end, isAllDay: e.isAllDay,
                       moduleCode: ModuleCode.find(in: e.title), location: e.location)
        }
        out += blocks.filter { $0.start < end && $0.end > start && !$0.skipped }.map { b in
            AgendaItem(id: "b-\(b.id)", kind: .block, title: b.title, start: b.start, end: b.end, isAllDay: false,
                       moduleCode: b.moduleCode, location: b.locationHint, blockID: b.id, completed: b.completed,
                       skipped: b.skipped, started: b.startedAt != nil)
        }
        return out.sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
    }

    /// The fixed routine (hall meals, reading, shutdown) on a day, laid out around that day's events.
    /// Sleep is left out (it's drawn as a band). Never written to Google unless the student opts in.
    static func routineItems(prefs: UserPrefs, events: [StoredEvent], on day: Date, calendar: DayCalendar) -> [AgendaItem] {
        let start = calendar.startOfDay(day), end = calendar.endOfDay(day)
        let evs = events.filter { $0.end > start && $0.start < end }.map(\.value)
        return RoutinePlanner(prefs: prefs).blocks(on: day, events: evs)
            .filter { $0.kind != .sleep && calendar.isSameDay($0.start, day) }
            .map { r in
                AgendaItem(id: "r-\(r.id)", kind: .routine, title: r.title, start: r.start, end: r.end, isAllDay: false,
                           moduleCode: nil, location: r.location ?? r.window.map { "open \(calendar.time($0.start))–\(calendar.time($0.end))" })
            }
    }

    /// What's happening now, or the next thing (today or tomorrow).
    static func nextUp(events: [StoredEvent], blocks: [StoredBlock], now: Date, calendar: DayCalendar) -> AgendaItem? {
        upcoming(events: events, blocks: blocks, now: now, calendar: calendar, limit: 1).first
    }

    static func upcoming(events: [StoredEvent], blocks: [StoredBlock], now: Date, calendar: DayCalendar,
                         limit: Int) -> [AgendaItem] {
        let today = items(events: events, blocks: blocks, on: now, calendar: calendar)
        let tomorrow = items(events: events, blocks: blocks, on: calendar.addingDays(1, to: now), calendar: calendar)
        var seen = Set<String>()
        return (today + tomorrow)
            .filter { !$0.isAllDay && $0.end > now && !$0.completed && seen.insert($0.id).inserted }
            .sorted { $0.start < $1.start }
            .prefix(limit).map { $0 }
    }

    static func dueSoon(tasks: [StoredTask], assessments: [StoredAssessment], now: Date, days: Int) -> [DueEntry] {
        let limit = now.addingTimeInterval(Double(days) * 86400)
        var out: [DueEntry] = tasks.compactMap { t in
            guard !t.isDone, let d = t.deadline, d < limit else { return nil }
            return DueEntry(id: "t-\(t.id)", kind: .task, title: t.title, due: d, moduleCode: t.moduleCode,
                            weightPercent: nil, isOverdue: d < now)
        }
        out += assessments.compactMap { a in
            guard !a.submitted, a.mark == nil, let d = a.due, d < limit, d > now.addingTimeInterval(-86400) else { return nil }
            return DueEntry(id: "a-\(a.id)", kind: .assessment, title: a.title, due: d, moduleCode: a.moduleCode,
                            weightPercent: a.weightPercent > 0 ? a.weightPercent : nil, isOverdue: d < now)
        }
        return out.sorted { $0.due < $1.due }
    }

    /// The small JSON the widgets read.
    @MainActor
    static func widgetSnapshot(context: ModelContext, now: Date = Date()) -> WidgetSnapshot {
        let cal = DayCalendar(timeZone: context.prefs.timeZone)
        let events = context.all(StoredEvent.self)
        let blocks = context.all(StoredBlock.self)
        let next = upcoming(events: events, blocks: blocks, now: now, calendar: cal, limit: 6).map { i in
            WidgetSnapshot.Item(id: i.id, kind: i.kind == .block ? .block : .event, title: i.title, start: i.start,
                                end: i.end, moduleCode: i.moduleCode,
                                detail: i.kind == .block ? "Focus block" : i.location)
        }
        let due = dueSoon(tasks: context.all(StoredTask.self), assessments: context.all(StoredAssessment.self),
                          now: now, days: 7).prefix(8).map { d in
            WidgetSnapshot.Item(id: d.id, kind: d.kind == .task ? .task : .assessment, title: d.title, due: d.due,
                                moduleCode: d.moduleCode, detail: d.weightPercent.map { "\(Int($0))%" })
        }
        return WidgetSnapshot(generatedAt: now, nextUp: next, dueThisWeek: Array(due))
    }
}
