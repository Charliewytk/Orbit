import Foundation

// MARK: - Context

/// Everything the planner may look at. The app builds this from its stores
/// (calendar, ELE lecture tracking, notes, tasks, scheduled blocks).
public struct PlannerContext: Sendable {
    /// A block already on the plan that can be moved (not a fixed event).
    public struct FlexibleBlock: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var start: Date
        public var end: Date
        public init(id: String, title: String, start: Date, end: Date) {
            self.id = id; self.title = title; self.start = start; self.end = end
        }
    }

    public var now: Date
    public var prefs: UserPrefs
    /// Fixed calendar events (lectures, socials…).
    public var events: [CalendarEvent]
    /// Teaching sessions with their notes status (from `LectureTracker`).
    public var lectures: [TrackedLecture]
    /// "ECM1400" → "Programming".
    public var moduleNames: [String: String]
    public var tasks: [OrbitTask]
    public var flexibleBlocks: [FlexibleBlock]
    /// Recording / slide links per lecture id, when ELE has them.
    public var lectureLinks: [String: [URL]]

    public init(now: Date, prefs: UserPrefs = UserPrefs(), events: [CalendarEvent] = [], lectures: [TrackedLecture] = [],
                moduleNames: [String: String] = [:], tasks: [OrbitTask] = [], flexibleBlocks: [FlexibleBlock] = [],
                lectureLinks: [String: [URL]] = [:]) {
        self.now = now; self.prefs = prefs; self.events = events; self.lectures = lectures
        self.moduleNames = moduleNames; self.tasks = tasks; self.flexibleBlocks = flexibleBlocks
        self.lectureLinks = lectureLinks
    }

    public var calendar: DayCalendar { DayCalendar(timeZone: prefs.timeZone) }

    func moduleLabel(_ code: String) -> String {
        moduleNames[code].map { "\($0) (\(code))" } ?? code
    }
}

// MARK: - Intents

/// One thing the user asked for, as the parser (AI or rules) understood it.
public struct PlannerIntent: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// "I don't want to do any work today": keep a day free.
        case restDay = "rest_day"
        /// "Type up a week's worth of stuff from last week, due Monday".
        case typeUp = "type_up"
        /// "I missed my 8:35 lecture on Friday, need to go over it".
        case catchUp = "catch_up"
        /// Anything else with an optional deadline and estimate.
        case task
    }

    public var kind: Kind
    public var title: String?
    /// restDay: the day. typeUp: period start. catchUp: when the missed session was (day, with time if known).
    public var date: Date?
    /// typeUp: period end (exclusive).
    public var until: Date?
    public var deadline: Date?
    public var minutes: Int?
    public var moduleCode: String?
    /// The words it came from.
    public var quote: String?

    public init(kind: Kind, title: String? = nil, date: Date? = nil, until: Date? = nil, deadline: Date? = nil,
                minutes: Int? = nil, moduleCode: String? = nil, quote: String? = nil) {
        self.kind = kind; self.title = title; self.date = date; self.until = until; self.deadline = deadline
        self.minutes = minutes; self.moduleCode = moduleCode; self.quote = quote
    }
}

// MARK: - Proposal

/// A concrete sub-task with a proposed slot. The user can accept, edit or remove each.
public struct ProposedItem: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case typeUp, catchUp, task }
    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String?
    public var minutes: Int
    public var start: Date?
    public var deadline: Date?
    public var moduleCode: String?
    /// The lecture it's about (type-ups and catch-ups).
    public var lectureID: String?
    public var links: [URL]
    public var included: Bool

    public init(id: String, kind: Kind, title: String, detail: String? = nil, minutes: Int, start: Date? = nil,
                deadline: Date? = nil, moduleCode: String? = nil, lectureID: String? = nil, links: [URL] = [],
                included: Bool = true) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.minutes = minutes
        self.start = start; self.deadline = deadline; self.moduleCode = moduleCode; self.lectureID = lectureID
        self.links = links; self.included = included
    }

    public var end: Date? { start?.addingTimeInterval(TimeInterval(minutes * 60)) }

    /// The task to create when the plan is committed.
    public func task(createdAt: Date) -> OrbitTask {
        var t = OrbitTask(title: title, notes: [detail, links.isEmpty ? nil : links.map(\.absoluteString).joined(separator: "\n")]
                            .compactMap { $0 }.joined(separator: "\n"),
                          estimateMinutes: minutes, deadline: deadline, earliestStart: start,
                          priority: deadline == nil ? .normal : .high, moduleCode: moduleCode,
                          source: .assistant, sourceRef: "orbit-planner:\(id)", createdAt: createdAt)
        t.minBlockMinutes = min(t.minBlockMinutes, minutes)
        t.maxBlockMinutes = max(t.maxBlockMinutes, minutes)
        return t
    }
}

