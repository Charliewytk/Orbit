import Foundation

/// What the assistant can see and do. The app implements this on top of its
/// store and services; tests use an in-memory version.
public protocol OrbitDataSource: Sendable {
    func tasks() async -> [OrbitTask]
    func events(from: Date, to: Date) async -> [CalendarEvent]
    func blocks(from: Date, to: Date) async -> [ScheduledBlock]
    func assessments() async -> [Assessment]
    func emails(limit: Int, category: EmailCategory?) async -> [EmailDigest]
    /// Returns short snippets with note titles.
    func searchNotes(_ query: String, moduleCode: String?, limit: Int) async -> [String]
    func addTask(_ task: OrbitTask) async throws
    func completeTask(id: UUID) async throws
    func addEvent(_ event: CalendarEvent) async throws
    func replan() async throws -> SchedulePlan
    func lighten(day: Date, fraction: Double) async throws -> SchedulePlan
}

/// The default tool set built on an `OrbitDataSource`.
public enum StandardTools {
    public static func make(_ data: OrbitDataSource, timeZone: TimeZone = TimeZone(identifier: "Europe/London")!,
                            now: @escaping @Sendable () -> Date = { Date() }) -> [AssistantTool] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let fmt = Formatter(timeZone: timeZone)

        func day(_ v: JSONValue?) -> Date {
            if let s = v?.string {
                if let d = ISO8601.parse(s) ?? FlexibleDate.parse(s, timeZone: timeZone) { return cal.startOfDay(for: d) }
                if let m = DateExtractor(now: now(), timeZone: timeZone).extract(from: s).first { return cal.startOfDay(for: m.date) }
            }
            return cal.startOfDay(for: now())
        }

        func date(_ v: JSONValue?) -> Date? {
            guard let s = v?.string else { return nil }
            return ISO8601.parse(s) ?? FlexibleDate.parse(s, timeZone: timeZone)
                ?? DateExtractor(now: now(), timeZone: timeZone).extract(from: s).first?.date
        }

