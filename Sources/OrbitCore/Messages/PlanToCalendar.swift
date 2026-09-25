import Foundation

/// A plan turned into a calendar event you can accept with one tap.
public struct PlanCalendarSuggestion: Identifiable, Hashable, Sendable {
    public var id: UUID { plan.id }
    public var plan: ExtractedPlan
    public var kind: PlanKind
    /// The event Orbit would add (to the Orbit calendar).
    public var event: CalendarEvent
    /// Busy events that overlap it.
    public var conflicts: [CalendarEvent]
    /// An event already on the calendar that looks like the same plan.
    public var duplicateOf: CalendarEvent?

    public var isDuplicate: Bool { duplicateOf != nil }
    public var hasConflicts: Bool { !conflicts.isEmpty }

    public init(plan: ExtractedPlan, kind: PlanKind, event: CalendarEvent,
                conflicts: [CalendarEvent] = [], duplicateOf: CalendarEvent? = nil) {
        self.plan = plan; self.kind = kind; self.event = event
        self.conflicts = conflicts; self.duplicateOf = duplicateOf
    }
}

/// Converts `ExtractedPlan`s into calendar event suggestions: fills in a
/// sensible length (dinner 2h, drinks 3h, coffee 1h, gym 1.5h, call 30m,
/// lecture 1h, party 4h, otherwise 2h), finds clashes with what's already on
/// the calendar, and spots plans that are already there.
public struct PlanToCalendar: Sendable {
    /// Calendar new events go to. Orbit writes to its own calendar, never yours.
    public var calendarID: String
    /// How far apart two starts can be and still count as the same plan when they don't overlap.
    public var duplicateSlack: TimeInterval

    public init(calendarID: String = "orbit", duplicateSlack: TimeInterval = 3600) {
        self.calendarID = calendarID; self.duplicateSlack = duplicateSlack
    }

    public static func defaultDuration(for title: String) -> TimeInterval {
        PlanKind.detect(in: title).defaultDuration
    }

    public func suggestion(for plan: ExtractedPlan, existing: [CalendarEvent]) -> PlanCalendarSuggestion {
        var kind = PlanKind.detect(in: plan.title)
        if kind == .other { kind = PlanKind.detect(in: plan.quote) }
        let end = plan.end.flatMap { $0 > plan.start ? $0 : nil } ?? plan.start.addingTimeInterval(kind.defaultDuration)
        let event = CalendarEvent(id: "plan-\(plan.id.uuidString)", title: plan.title, start: plan.start, end: end,
                                  location: plan.location, notes: Self.notes(for: plan),
                                  calendarID: calendarID, source: .orbit, isBusy: true)

        let duplicate = existing
            .filter { isDuplicate(event, of: $0) }
            .min { abs($0.start.timeIntervalSince(event.start)) < abs($1.start.timeIntervalSince(event.start)) }
        let conflicts = existing.filter { other in
            other.id != duplicate?.id && other.isBusy && !other.isAllDay
                && other.start < event.end && event.start < other.end
        }.sorted { $0.start < $1.start }
        return PlanCalendarSuggestion(plan: plan, kind: kind, event: event, conflicts: conflicts, duplicateOf: duplicate)
    }

    public func suggestions(for plans: [ExtractedPlan], existing: [CalendarEvent]) -> [PlanCalendarSuggestion] {
        plans.map { suggestion(for: $0, existing: existing) }
    }

    /// Same plan if the titles match loosely and the times overlap (or start within `duplicateSlack`).
    public func isDuplicate(_ event: CalendarEvent, of other: CalendarEvent) -> Bool {
        let overlaps = other.start < event.end && event.start < other.end
        let close = abs(other.start.timeIntervalSince(event.start)) <= duplicateSlack
        guard overlaps || close else { return false }
        return PlanTitleMatch.similar(event.title, other.title)
    }

    static func notes(for plan: ExtractedPlan) -> String {
        let from: String
        switch plan.source {
        case .whatsapp: from = "WhatsApp"
        case .instagram: from = "Instagram"
        case .imessage: from = "Messages"
        case .screenshot: from = "a screenshot"
        case .shared: from = "a shared message"
        }
        var lines = ["Added by Orbit from \(from)."]
        if !plan.quote.isEmpty { lines.append("“\(plan.quote)”") }
        if !plan.people.isEmpty { lines.append("With: \(plan.people.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }
}
