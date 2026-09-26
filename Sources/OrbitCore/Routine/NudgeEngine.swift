import Foundation

public enum NudgeKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case freeGap, blockStarting, deadlineNoProgress, mealClosing, typeUp, flashcardsDue, streakAtRisk, shutdown, reading

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .freeGap: "Free time + something due"
        case .blockStarting: "Planned block starting"
        case .deadlineNoProgress: "Deadline in 24 h, not started"
        case .mealClosing: "Hall meal closing"
        case .typeUp: "Type up after lectures"
        case .flashcardsDue: "Flashcards due"
        case .streakAtRisk: "Streak at risk (20:30)"
        case .shutdown: "Shutdown ritual"
        case .reading: "Reading time"
        }
    }

    /// Routine reminders that go out even in quiet hours and don't count towards the daily cap.
    public var isRitual: Bool { self == .shutdown || self == .reading }

    /// Minimum minutes between two nudges of this kind.
    public var cooldownMinutes: Int {
        switch self {
        case .freeGap: 120
        case .blockStarting, .typeUp: 10
        case .deadlineNoProgress: 180
        case .mealClosing: 60
        case .flashcardsDue: 360
        case .streakAtRisk, .shutdown, .reading: 600
        }
    }
}

public enum NudgeAction: String, Codable, CaseIterable, Sendable {
    case startFocus, snooze30, notNow
}

public struct Nudge: Codable, Hashable, Sendable, Identifiable {
    /// De-duplication key: the same key is never sent twice (unless snoozed).
    public var id: String
    public var kind: NudgeKind
    public var title: String
    public var body: String
    /// 0–100, higher first.
    public var priority: Int
    public var taskID: UUID?
    public var blockID: UUID?
    /// Length of the focus session "Start focus" begins.
    public var focusMinutes: Int?
    public var focusTitle: String?

    public init(id: String, kind: NudgeKind, title: String, body: String, priority: Int, taskID: UUID? = nil,
                blockID: UUID? = nil, focusMinutes: Int? = nil, focusTitle: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.body = body; self.priority = priority
        self.taskID = taskID; self.blockID = blockID; self.focusMinutes = focusMinutes; self.focusTitle = focusTitle
    }
}

public struct NudgeLogEntry: Codable, Hashable, Sendable {
    public var key: String
    public var kind: NudgeKind
    public var firedAt: Date
    /// Set by "Snooze 30m": the nudge may come back after this.
    public var snoozedUntil: Date?
    public var action: NudgeAction?

    public init(key: String, kind: NudgeKind, firedAt: Date, snoozedUntil: Date? = nil, action: NudgeAction? = nil) {
        self.key = key; self.kind = kind; self.firedAt = firedAt; self.snoozedUntil = snoozedUntil; self.action = action
    }
}

public struct NudgeSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var disabledKinds: Set<NudgeKind>
    public var maxPerDay: Int
    public var quietStart: MinuteOfDay
    public var quietEnd: MinuteOfDay
    /// A free gap must be at least this long.
    public var minimumGapMinutes: Int
    /// Minutes between any two (non-ritual) nudges.
    public var spacingMinutes: Int
    public var flashcardThreshold: Int
    public var streakCheckTime: MinuteOfDay

    public init(enabled: Bool = true, disabledKinds: Set<NudgeKind> = [], maxPerDay: Int = 6,
                quietStart: MinuteOfDay = 22 * 60, quietEnd: MinuteOfDay = 7 * 60 + 30, minimumGapMinutes: Int = 45,
                spacingMinutes: Int = 20, flashcardThreshold: Int = 10, streakCheckTime: MinuteOfDay = 20 * 60 + 30) {
        self.enabled = enabled; self.disabledKinds = disabledKinds; self.maxPerDay = maxPerDay
        self.quietStart = quietStart; self.quietEnd = quietEnd; self.minimumGapMinutes = minimumGapMinutes
        self.spacingMinutes = spacingMinutes; self.flashcardThreshold = flashcardThreshold
        self.streakCheckTime = streakCheckTime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NudgeSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: key)) ?? fallback }
        enabled = v(.enabled, d.enabled)
        disabledKinds = v(.disabledKinds, d.disabledKinds)
        maxPerDay = v(.maxPerDay, d.maxPerDay)
        quietStart = v(.quietStart, d.quietStart)
        quietEnd = v(.quietEnd, d.quietEnd)
        minimumGapMinutes = v(.minimumGapMinutes, d.minimumGapMinutes)
        spacingMinutes = v(.spacingMinutes, d.spacingMinutes)
        flashcardThreshold = v(.flashcardThreshold, d.flashcardThreshold)
        streakCheckTime = v(.streakCheckTime, d.streakCheckTime)
    }

    public func isOn(_ kind: NudgeKind) -> Bool { enabled && !disabledKinds.contains(kind) }
}

