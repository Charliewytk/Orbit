import Foundation

/// A teaching session that gets a "type up your notes" block afterwards.
public struct TypeUpSession: Codable, Hashable, Sendable, Identifiable {
    /// The tracked lecture id ("<event id>@<start>").
    public var id: String
    public var moduleCode: String
    public var kind: TrackedLecture.SessionKind
    public var week: Int?
    public var start: Date
    public var end: Date
    public var location: String?

    public init(id: String, moduleCode: String, kind: TrackedLecture.SessionKind, week: Int?, start: Date, end: Date,
                location: String? = nil) {
        self.id = id; self.moduleCode = moduleCode; self.kind = kind; self.week = week
        self.start = start; self.end = end; self.location = location
    }

    public init(_ l: TrackedLecture) {
        self.init(id: l.id, moduleCode: l.moduleCode, kind: l.kind, week: l.week, start: l.start, end: l.end, location: l.location)
    }

    /// "Lecture", "Tutorial"…
    public var kindLabel: String {
        switch kind {
        case .lecture: "Lecture"
        case .tutorial: "Tutorial"
        case .seminar: "Seminar"
        case .workshop: "Workshop"
        case .practical: "Practical"
        case .other: "Session"
        }
    }
}

/// A planned type-up block.
public struct TypeUpBlock: Codable, Hashable, Sendable, Identifiable {
    public var id: String { sessionID }
    public var sessionID: String
    public var moduleCode: String
    public var week: Int?
    public var title: String
    public var start: Date
    public var end: Date
    public var locationHint: String
    /// True when it sits on campus straight after the session.
    public var onCampus: Bool

    public init(sessionID: String, moduleCode: String, week: Int?, title: String, start: Date, end: Date,
                locationHint: String, onCampus: Bool) {
        self.sessionID = sessionID; self.moduleCode = moduleCode; self.week = week; self.title = title
        self.start = start; self.end = end; self.locationHint = locationHint; self.onCampus = onCampus
    }
    /// Stable ids so re-planning finds the same task and block.
    public var taskID: UUID { TypeUpPlanner.taskID(sessionID: sessionID) }
    public var blockID: UUID { StableUUID.make("orbit-typeup-block|\(sessionID)") }

    public var interval: DateInterval { DateInterval(start: start, end: end) }
}

/// A typed note seen in the Library (module, week, last change).
public struct TypedNoteRef: Codable, Hashable, Sendable {
    public var moduleCode: String?
    public var week: Int?
    public var modified: Date
    public init(moduleCode: String?, week: Int?, modified: Date) {
        self.moduleCode = moduleCode; self.week = week; self.modified = modified
    }
}

/// Plans a type-up block after each lecture, tutorial, seminar and workshop, as soon
/// as possible: on campus straight after it when there's room (walking time only),
/// otherwise at the hall later that day (after travelling back), otherwise the next morning.
public struct TypeUpPlanner: Sendable {
    public static let kinds: Set<TrackedLecture.SessionKind> = [.lecture, .tutorial, .seminar, .workshop]

    public var prefs: UserPrefs
    public var routine: RoutineSettings
    public var calendar: DayCalendar

    public init(prefs: UserPrefs) {
        self.prefs = prefs
        self.routine = prefs.effectiveRoutine
        self.calendar = DayCalendar(timeZone: prefs.timeZone)
    }

    public static func taskID(sessionID: String) -> UUID { StableUUID.make("orbit-typeup|\(sessionID)") }

    /// "Type up BEE1022 Lecture notes".
    public static func title(for s: TypeUpSession) -> String { "Type up \(s.moduleCode) \(s.kindLabel) notes" }

    var minutes: Int { max(5, routine.typeUpMinutes) }

    /// Plans blocks for sessions that don't have one yet. `busy` is everything already
    /// on the plan (study blocks, earlier type-ups); routine blocks and travel are added here.
    /// Blocks placed in this call count as busy for the next ones.
    public func plan(sessions: [TypeUpSession], alreadyPlanned: Set<String>, events: [CalendarEvent],
                     busy: [DateInterval], now: Date) -> [TypeUpBlock] {
        guard routine.enabled, routine.typeUpEnabled else { return [] }
        var taken = busy
        var out: [TypeUpBlock] = []
        for s in sessions.sorted(by: { $0.end < $1.end }) where Self.kinds.contains(s.kind) && !alreadyPlanned.contains(s.id) {
            // Old sessions are left alone (their type-up would already have expired).
            guard s.end > now.addingTimeInterval(-Double(routine.typeUpExpiryDays) * 86400) else { continue }
            if let b = place(s, events: events, busy: taken, now: now) {
                out.append(b)
                taken.append(b.interval)
            }
        }
        return out
    }