        return [
            AssistantTool(
                name: "get_schedule",
                description: "Events and planned work blocks for a day or range.",
                arguments: ["date": "ISO date or 'today'/'tomorrow' (optional)", "days": "number of days, default 1"]
            ) { args in
                let start = day(args["date"])
                let days = max(1, min(14, args["days"]?.int ?? 1))
                let end = cal.date(byAdding: .day, value: days, to: start)!
                let events = await data.events(from: start, to: end)
                let blocks = await data.blocks(from: start, to: end)
                var lines: [(Date, String)] = events.map { ($0.start, "\(fmt.range($0.start, $0.end, allDay: $0.isAllDay)) \($0.title)\($0.location.map { " @ \($0)" } ?? "")") }
                lines += blocks.map { ($0.start, "\(fmt.range($0.start, $0.end)) [Orbit] \($0.title)") }
                if lines.isEmpty { return "Nothing scheduled." }
                return lines.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")
            },
            AssistantTool(
                name: "list_tasks",
                description: "Open to-dos, most urgent first.",
                arguments: ["module": "module code filter (optional)", "include_done": "bool (optional)"]
            ) { args in
                var tasks = await data.tasks()
                if args["include_done"]?.bool != true { tasks = tasks.filter { !$0.isDone } }
                if let m = args["module"]?.string?.uppercased() { tasks = tasks.filter { $0.moduleCode == m } }
                let ranked = TaskScorer().rank(tasks, now: now())
                if ranked.isEmpty { return "No open tasks." }
                return ranked.prefix(25).map { t in
                    var s = "- \(t.title) (\(t.remainingMinutes)m"
                    if let d = t.deadline { s += ", due \(fmt.dayTime(d))" }
                    if let m = t.moduleCode { s += ", \(m)" }
                    return s + ")\(t.isDone ? " ✓" : "")"
                }.joined(separator: "\n")
            },
            AssistantTool(
                name: "add_task",
                description: "Add a to-do. Pass natural language in 'text' (e.g. 'essay plan BEM2031 2h before Friday') or explicit fields.",
                arguments: ["text": "natural language description", "title": "string (optional)",
                            "minutes": "estimate (optional)", "deadline": "ISO datetime (optional)", "module": "code (optional)"],
                mutates: true
            ) { args in
                let text = args["text"]?.string ?? args["title"]?.string ?? ""
                guard !text.isEmpty else { return "error: give text or title" }
                var task = QuickAddParser(now: now(), timeZone: timeZone).parse(text).task
                task.source = .assistant
                if let t = args["title"]?.string { task.title = t }
                if let m = args["minutes"]?.int { task.estimateMinutes = m }
                if let d = date(args["deadline"]) { task.deadline = d }
                if let m = args["module"]?.string { task.moduleCode = m.uppercased() }
                try await data.addTask(task)
                return "Added '\(task.title)' (\(task.estimateMinutes)m\(task.deadline.map { ", due \(fmt.dayTime($0))" } ?? ""))."
            },
            AssistantTool(
                name: "complete_task",
                description: "Mark a to-do done by (part of) its title.",
                arguments: ["title": "string"],
                mutates: true
            ) { args in
                let q = (args["title"]?.string ?? "").lowercased()
                let open = await data.tasks().filter { !$0.isDone }
                guard let t = open.first(where: { $0.title.lowercased() == q }) ?? open.first(where: { $0.title.lowercased().contains(q) }) else {
                    return "No open task matching '\(q)'."
                }
                try await data.completeTask(id: t.id)
                return "Marked '\(t.title)' done."
            },
            AssistantTool(
                name: "add_event",
                description: "Put a fixed event (plan, meeting) on the calendar.",
                arguments: ["title": "string", "start": "ISO datetime", "end": "ISO datetime (optional)", "location": "string (optional)"],
                mutates: true
            ) { args in
                guard let title = args["title"]?.string, let start = date(args["start"]) else { return "error: need title and start" }
                let end = date(args["end"]) ?? start.addingTimeInterval(3600)
                try await data.addEvent(CalendarEvent(title: title, start: start, end: end, location: args["location"]?.string,
                                                      calendarID: "orbit", source: .orbit))
                return "Added \(title) on \(fmt.range(start, end))."
            },
            AssistantTool(
                name: "replan",
                description: "Re-run the smart scheduler over the next two weeks.",
                mutates: true
            ) { _ in
                summarise(try await data.replan(), fmt)
            },
            AssistantTool(
                name: "lighten_day",
                description: "Reduce the workload on a day and push the rest later (e.g. when tired).",
                arguments: ["date": "ISO date or 'today'", "fraction": "0-1, how much to remove (default 0.5)"],
                mutates: true
            ) { args in
                summarise(try await data.lighten(day: day(args["date"]), fraction: args["fraction"]?.double ?? 0.5), fmt)
            },
            AssistantTool(
                name: "deadlines",
                description: "Upcoming assessments and task deadlines.",
                arguments: ["days": "look-ahead in days (default 21)"]
            ) { args in
                let until = now().addingTimeInterval(Double(args["days"]?.int ?? 21) * 86400)
                var items: [(Date, String)] = await data.assessments().compactMap { a in
                    guard let d = a.due, d >= now(), d <= until, !a.submitted else { return nil }
                    return (d, "\(a.moduleCode) \(a.title) (\(Int(a.weightPercent))%): \(fmt.dayTime(d))")
                }
                items += await data.tasks().compactMap { t in
                    guard let d = t.deadline, !t.isDone, d >= now(), d <= until else { return nil }
                    return (d, "Task: \(t.title): \(fmt.dayTime(d))")
                }
                return items.isEmpty ? "No deadlines in that window." : items.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")
            },
            AssistantTool(
                name: "inbox",
                description: "Important recent emails (Gmail + Exeter), already sorted.",
                arguments: ["category": "urgent|needsReply|hasDate|uni (optional)", "limit": "default 10"]
            ) { args in
                let cat = args["category"]?.string.flatMap(EmailCategory.init(rawValue:))
                let mails = await data.emails(limit: args["limit"]?.int ?? 10, category: cat)
                if mails.isEmpty { return "No matching emails." }
                return mails.map { "\($0.category.emoji) [\($0.account.rawValue)] \($0.from): \($0.subject) · \($0.summary)" }.joined(separator: "\n")
            },
            AssistantTool(
                name: "search_notes",
                description: "Search lecture notes (typed and handwritten).",
                arguments: ["query": "string", "module": "code (optional)"]
            ) { args in
                let hits = await data.searchNotes(args["query"]?.string ?? "", moduleCode: args["module"]?.string?.uppercased(), limit: 6)
                return hits.isEmpty ? "No notes found." : hits.joined(separator: "\n---\n")
            },
        ]
    }

    static func summarise(_ plan: SchedulePlan, _ fmt: Formatter) -> String {
        var s = "Planned \(plan.blocks.count) blocks."
        let next = plan.blocks.sorted { $0.start < $1.start }.prefix(8)
        if !next.isEmpty { s += "\n" + next.map { "\(fmt.range($0.start, $0.end)) \($0.title)" }.joined(separator: "\n") }
        if !plan.unscheduled.isEmpty { s += "\nCouldn't fit: " + plan.unscheduled.map { "\($0.task.title) (\($0.reason))" }.joined(separator: "; ") }
        if !plan.warnings.isEmpty { s += "\nWarnings: " + plan.warnings.joined(separator: "; ") }
        return s
    }

    struct Formatter: Sendable {
        let timeZone: TimeZone
        private func f(_ format: String) -> DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_GB"); f.timeZone = timeZone; f.dateFormat = format
            return f
        }
        func dayTime(_ d: Date) -> String { f("EEE d MMM HH:mm").string(from: d) }
        func range(_ a: Date, _ b: Date, allDay: Bool = false) -> String {
            allDay ? f("EEE d MMM").string(from: a) + " (all day)" : f("EEE d MMM HH:mm").string(from: a) + "–" + f("HH:mm").string(from: b)
        }
    }
}