public struct PlanProposal: Codable, Hashable, Sendable {
    public var intents: [PlannerIntent]
    public var items: [ProposedItem]
    /// Days to keep free (start of day).
    public var restDays: [Date]
    /// Flexible blocks on those days that will be moved elsewhere.
    public var blocksToMove: [PlannerContext.FlexibleBlock]
    public var warnings: [String]
    /// "Here's what I'll do: …"
    public var summary: String
    /// True when the AI understood the request (rules otherwise).
    public var usedAI: Bool
}

// MARK: - Planner

/// Turns a rambling request ("first of all no work today, second I need to type up
/// last week for Monday, third I missed my 8:35 on Friday") into a reviewed plan:
///
/// 1. **Understand**: an AI agent with read-only tools (`lectures`, `calendar`,
///    `tasks`) replies with structured `{"intents":[…]}`; without AI, rules do it.
/// 2. **Look up**: type-ups become one item per lecture in that period whose notes
///    are missing or thin; a catch-up finds the lecture at that day and time.
/// 3. **Schedule**: items go into free slots before their deadline, around fixed
///    events, meals, the daily focus cap, and any day kept free.
/// 4. **Revise**: a one-line reply ("move the stats one to Sunday") edits the plan.
public struct ConversationalPlanner: Sendable {
    public var router: LLMRouter?
    public var purpose: LLMPurpose
    public var maxToolSteps: Int

    public init(router: LLMRouter? = nil, purpose: LLMPurpose = .privateData, maxToolSteps: Int = 4) {
        self.router = router; self.purpose = purpose; self.maxToolSteps = maxToolSteps
    }

    public func propose(_ input: String, context: PlannerContext) async -> PlanProposal {
        var intents: [PlannerIntent] = []
        var usedAI = false
        if router != nil, let ai = try? await aiIntents(input, context: context), !ai.isEmpty {
            intents = ai
            usedAI = true
        }
        if intents.isEmpty { intents = PlannerRules(context: context).intents(in: input) }
        var proposal = build(intents: intents, context: context)
        proposal.usedAI = usedAI
        return proposal
    }

    // MARK: Build

    public func build(intents: [PlannerIntent], context: PlannerContext) -> PlanProposal {
        let cal = context.calendar
        var items: [ProposedItem] = []
        var warnings: [String] = []
        var restDays: [Date] = []
        var coveredLectures = Set<String>()

        for intent in intents where intent.kind == .restDay {
            restDays.append(cal.startOfDay(intent.date ?? context.now))
        }
        // Catch-ups first so the same lecture isn't also a plain type-up.
        for intent in intents where intent.kind == .catchUp {
            if let lecture = findLecture(for: intent, context: context) {
                coveredLectures.insert(lecture.id)
                items.append(catchUpItem(lecture, deadline: intent.deadline, context: context))
            } else {
                let when = intent.date.map { cal.format($0, "EEE HH:mm") } ?? "that session"
                warnings.append("Couldn't find the lecture at \(when) in your timetable, so I added a general catch-up.")
                items.append(ProposedItem(id: "catchup-\(items.count)", kind: .catchUp,
                                          title: intent.title ?? "Catch up on the missed lecture", minutes: intent.minutes ?? 90,
                                          deadline: intent.deadline, moduleCode: intent.moduleCode))
            }
        }
        for intent in intents where intent.kind == .typeUp {
            let found = lecturesToTypeUp(intent, context: context).filter { !coveredLectures.contains($0.id) }
            if found.isEmpty {
                warnings.append("Every lecture in that period already has notes, so there's nothing to type up.")
            }
            for l in found {
                coveredLectures.insert(l.id)
                items.append(typeUpItem(l, deadline: intent.deadline, context: context))
            }
        }
        for intent in intents where intent.kind == .task {
            let title = intent.title ?? intent.quote ?? "Task"
            items.append(ProposedItem(id: "task-\(StableID.uuid(title).uuidString.prefix(8))", kind: .task, title: title,
                                      minutes: intent.minutes ?? 60, deadline: intent.deadline, moduleCode: intent.moduleCode))
        }

        let moved = context.flexibleBlocks.filter { b in restDays.contains { cal.isSameDay($0, b.start) } && b.end > context.now }
        var proposal = PlanProposal(intents: intents, items: items, restDays: restDays, blocksToMove: moved,
                                    warnings: warnings, summary: "", usedAI: false)
        schedule(&proposal, context: context)
        proposal.summary = summary(proposal, context: context)
        return proposal
    }