/// A planned block, as the nudge engine sees it.
public struct NudgeBlock: Hashable, Sendable {
    public var id: UUID
    public var taskID: UUID
    public var title: String
    public var start: Date
    public var end: Date
    public var completed: Bool
    public var isTypeUp: Bool
    public var locationHint: String?

    public init(id: UUID, taskID: UUID, title: String, start: Date, end: Date, completed: Bool = false,
                isTypeUp: Bool = false, locationHint: String? = nil) {
        self.id = id; self.taskID = taskID; self.title = title; self.start = start; self.end = end
        self.completed = completed; self.isTypeUp = isTypeUp; self.locationHint = locationHint
    }
}

/// Everything the engine looks at.
public struct NudgeInput: Sendable {
    public var now: Date
    public var events: [CalendarEvent]
    public var blocks: [NudgeBlock]
    public var tasks: [OrbitTask]
    public var routine: [RoutineBlock]
    /// Routine block ids ticked as done ("ate dinner").
    public var routineDone: Set<String>
    public var flashcardsDue: Int
    public var streak: Int
    public var todayCounts: Bool
    public var focusActive: Bool
    public var shutdownDoneToday: Bool
    public var log: [NudgeLogEntry]

    public init(now: Date, events: [CalendarEvent] = [], blocks: [NudgeBlock] = [], tasks: [OrbitTask] = [],
                routine: [RoutineBlock] = [], routineDone: Set<String> = [], flashcardsDue: Int = 0, streak: Int = 0,
                todayCounts: Bool = true, focusActive: Bool = false, shutdownDoneToday: Bool = false, log: [NudgeLogEntry] = []) {
        self.now = now; self.events = events; self.blocks = blocks; self.tasks = tasks; self.routine = routine
        self.routineDone = routineDone; self.flashcardsDue = flashcardsDue; self.streak = streak
        self.todayCounts = todayCounts; self.focusActive = focusActive; self.shutdownDoneToday = shutdownDoneToday
        self.log = log
    }
}

/// Decides which proactive nudges to send right now. Pure: the app calls `evaluate`
/// every 5 minutes, posts the first result, and appends it to the log.
public struct NudgeEngine: Sendable {
    public var settings: NudgeSettings
    public var calendar: DayCalendar

    public init(settings: NudgeSettings = NudgeSettings(), calendar: DayCalendar = DayCalendar()) {
        self.settings = settings; self.calendar = calendar
    }

    // MARK: Filtering

    public func isQuietHours(_ date: Date) -> Bool {
        let m = calendar.minuteOfDay(date)
        let s = settings.quietStart, e = settings.quietEnd
        return s <= e ? (m >= s && m < e) : (m >= s || m < e)
    }

    /// Why ordinary nudges are held back right now (nil = they may go).
    public func suppression(_ input: NudgeInput) -> String? {
        let now = input.now
        if isQuietHours(now) { return "quiet hours" }
        if input.focusActive { return "focus session" }
        if input.events.contains(where: { $0.isBusy && !$0.isAllDay && $0.start <= now && now < $0.end }) { return "in a class or event" }
        if input.routine.contains(where: { $0.kind.isMeal && $0.start <= now && now < $0.end }) { return "meal" }
        return nil
    }

    private func sameDay(_ d: Date, _ now: Date) -> Bool { calendar.isSameDay(d, now) }

    /// Sent before and not snoozed-and-due-again.
    func alreadySent(_ key: String, _ input: NudgeInput) -> Bool {
        guard let last = input.log.filter({ $0.key == key }).max(by: { $0.firedAt < $1.firedAt }) else { return false }
        if let until = last.snoozedUntil { return input.now < until }
        return true
    }

