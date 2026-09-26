import Foundation

/// Everything for the morning notification and Today header. Plain data first;
/// `narrate(using:)` adds a friendly AI-written paragraph on top.
public struct MorningBrief: Codable, Hashable, Sendable {
    /// Local midnight of the day this brief is for.
    public var date: Date
    public var generatedAt: Date
    public var timeZoneID: String
    /// Today's timed events (not Orbit blocks), in order.
    public var events: [CalendarEvent]
    public var allDayEvents: [CalendarEvent]
    /// Today's planned Orbit blocks, in order.
    public var blocks: [ScheduledBlock]
    /// Deadlines and assessments in the next week (including overdue ones).
    public var dueSoon: [DueItem]
    public var topEmails: [EmailDigest]
    public var flashcardsDue: Int
    public var plannedMinutes: Int
    /// Minutes of busy timed events today.
    public var busyMinutes: Int
    /// Earliest start among today's events and blocks.
    public var firstStart: Date?
    /// AI paragraph, once narrated.
    public var narrative: String?

    public var calendar: DayCalendar { DayCalendar(timeZone: TimeZone(identifier: timeZoneID) ?? .current) }

    /// Deterministic plain-text version (also the facts sent to the AI, and a fallback).
    public func plainSummary() -> String {
        let cal = calendar
        var lines = ["Date: \(cal.format(date, "EEEE d MMMM yyyy"))"]
        if events.isEmpty {
            lines.append("Events today: none.")
        } else {
            lines.append("Events today: " + events.map { e in
                "\(BriefText.range(e.start, e.end, cal)) \(e.title)" + (e.location.map { " (\($0))" } ?? "")
            }.joined(separator: "; ") + ".")
        }
        if !allDayEvents.isEmpty {
            lines.append("All day: " + allDayEvents.map(\.title).joined(separator: "; ") + ".")
        }
        if blocks.isEmpty {
            lines.append("Planned study blocks: none.")
        } else {
            lines.append("Planned study blocks: " + blocks.map { b in
                "\(BriefText.range(b.start, b.end, cal)) \(b.title)" + (b.moduleCode.map { " (\($0))" } ?? "")
            }.joined(separator: "; ") + ". Total \(BriefText.duration(plannedMinutes)).")
        }
        if dueSoon.isEmpty {
            lines.append("Due in the next week: nothing.")
        } else {
            lines.append("Due soon: " + dueSoon.map { BriefText.dueLabel($0, cal) }.joined(separator: "; ") + ".")
        }
        if !topEmails.isEmpty {
            lines.append("Emails worth a look: " + topEmails.map { e in
                "[\(e.category.rawValue)] \(e.subject) from \(e.from)" + (e.summary.isEmpty ? "" : ": \(e.summary)")
            }.joined(separator: "; ") + ".")
        }
        if flashcardsDue > 0 {
            // A short daily review beats a long one: ~30 s a card, capped at 10 minutes.
            let session = min(flashcardsDue, 10 * 60 / FlashcardDeck.secondsPerCard)
            let minutes = max(1, Int((Double(session * FlashcardDeck.secondsPerCard) / 60).rounded(.up)))
            lines.append("Flashcards due: \(flashcardsDue). Suggest a \(minutes)-minute review of \(session) card\(session == 1 ? "" : "s")"
                         + (flashcardsDue > session ? " (the rest can wait)." : "."))
        }
        return lines.joined(separator: "\n")
    }

    /// A friendly 3–5 sentence summary in UK English.
    public func narrate(using router: LLMRouter) async throws -> String {
        try await BriefText.narrate(facts: plainSummary(), kind: "morning brief", router: router)
    }

    /// A copy with `narrative` filled in (left nil if the AI is unavailable).
    public func narrated(using router: LLMRouter) async -> MorningBrief {
        var copy = self
        copy.narrative = try? await narrate(using: router)
        return copy
    }
}

public struct MorningBriefBuilder: Sendable {
    public var prefs: UserPrefs
    public var dueSoonDays: Int
    public var maxEmails: Int

    public init(prefs: UserPrefs = UserPrefs(), dueSoonDays: Int = 7, maxEmails: Int = 5) {
        self.prefs = prefs; self.dueSoonDays = dueSoonDays; self.maxEmails = maxEmails
    }

    static let categoryRank: [EmailCategory: Int] = [.urgent: 0, .needsReply: 1, .hasDate: 2, .uni: 3, .other: 4]

    public func build(now: Date, events: [CalendarEvent], blocks: [ScheduledBlock], tasks: [OrbitTask],
                      assessments: [Assessment] = [], emails: [EmailDigest] = [],
                      flashcards: [Flashcard]) -> MorningBrief {
        let cal = DayCalendar(timeZone: prefs.timeZone)
        let endOfToday = cal.endOfDay(now)
        return build(now: now, events: events, blocks: blocks, tasks: tasks, assessments: assessments,
                     emails: emails, flashcardsDue: flashcards.filter { $0.due < endOfToday }.count)
    }

    public func build(now: Date, events: [CalendarEvent], blocks: [ScheduledBlock], tasks: [OrbitTask],
                      assessments: [Assessment] = [], emails: [EmailDigest] = [],
                      flashcardsDue: Int = 0) -> MorningBrief {
        let cal = DayCalendar(timeZone: prefs.timeZone)
        let day = cal.startOfDay(now), dayEnd = cal.endOfDay(now)
        let today = events.filter { $0.source != .orbit && $0.start < dayEnd && $0.end > day }
        let timed = today.filter { !$0.isAllDay }.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
        let allDay = today.filter(\.isAllDay).sorted { $0.title < $1.title }
        let todayBlocks = blocks.filter { $0.start >= day && $0.start < dayEnd }.sorted { $0.start < $1.start }
        let busy = timed.filter(\.isBusy).reduce(0) { total, e in
            total + IntervalMath.minutes(DateInterval(start: max(e.start, day), end: max(max(e.start, day), min(e.end, dayEnd))))
        }
        let top = emails.filter { $0.category != .ignore }.sorted { a, b in
            let ra = Self.categoryRank[a.category] ?? 9, rb = Self.categoryRank[b.category] ?? 9
            if ra != rb { return ra < rb }
            if a.importance != b.importance { return a.importance > b.importance }
            return a.date > b.date
        }.prefix(maxEmails)

        return MorningBrief(
            date: day, generatedAt: now, timeZoneID: prefs.timeZoneID, events: timed, allDayEvents: allDay,
            blocks: todayBlocks,
            dueSoon: BriefText.dueItems(now: now, days: dueSoonDays, tasks: tasks, assessments: assessments, cal: cal),
            topEmails: Array(top), flashcardsDue: flashcardsDue,
            plannedMinutes: todayBlocks.reduce(0) { $0 + $1.minutes }, busyMinutes: busy,
            firstStart: (timed.map(\.start) + todayBlocks.map(\.start)).min(), narrative: nil)
    }
}