    func findLecture(for intent: PlannerIntent, context: PlannerContext) -> TrackedLecture? {
        let cal = context.calendar
        let past = context.lectures.filter { $0.start < context.now }
        if let date = intent.date {
            let sameDay = past.filter { cal.isSameDay($0.start, date) && (intent.moduleCode == nil || $0.moduleCode == intent.moduleCode) }
            let hasClock = cal.minuteOfDay(date) != 0
            if hasClock {
                return sameDay.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
                    .flatMap { abs($0.start.timeIntervalSince(date)) <= 45 * 60 ? $0 : nil }
            }
            return sameDay.first { $0.kind == .lecture } ?? sameDay.first
        }
        if let code = intent.moduleCode {
            return past.filter { $0.moduleCode == code }.max { $0.start < $1.start }
        }
        return nil
    }

    func lecturesToTypeUp(_ intent: PlannerIntent, context: PlannerContext) -> [TrackedLecture] {
        let from = intent.date ?? context.calendar.addingDays(-7, to: context.now)
        let to = min(intent.until ?? context.now, context.now)
        let kinds: Set<TrackedLecture.SessionKind> = [.lecture, .seminar, .workshop]
        return context.lectures
            .filter { $0.start >= from && $0.start < to && kinds.contains($0.kind) }
            .filter { $0.status == .noNotes || $0.status == .notesIncomplete }
            .filter { intent.moduleCode == nil || $0.moduleCode == intent.moduleCode }
            .sorted { $0.start < $1.start }
    }

    func typeUpItem(_ l: TrackedLecture, deadline: Date?, context: PlannerContext) -> ProposedItem {
        let cal = context.calendar
        let session = TypeUpSession(l)
        let thin = l.status == .notesIncomplete
        return ProposedItem(id: "typeup-\(l.id)", kind: .typeUp,
                            title: "Type up \(session.kindLabel.lowercased()): \(context.moduleLabel(l.moduleCode))",
                            detail: "\(cal.format(l.start, "EEE d MMM HH:mm"))" + (l.title.isEmpty ? "" : " · \(l.title)")
                                + (thin ? " · notes are thin, fill the gaps" : ""),
                            minutes: thin ? 30 : 45, deadline: deadline, moduleCode: l.moduleCode, lectureID: l.id,
                            links: context.lectureLinks[l.id] ?? [])
    }

    func catchUpItem(_ l: TrackedLecture, deadline: Date?, context: PlannerContext) -> ProposedItem {
        let cal = context.calendar
        let slides = l.slideTitles.isEmpty ? "" : " · slides: \(l.slideTitles.prefix(2).joined(separator: ", "))"
        return ProposedItem(id: "catchup-\(l.id)", kind: .catchUp,
                            title: "Watch recording + go through slides: \(context.moduleLabel(l.moduleCode))",
                            detail: "Missed \(cal.format(l.start, "EEE d MMM HH:mm"))" + (l.title.isEmpty ? "" : " · \(l.title)") + slides,
                            minutes: 90, deadline: deadline, moduleCode: l.moduleCode, lectureID: l.id,
                            links: context.lectureLinks[l.id] ?? [])
    }

    // MARK: Scheduling