    /// The nudges that may go now, highest priority first.
    public func evaluate(_ input: NudgeInput) -> [Nudge] {
        guard settings.enabled else { return [] }
        let now = input.now
        let todays = input.log.filter { sameDay($0.firedAt, now) && !$0.kind.isRitual }
        let capReached = todays.count >= settings.maxPerDay
        let lastAny = todays.map(\.firedAt).max()
        let spaced = lastAny.map { now.timeIntervalSince($0) >= Double(settings.spacingMinutes) * 60 } ?? true
        let held = suppression(input)

        return candidates(input).filter { n in
            guard settings.isOn(n.kind), !alreadySent(n.id, input) else { return false }
            // Snoozed nudges come back regardless of the per-kind cooldown.
            let snoozed = input.log.contains { $0.key == n.id && $0.snoozedUntil != nil }
            if !snoozed, let last = input.log.filter({ $0.kind == n.kind }).map(\.firedAt).max(),
               now.timeIntervalSince(last) < Double(n.kind.cooldownMinutes) * 60 {
                return false
            }
            if n.kind.isRitual { return true }
            if capReached || !spaced { return false }
            if let held {
                // A meal closing reminder may interrupt the meal slot itself.
                return n.kind == .mealClosing && held == "meal"
            }
            return true
        }
        .sorted { ($0.priority, $1.id) > ($1.priority, $0.id) }
    }

    // MARK: Rules

    /// Every nudge the rules produce, before cooldowns and quiet hours.
    public func candidates(_ input: NudgeInput) -> [Nudge] {
        var out: [Nudge] = []
        out += blockRules(input)
        if let n = freeGap(input) { out.append(n) }
        out += deadlineRules(input)
        out += mealRules(input)
        out += dayRules(input)
        return out
    }

    func blockRules(_ input: NudgeInput) -> [Nudge] {
        let now = input.now
        return input.blocks.compactMap { b in
            let lead = b.start.timeIntervalSince(now)
            guard !b.completed, lead > 0, lead <= 6 * 60 else { return nil }
            let mins = max(1, Int((lead / 60).rounded()))
            let place = b.locationHint.map { " · \($0)" } ?? ""
            if b.isTypeUp {
                return Nudge(id: "typeup:\(b.id.uuidString)", kind: .typeUp, title: b.title,
                             body: "Starts in \(mins) min\(place). Type it up while the lecture's fresh.",
                             priority: 88, taskID: b.taskID, blockID: b.id, focusMinutes: b.minutesLong, focusTitle: b.title)
            }
            return Nudge(id: "block:\(b.id.uuidString)", kind: .blockStarting, title: "\(b.title) in \(mins) min",
                         body: "\(calendar.time(b.start))–\(calendar.time(b.end))\(place). Ready to start?",
                         priority: 90, taskID: b.taskID, blockID: b.id, focusMinutes: b.minutesLong, focusTitle: b.title)
        }
    }

    /// The free stretch starting now (until the next event, block or routine block, or the shutdown).
    public func freeGap(at now: Date, input: NudgeInput) -> DateInterval? {
        let busy: [DateInterval] = input.events.filter { $0.isBusy && !$0.isAllDay }.map(\.interval)
            + input.blocks.filter { !$0.completed }.map { DateInterval(start: $0.start, end: $0.end) }
            + input.routine.map(\.interval)
        if busy.contains(where: { $0.start <= now && now < $0.end }) { return nil }
        let dayEnd = calendar.endOfDay(now)
        let next = busy.filter { $0.start > now }.map(\.start).min() ?? dayEnd
        let end = min(next, dayEnd)
        return end > now ? DateInterval(start: now, end: end) : nil
    }

    func freeGap(_ input: NudgeInput) -> Nudge? {
        let now = input.now
        guard let gap = freeGap(at: now, input: input), gap.duration >= Double(settings.minimumGapMinutes) * 60 else { return nil }
        let soon = now.addingTimeInterval(36 * 3600)
        guard let task = input.tasks.filter({ !$0.isDone && $0.remainingMinutes > 0 && ($0.deadline.map { $0 > now && $0 <= soon } ?? false) })
            .min(by: { ($0.deadline!, -$0.priority.rawValue) < ($1.deadline!, -$1.priority.rawValue) }) else { return nil }
        let gapText = Self.durationText(Int(gap.duration / 60))
        let dueText = Self.dueText(task.deadline!, now: now, calendar: calendar)
        let minutes = min(Int(gap.duration / 60), max(25, min(task.remainingMinutes, 90)))
        return Nudge(id: "gap:\(task.id.uuidString):\(calendar.format(now, "yyyy-MM-dd"))", kind: .freeGap,
                     title: "You've got \(gapText) free",
                     body: "You've got \(gapText) free and \(task.title) is due \(dueText). Start it?",
                     priority: 70, taskID: task.id, focusMinutes: minutes, focusTitle: task.title)
    }