    /// Where one session's type-up goes.
    public func place(_ s: TypeUpSession, events: [CalendarEvent], busy: [DateInterval], now: Date) -> TypeUpBlock? {
        let t = routine.travel
        let length = TimeInterval(minutes * 60)
        let others = events.filter { $0.isBusy && !$0.isAllDay && $0.end > $0.start && !($0.start == s.start && $0.end == s.end) }
        let planner = RoutinePlanner(settings: routine, calendar: calendar)
        let day = calendar.startOfDay(s.end)
        let routineBusy = planner.blocks(from: day, to: calendar.addingDays(3, to: day), events: events).map(\.interval)
        let cutoff = calendar.date(minute: routine.adjusted(prefs).workCutoff, of: day)

        // 1. On campus, straight after the session (walk to the library), if it fits before
        //    the next thing (and the walk to it) and nothing else is booked.
        let sessionEvent = CalendarEvent(title: s.kindLabel, start: s.start, end: s.end, location: s.location, source: .timetable)
        if t.place(of: sessionEvent) != .home {
            let start = IntervalMath.roundUp5(max(now, s.end.addingTimeInterval(Double(t.walkMinutes) * 60)))
            let slot = DateInterval(start: start, end: start.addingTimeInterval(length))
            let walk = Double(t.walkMinutes) * 60
            let clashesEvent = others.contains { e in
                e.start.addingTimeInterval(-walk) < slot.end && e.end.addingTimeInterval(walk) > slot.start
            }
            let clashesBusy = (busy + routineBusy).contains { $0.start < slot.end && $0.end > slot.start }
            if calendar.isSameDay(slot.start, s.end), slot.end <= cutoff, !clashesEvent, !clashesBusy {
                return TypeUpBlock(sessionID: s.id, moduleCode: s.moduleCode, week: s.week, title: Self.title(for: s),
                                   start: slot.start, end: slot.end, locationHint: "\(t.campusStudySpot) (on campus)", onCampus: true)
            }
        }

        // 2. At the hall: first free slot after getting back, today, then the next days' mornings.
        let finder = FreeSlotFinder(prefs: routine.adjusted(prefs), minimumSlotMinutes: minutes)
        let travel = planner.travelIntervals(events: events + [sessionEvent])
        let blocked = busy + routineBusy + travel
        let earliest = max(now, s.end.addingTimeInterval(Double(t.travelMinutes) * 60))
        for offset in 0..<3 {
            let d = calendar.addingDays(offset, to: day)
            for slot in finder.freeSlots(on: d, events: others, blocked: blocked) {
                let start = IntervalMath.roundUp5(max(slot.start, earliest))
                guard slot.end.timeIntervalSince(start) >= length else { continue }
                let interval = DateInterval(start: start, end: start.addingTimeInterval(length))
                return TypeUpBlock(sessionID: s.id, moduleCode: s.moduleCode, week: s.week, title: Self.title(for: s),
                                   start: interval.start, end: interval.end,
                                   locationHint: planner.locationHint(for: interval, events: events), onCampus: false)
            }
        }
        return nil
    }

    public enum Status: String, Codable, Sendable { case pending, done, expired }

    /// Done once a typed note for the module (and week, when both are known) was saved
    /// after the session started; expired when still not done `typeUpExpiryDays` after the block.
    public func status(of block: TypeUpBlock, sessionStart: Date, typedNotes: [TypedNoteRef], now: Date) -> Status {
        let done = typedNotes.contains { n in
            guard n.moduleCode?.caseInsensitiveCompare(block.moduleCode) == .orderedSame else { return false }
            if let w = block.week, let nw = n.week, w != nw { return false }
            // Touched after the session started (a week file may hold several sessions).
            return n.modified >= sessionStart
        }
        if done { return .done }
        if now >= block.start.addingTimeInterval(Double(routine.typeUpExpiryDays) * 86400) { return .expired }
        return .pending
    }
}