    /// Places included items that have no start yet, earliest deadline first.
    public func schedule(_ proposal: inout PlanProposal, context: PlannerContext) {
        let cal = context.calendar
        let finder = FreeSlotFinder(prefs: context.prefs)
        let restBlocks = proposal.restDays.map { DateInterval(start: $0, end: cal.endOfDay($0)) }
        let movedIDs = Set(proposal.blocksToMove.map(\.id))
        var taken = context.flexibleBlocks.filter { !movedIDs.contains($0.id) }.map { DateInterval(start: $0.start, end: $0.end) }
        taken += proposal.items.compactMap { i in i.included ? i.start.flatMap { s in i.end.map { DateInterval(start: s, end: $0) } } : nil }
        var perDay: [Date: Int] = [:]
        for t in taken { perDay[cal.startOfDay(t.start), default: 0] += Int(t.duration / 60) }

        let order = proposal.items.indices.filter { proposal.items[$0].included && proposal.items[$0].start == nil }
            .sorted { a, b in
                let x = proposal.items[a], y = proposal.items[b]
                return (x.deadline ?? .distantFuture, x.kind == .catchUp ? 0 : 1) < (y.deadline ?? .distantFuture, y.kind == .catchUp ? 0 : 1)
            }
        let from = IntervalMath.roundUp5(context.now.addingTimeInterval(15 * 60))
        for i in order {
            let item = proposal.items[i]
            let horizon = item.deadline ?? cal.addingDays(14, to: from)
            let slot = firstSlot(minutes: item.minutes, from: from, to: horizon, finder: finder, context: context,
                                 blocked: restBlocks + taken, perDay: perDay)
                ?? firstSlot(minutes: item.minutes, from: max(from, horizon), to: cal.addingDays(7, to: max(from, horizon)),
                             finder: finder, context: context, blocked: restBlocks + taken, perDay: perDay)
            guard let slot else {
                proposal.warnings.append("No free time found for “\(item.title)”.")
                continue
            }
            if let d = item.deadline, slot.addingTimeInterval(TimeInterval(item.minutes * 60)) > d {
                proposal.warnings.append("“\(item.title)” doesn't fit before \(cal.format(d, "EEE HH:mm")); it's the earliest free slot after.")
            }
            proposal.items[i].start = slot
            taken.append(DateInterval(start: slot, duration: TimeInterval(item.minutes * 60)))
            perDay[cal.startOfDay(slot), default: 0] += item.minutes
        }
        proposal.items.sort { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    func firstSlot(minutes: Int, from: Date, to: Date, finder: FreeSlotFinder, context: PlannerContext,
                   blocked: [DateInterval], perDay: [Date: Int]) -> Date? {
        guard to > from else { return nil }
        for day in finder.freeSlots(from: from, to: to, events: context.events, blocked: blocked) where day.isWorkDay {
            guard perDay[day.day, default: 0] + minutes <= context.prefs.maxFocusMinutesPerDay else { continue }
            if let s = day.slots.first(where: { IntervalMath.minutes($0) >= minutes && $0.start.addingTimeInterval(TimeInterval(minutes * 60)) <= to }) {
                return s.start
            }
        }
        return nil
    }

    // MARK: Summary

    public func summary(_ p: PlanProposal, context: PlannerContext) -> String {
        let cal = context.calendar
        var lines: [String] = []
        for d in p.restDays {
            let day = cal.isSameDay(d, context.now) ? "today" : cal.format(d, "EEEE")
            let moved = p.blocksToMove.filter { cal.isSameDay($0.start, d) }.count
            lines.append("Keep \(day) free" + (moved > 0 ? " (moving \(moved) block\(moved == 1 ? "" : "s") off it)" : ""))
        }
        for i in p.items where i.included {
            let when = i.start.map { cal.format($0, "EEE HH:mm") } ?? "unscheduled"
            lines.append("\(when) · \(i.title) (\(DeferralAdvisor.hours(i.minutes)))")
        }
        guard !lines.isEmpty else { return "I couldn't find anything to plan in that." }
        return "Here's what I'll do:\n" + lines.map { "• " + $0 }.joined(separator: "\n")
    }

    // MARK: AI agent

    struct AgentStep: Decodable {
        let tool: String?
        let args: [String: JSONValue]?
        let intents: [AIIntent]?
    }

    struct AIIntent: Decodable {
        let kind: String
        let title: String?
        let date: String?
        let until: String?
        let deadline: String?
        let minutes: Int?
        let module: String?
        let quote: String?
    }

    static let systemPrompt = """
        You turn a university student's message into planning intents. The message may contain several \
        requests ("first of all… second… third…"). Split them.
        Intent kinds:
        "rest_day": they don't want to work on a day (date = that day).
        "type_up": type up notes for lectures in a period (date = period start, until = period end, deadline).
        "catch_up": they missed a lecture and need to go over it (date = when the lecture was, with the time if given, e.g. "835" = 08:35).
        "task": anything else (title, deadline, minutes).
        You can look things up first with tools, replying {"tool":"<name>","args":{…}}:
        - lectures(from, to): timetabled sessions with module and notes status
        - calendar(day): fixed events on a day
        - tasks(): open to-dos
        When done reply with ONLY {"intents":[{"kind":"catch_up","date":"2026-10-16T08:35","module":"ECM1400","quote":"…"}]}.
        Dates are local ISO 8601 (Europe/London). "last week" said on a weekend means the week that just ended.
        """

    func aiIntents(_ input: String, context: PlannerContext) async throws -> [PlannerIntent] {
        guard let router else { return [] }
        let cal = context.calendar
        var messages: [LLMMessage] = [.system(Self.systemPrompt),
                                      .user("Now: \(cal.format(context.now, "EEEE d MMMM yyyy HH:mm")).\nMessage: \(input)")]
        for step in 0..<maxToolSteps {
            let out = try await router.completeJSON(AgentStep.self, LLMRequest(messages: messages, purpose: purpose, json: true, temperature: 0.1))
            if let intents = out.intents {
                return intents.compactMap { toIntent($0, context: context) }
            }
            guard let tool = out.tool, step < maxToolSteps - 1 else { break }
            messages.append(.assistant(#"{"tool":"\#(tool)"}"#))
            messages.append(.user("Tool result for \(tool):\n\(runTool(tool, args: out.args ?? [:], context: context))"))
        }
        return []
    }

    func runTool(_ name: String, args: [String: JSONValue], context: PlannerContext) -> String {
        let cal = context.calendar
        func date(_ key: String) -> Date? {
            if case .string(let s)? = args[key] { return FlexibleDate.parse(s, timeZone: context.prefs.timeZone) }
            return nil
        }
        switch name {
        case "lectures":
            let from = date("from") ?? cal.addingDays(-14, to: context.now), to = date("to") ?? context.now
            let rows = context.lectures.filter { $0.start >= from && $0.start < to }.map {
                "\(cal.format($0.start, "yyyy-MM-dd'T'HH:mm")) \($0.moduleCode) \(context.moduleNames[$0.moduleCode] ?? "") \($0.kind.rawValue) \"\($0.title)\" notes=\($0.status.rawValue)"
            }
            return rows.isEmpty ? "none" : rows.joined(separator: "\n")
        case "calendar":
            let day = date("day") ?? context.now
            let rows = context.events.filter { cal.isSameDay($0.start, day) }.map { "\(cal.time($0.start))-\(cal.time($0.end)) \($0.title)" }
            return rows.isEmpty ? "free" : rows.joined(separator: "\n")
        case "tasks":
            let rows = context.tasks.filter { !$0.isDone }.map { "\($0.title)" + ($0.deadline.map { " due \(cal.format($0, "yyyy-MM-dd HH:mm"))" } ?? "") }
            return rows.isEmpty ? "none" : rows.joined(separator: "\n")
        default:
            return "error: no such tool (lectures, calendar, tasks)"
        }
    }

    func toIntent(_ a: AIIntent, context: PlannerContext) -> PlannerIntent? {
        guard let kind = PlannerIntent.Kind(rawValue: a.kind.lowercased()) else { return nil }
        let tz = context.prefs.timeZone
        func d(_ s: String?) -> Date? { s.flatMap { FlexibleDate.parse($0, timeZone: tz) ?? ISO8601.parse($0) } }
        return PlannerIntent(kind: kind, title: a.title, date: d(a.date), until: d(a.until), deadline: d(a.deadline),
                             minutes: a.minutes, moduleCode: a.module?.uppercased(), quote: a.quote)
    }

    // MARK: Revise

    public enum Edit: Hashable, Sendable {
        case move(itemID: String, to: Date, keepTime: Bool)
        case remove(itemID: String)
        case setMinutes(itemID: String, minutes: Int)
    }

    struct AIEdits: Decodable {
        struct E: Decodable { let op: String; let match: String?; let to: String?; let minutes: Int? }
        let edits: [E]
    }

    /// Applies a one-line reply ("move the stats one to Sunday", "drop the programming type-up").
    public func revise(_ proposal: PlanProposal, reply: String, context: PlannerContext) async -> (PlanProposal, [Edit]) {
        var edits: [Edit] = []
        if let router {
            let list = proposal.items.map { "\($0.id): \($0.title) @ \($0.start.map { context.calendar.format($0, "yyyy-MM-dd'T'HH:mm") } ?? "-")" }
            let prompt = """
                Plan items:\n\(list.joined(separator: "\n"))\nNow: \(context.calendar.format(context.now, "EEEE yyyy-MM-dd HH:mm"))\nUser: \(reply)
                Reply with ONLY {"edits":[{"op":"move|remove|minutes","match":"<item id>","to":"2026-10-18T14:00 or a day like 2026-10-18","minutes":30}]}
                """
            if let ai = try? await router.completeJSON(AIEdits.self, LLMRequest(messages: [.user(prompt)], purpose: purpose, json: true, temperature: 0)) {
                edits = ai.edits.compactMap { e in
                    guard let id = e.match.flatMap({ m in proposal.items.first { $0.id == m }?.id ?? PlannerRules.match(m, in: proposal.items, context: context) })
                    else { return nil }
                    switch e.op.lowercased() {
                    case "remove": return .remove(itemID: id)
                    case "minutes": return e.minutes.map { .setMinutes(itemID: id, minutes: $0) }
                    case "move":
                        guard let s = e.to, let d = FlexibleDate.parse(s, timeZone: context.prefs.timeZone) else { return nil }
                        return .move(itemID: id, to: d, keepTime: s.contains("T"))
                    default: return nil
                    }
                }
            }
        }
        if edits.isEmpty { edits = PlannerRules(context: context).edits(in: reply, items: proposal.items) }
        return (apply(edits, to: proposal, context: context), edits)
    }

    public func apply(_ edits: [Edit], to proposal: PlanProposal, context: PlannerContext) -> PlanProposal {
        var p = proposal
        let cal = context.calendar
        var reslot: [(Int, Date)] = []
        for e in edits {
            switch e {
            case .remove(let id):
                if let i = p.items.firstIndex(where: { $0.id == id }) { p.items[i].included = false }
            case .setMinutes(let id, let m):
                if let i = p.items.firstIndex(where: { $0.id == id }) { p.items[i].minutes = max(5, m) }
            case .move(let id, let to, let keepTime):
                guard let i = p.items.firstIndex(where: { $0.id == id }) else { continue }
                if keepTime { p.items[i].start = to } else { p.items[i].start = nil; reslot.append((i, cal.startOfDay(to))) }
            }
        }
        // Items moved to a day get the first free slot on that day.
        let finder = FreeSlotFinder(prefs: context.prefs)
        for (i, day) in reslot {
            let taken = p.items.enumerated().compactMap { j, it -> DateInterval? in
                guard j != i, it.included, let s = it.start else { return nil }
                return DateInterval(start: s, duration: TimeInterval(it.minutes * 60))
            }
            let from = max(day, context.now)
            p.items[i].start = firstSlot(minutes: p.items[i].minutes, from: from, to: cal.endOfDay(day), finder: finder,
                                         context: context, blocked: taken, perDay: [:])
            if p.items[i].start == nil { p.warnings.append("\(cal.format(day, "EEEE")) has no free slot for “\(p.items[i].title)”.") }
            if let d = p.items[i].deadline, let e = p.items[i].end, e > d {
                p.warnings.append("“\(p.items[i].title)” is now after its deadline.")
            }
        }
        p.items.sort { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
        p.summary = summary(p, context: context)
        return p
    }
}

// MARK: - Rule fallback

/// Understands the common phrasings without AI.
struct PlannerRules {
    var context: PlannerContext
    var cal: DayCalendar { context.calendar }

    static let splitter = PlanRegex(#"(?:\b(?:first(?:ly)?|second(?:ly)?|third(?:ly)?|fourth(?:ly)?|finally|also|and then|plus)\s*(?:of all)?\s*,?)|[.;\n]+"#)
    static let rest = PlanRegex(#"\b(?:(?:don'?t|do not|dont) want to (?:do )?(?:any )?work|no work|day off|rest day|not working|taking (?:the day|today|tomorrow) off)\b"#)
    static let typeUp = PlanRegex(#"\btyp(?:e|ing) (?:up|out)\b|\bwrite up\b"#)
    static let missed = PlanRegex(#"\b(?:(?:did ?n[o']?t|didnt|never) (?:go|make it) to|missed|skipped|slept through)\b"#)
    static let due = PlanRegex(#"\b(?:due|for|by|before)\s+(?:for\s+)?(today|tonight|tomorrow|mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)\b"#)
    static let onDay = PlanRegex(#"\b(?:on |last )?(yesterday|mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)\b"#)
    static let clock = PlanRegex(#"\b(?:at\s+)?(\d{1,2})[:.]?(\d{2})\s*(am|pm)?\b|\bat\s+(\d{1,2})\s*(am|pm)?\b"#)
    static let moduleCode = PlanRegex(#"\b([A-Z]{3}\d{4})\b"#, caseInsensitive: false)

    static let weekdays: [String: Int] = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]

    func intents(in input: String) -> [PlannerIntent] {
        let text = MessageText.clean(input)
        let parts = Self.splitter.regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "|")
            .split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 2 }
        var out: [PlannerIntent] = []
        for part in parts {
            let lower = part.lowercased()
            let code = Self.moduleCode.firstMatch(in: part)?.group(1)
            if Self.rest.contains(lower) {
                out.append(PlannerIntent(kind: .restDay, date: lower.contains("tomorrow") ? cal.addingDays(1, to: context.now) : context.now,
                                         quote: part))
            } else if Self.typeUp.contains(lower) {
                let (from, until) = period(lower)
                out.append(PlannerIntent(kind: .typeUp, date: from, until: until, deadline: deadline(lower),
                                         moduleCode: code, quote: part))
            } else if Self.missed.contains(lower) {
                out.append(PlannerIntent(kind: .catchUp, date: missedWhen(lower), deadline: deadline(lower),
                                         moduleCode: code, quote: part))
            } else {
                let q = QuickAddParser(now: context.now, timeZone: context.prefs.timeZone).parse(part)
                out.append(PlannerIntent(kind: .task, title: q.task.title, deadline: q.task.deadline,
                                         minutes: q.hasExplicitEstimate ? q.task.estimateMinutes : nil,
                                         moduleCode: q.task.moduleCode, quote: part))
            }
        }
        return out
    }

    /// "last week": the Mon–Sun week before this one; said on a weekend, the week that just ended.
    func period(_ s: String) -> (Date, Date) {
        let thisWeek = cal.startOfWeek(context.now)
        if s.contains("this week") { return (thisWeek, context.now) }
        let weekend = [1, 7].contains(cal.weekday(context.now))
        if s.contains("last week") || s.contains("past week") || s.contains("week") {
            return weekend && !s.contains("past week") ? (thisWeek, cal.addingDays(5, to: thisWeek))
                : (cal.addingDays(-7, to: thisWeek), thisWeek)
        }
        return (cal.addingDays(-7, to: context.now), context.now)
    }

    /// Next occurrence of the named day, at the start of the working day (work due "for Monday").
    func deadline(_ s: String) -> Date? {
        guard let word = Self.due.firstMatch(in: s)?.group(1) else { return nil }
        switch word {
        case "today", "tonight": return cal.date(minute: context.prefs.dayEnd, of: context.now)
        case "tomorrow": return cal.date(minute: context.prefs.dayStart + 60, of: cal.addingDays(1, to: context.now))
        default:
            guard let wd = Self.weekdays[String(word.prefix(3))] else { return nil }
            var ahead = (wd - cal.weekday(context.now) + 7) % 7
            if ahead == 0 { ahead = 7 }
            return cal.date(minute: context.prefs.dayStart + 60, of: cal.addingDays(ahead, to: context.now))
        }
    }

    /// Most recent past occurrence of the named day, with "835" / "8:35" / "at 9am" as the time.
    func missedWhen(_ s: String) -> Date? {
        var day: Date?
        if let word = Self.onDay.firstMatch(in: s)?.group(1) {
            if word == "yesterday" { day = cal.addingDays(-1, to: context.now) }
            else if let wd = Self.weekdays[String(word.prefix(3))] {
                var back = (cal.weekday(context.now) - wd + 7) % 7
                if back == 0 { back = 7 }
                day = cal.addingDays(-back, to: context.now)
            }
        }
        guard let day else { return nil }
        guard let m = Self.clock.firstMatch(in: s) else { return cal.startOfDay(day) }
        var hour: Int, minute = 0
        if let h = m.group(1).flatMap(Int.init), let mi = m.group(2).flatMap(Int.init) {
            hour = h; minute = mi
            if let ap = m.group(3) { hour = PlanTimeParser.apply(ap, to: hour) }
        } else if let h = m.group(4).flatMap(Int.init) {
            hour = m.group(5).map { PlanTimeParser.apply($0, to: h) } ?? h
        } else { return cal.startOfDay(day) }
        guard hour < 24, minute < 60 else { return cal.startOfDay(day) }
        return cal.date(minute: hour * 60 + minute, of: day)
    }

    // MARK: Edits

    static let moveEdit = PlanRegex(#"\b(?:move|put|shift|push|do)\s+(?:the\s+)?(.+?)(?:\s+one)?\s+(?:to|on|until)\s+(today|tomorrow|mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)\b"#)
    static let removeEdit = PlanRegex(#"\b(?:remove|drop|delete|skip|forget|no need for)\s+(?:the\s+)?(.+?)(?:\s+one)?\s*$"#)

    func edits(in reply: String, items: [ProposedItem]) -> [ConversationalPlanner.Edit] {
        var out: [ConversationalPlanner.Edit] = []
        for clause in reply.lowercased().split(whereSeparator: { ",;.".contains($0) }).map(String.init) {
            let c = clause.replacingOccurrences(of: " and ", with: " ").trimmingCharacters(in: .whitespaces)
            if let m = Self.moveEdit.firstMatch(in: c), let what = m.group(1), let day = m.group(2),
               let id = Self.match(what, in: items, context: context), let date = dayDate(day) {
                out.append(.move(itemID: id, to: date, keepTime: false))
            } else if let m = Self.removeEdit.firstMatch(in: c), let what = m.group(1),
                      let id = Self.match(what, in: items, context: context) {
                out.append(.remove(itemID: id))
            }
        }
        return out
    }

    func dayDate(_ word: String) -> Date? {
        if word == "today" { return context.now }
        if word == "tomorrow" { return cal.addingDays(1, to: context.now) }
        guard let wd = Self.weekdays[String(word.prefix(3))] else { return nil }
        let ahead = (wd - cal.weekday(context.now) + 7) % 7
        return cal.addingDays(ahead, to: context.now)
    }

    /// The item whose title / module best matches "stats", "the programming type-up", "ECM1400"…
    static func match(_ phrase: String, in items: [ProposedItem], context: PlannerContext) -> String? {
        let words = phrase.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { !["the", "a", "one", "my", "that", "this", "up", "type", "typeup", "lecture", "thing"].contains($0) }
        guard !words.isEmpty else { return nil }
        func haystack(_ i: ProposedItem) -> [String] {
            let extra = [i.moduleCode, i.moduleCode.flatMap { context.moduleNames[$0] }, i.detail].compactMap { $0 }.joined(separator: " ")
            return (i.title + " " + extra).lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        let scored = items.map { item -> (String, Int) in
            let hay = haystack(item)
            // "stats" ≈ "statistics", "prog" ≈ "programming", "micro" ≈ "microeconomics".
            let score = words.filter { w in hay.contains { $0.hasPrefix(w) || $0.commonPrefix(with: w).count >= 4 } }.count
            return (item.id, score)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }
}