    func deadlineRules(_ input: NudgeInput) -> [Nudge] {
        let now = input.now
        let started = Set(input.blocks.filter(\.completed).map(\.taskID))
        return input.tasks.compactMap { t in
            guard !t.isDone, let d = t.deadline, d > now, d.timeIntervalSince(now) <= 24 * 3600,
                  t.minutesDone == 0, !started.contains(t.id) else { return nil }
            return Nudge(id: "deadline:\(t.id.uuidString)", kind: .deadlineNoProgress, title: "\(t.title) is due \(Self.dueText(d, now: now, calendar: calendar))",
                         body: "No progress logged yet. Even 25 minutes now makes tomorrow easier.",
                         priority: 80, taskID: t.id, focusMinutes: 25, focusTitle: t.title)
        }
    }

    func mealRules(_ input: NudgeInput) -> [Nudge] {
        let now = input.now
        return input.routine.compactMap { r in
            guard r.kind.isMeal, let w = r.window, !input.routineDone.contains(r.id), now >= r.start,
                  now < w.end, w.end.timeIntervalSince(now) <= 30 * 60 else { return nil }
            let left = max(1, Int((w.end.timeIntervalSince(now) / 60).rounded()))
            return Nudge(id: "meal:\(r.id)", kind: .mealClosing, title: r.closesLine(calendar: calendar) ?? r.title,
                         body: "\(left) min left at \(r.location ?? "the hall") and you haven't ticked \(r.title.lowercased()) yet.",
                         priority: 85)
        }
    }

    func dayRules(_ input: NudgeInput) -> [Nudge] {
        let now = input.now
        let m = calendar.minuteOfDay(now)
        let day = calendar.format(now, "yyyy-MM-dd")
        var out: [Nudge] = []
        if input.flashcardsDue >= settings.flashcardThreshold {
            out.append(Nudge(id: "cards:\(day)", kind: .flashcardsDue, title: "\(input.flashcardsDue) flashcards due",
                             body: "About \(max(5, input.flashcardsDue / 3)) minutes clears them.", priority: 40,
                             focusMinutes: max(5, min(30, input.flashcardsDue / 3)), focusTitle: "Flashcard review"))
        }
        let shutdown = input.routine.first { $0.kind == .shutdown && sameDay($0.start, now) }
        if input.streak > 0, !input.todayCounts, m >= settings.streakCheckTime, shutdown.map({ now < $0.start }) ?? true {
            out.append(Nudge(id: "streak:\(day)", kind: .streakAtRisk, title: "Your \(input.streak)-day streak is at risk",
                             body: "One to-do, 10 minutes of focus or 5 flashcards keeps it alive.", priority: 75,
                             focusMinutes: 10, focusTitle: "Keep the streak"))
        }
        if let s = shutdown, !input.shutdownDoneToday, now >= s.start.addingTimeInterval(-60), now < s.start.addingTimeInterval(20 * 60) {
            out.append(Nudge(id: "shutdown:\(day)", kind: .shutdown, title: "Shutdown time — 2 minutes",
                             body: "Tick off today, roll over the rest, see tomorrow.", priority: 100))
        }
        if let r = input.routine.first(where: { $0.kind == .reading && sameDay($0.start, now) }),
           now >= r.start.addingTimeInterval(-120), now < r.start.addingTimeInterval(10 * 60) {
            out.append(Nudge(id: "reading:\(day)", kind: .reading, title: r.title,
                             body: "\(r.minutes) minutes with your book, then lights out.", priority: 95))
        }
        return out
    }

    // MARK: Text

    static func durationText(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        if m < 10 { return h == 1 ? "an hour" : "\(h) hours" }
        return "\(h)h \(m)m"
    }

    static func dueText(_ due: Date, now: Date, calendar: DayCalendar) -> String {
        if calendar.isSameDay(due, now) { return "today at \(calendar.time(due))" }
        if calendar.days(from: now, to: due) == 1 { return "tomorrow" }
        return calendar.format(due, "EEEE")
    }
}

extension NudgeBlock {
    var minutesLong: Int { max(5, Int(end.timeIntervalSince(start) / 60)) }
}
