import Foundation

/// What the assistant can see of the student's courses. Separate from
/// `OrbitDataSource` so existing implementations keep compiling; the app's
/// `StoreDataSource` implements both.
public protocol AcademicDataSource: Sendable {
    /// Everything indexed about the courses (empty where not available, e.g. on the iPhone).
    func courseKnowledge() async -> CourseKnowledgeBase
    func lectureReviews() async -> [LectureReview]
    func tasks() async -> [OrbitTask]
    /// Embeds queries for semantic search (nil = keyword search only).
    func noteEmbedder() async -> NoteEmbedder?
    /// Runs (or refreshes) the notes-vs-slides review for a module week on demand.
    func runLectureReview(module: String, week: Int) async -> LectureReview?
}

public extension AcademicDataSource {
    func noteEmbedder() async -> NoteEmbedder? { nil }
    func runLectureReview(module: String, week: Int) async -> LectureReview? { nil }
}

/// Chat tools over the course knowledge base: this week, search, modules, weeks,
/// homework, lecture reviews, reading a resource, ELE activity and feedback themes.
public enum AcademicTools {
    public static func make(_ data: AcademicDataSource, timeZone: TimeZone = TimeZone(identifier: "Europe/London")!,
                            now: @escaping @Sendable () -> Date = { Date() }) -> [AssistantTool] {
        [
            AssistantTool(
                name: "whats_happening",
                description: "This teaching week and next across all modules: lectures/tutorials, ELE topics, readings, homework and assessments due. Pass module to focus on one.",
                arguments: ["module": "module code or name (optional)", "week": "'this', 'next' or a week number (optional)"]
            ) { args in
                let kb = await data.courseKnowledge()
                guard !kb.isEmpty else { return "Nothing synced from ELE yet." }
                let happening = kb.whatsHappening(now: now())
                if let m = args["module"]?.string, let code = resolveModule(m, kb) {
                    let week = weekArg(args["week"], happening: happening)
                    guard let w = week else { return "No teaching week at the moment." }
                    return kb.weekOverview(module: code, week: w.week, term: w.term)?.text(timeZone: timeZone) ?? "Nothing for \(code)."
                }
                if let n = args["week"]?.int {
                    let term = (happening.currentWeek ?? happening.nextWeek)?.term
                    let all = kb.modules.keys.sorted().compactMap { code -> WeekOverview? in
                        let t = kb.modules[code]?.term
                        guard t == nil || term == nil || t == term else { return nil }
                        return kb.weekOverview(module: code, week: n, term: term)
                    }.filter { !$0.isEmpty }
                    return all.isEmpty ? "Nothing on ELE for week \(n) yet." : all.map { $0.text(timeZone: timeZone) }.joined(separator: "\n\n")
                }
                return happening.text(calendar: kb.calendar)
            },
            AssistantTool(
                name: "course_search",
                description: "Search everything from ELE and the notes: slides, handouts, problem sheets, briefs, reading guides, past papers, announcements, feedback and lecture notes.",
                arguments: ["query": "string", "module": "code (optional)", "week": "number (optional)",
                            "kind": "slides|handout|homework|assessmentBrief|readingGuide|pastPaper|lectureNotes|announcement|feedback (optional)"]
            ) { args in
                let kb = await data.courseKnowledge()
                let query = args["query"]?.string ?? ""
                guard !query.isEmpty else { return "error: give a query" }
                let code = args["module"]?.string.flatMap { resolveModule($0, kb) }
                let kinds = args["kind"]?.string.flatMap(CourseDocKind.init(rawValue:)).map { Set([$0]) }
                let hits: [KBHit]
                if let e = await data.noteEmbedder() {
                    hits = await kb.search(query, moduleCode: code, week: args["week"]?.int, kinds: kinds, limit: 6, embedder: e)
                } else {
                    hits = kb.search(query, moduleCode: code, week: args["week"]?.int, kinds: kinds, limit: 6)
                }
                if hits.isEmpty { return "Nothing found for '\(query)'." }
                return hits.map { "[\($0.citation)] (id \($0.document.id))\n\($0.snippet)" }.joined(separator: "\n---\n")
            },
            AssistantTool(
                name: "module_overview",
                description: "One module: its weeks and topics, assessments (weights, deadlines), homework and what's indexed.",
                arguments: ["module": "code or name"]
            ) { args in
                let kb = await data.courseKnowledge()
                guard let code = args["module"]?.string.flatMap({ resolveModule($0, kb) }) else {
                    return "Which module? Known: \(kb.modules.keys.sorted().joined(separator: ", "))."
                }
                var text = kb.moduleOverview(module: code)?.text(timeZone: timeZone) ?? "No data for \(code)."
                let reminders = kb.feedbackReminders(moduleCode: code)
                if !reminders.isEmpty { text += "\nFeedback to remember:\n" + reminders.map { "  \($0)" }.joined(separator: "\n") }
                return text
            },
            AssistantTool(
                name: "week_materials",
                description: "What's on ELE for a module's week: slides, handouts, sheets, readings, with ids for read_resource.",
                arguments: ["module": "code or name", "week": "number"]
            ) { args in
                let kb = await data.courseKnowledge()
                guard let code = args["module"]?.string.flatMap({ resolveModule($0, kb) }), let week = args["week"]?.int else {
                    return "error: need module and week"
                }
                var lines: [String] = []
                if let o = kb.weekOverview(module: code, week: week) { lines.append(o.text(timeZone: timeZone)) }
                let docs = kb.materials(for: code, week: week)
                if !docs.isEmpty { lines.append("Files:") }
                lines += docs.map { "- \($0.title) (\($0.kind.label), id \($0.id), \($0.text.count) chars)" }
                return lines.isEmpty ? "Nothing on ELE for \(code) week \(week) yet." : lines.joined(separator: "\n")
            },
            AssistantTool(
                name: "homework",
                description: "Homework, problem sheets, quizzes, tests and lecture prep found on ELE across all modules, with due dates and status.",
                arguments: ["module": "code (optional)", "include_done": "bool (optional)"]
            ) { args in
                let kb = await data.courseKnowledge()
                let tasks = Dictionary(await data.tasks().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let code = args["module"]?.string.flatMap { resolveModule($0, kb) }
                let fmt = KBFormat(timeZone: timeZone)
                let t = now()
                let items = kb.homework.filter { code == nil || $0.moduleCode == code }
                    .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                let lines: [String] = items.compactMap { h in
                    let task = tasks[h.taskID]
                    let done = task?.isDone ?? false
                    if done && args["include_done"]?.bool != true { return nil }
                    let status = done ? "done" : (h.due.map { $0 < t ? "overdue" : "to do" } ?? "to do")
                    var s = "- \(h.moduleCode) \(h.kind.label): \(h.title)"
                    if let d = h.due { s += " — due \(fmt.dayTime(d))\(h.dueSource == .assumed ? " (assumed)" : "")" }
                    s += " [\(status)]"
                    if let q = h.questionCount { s += " · \(q) questions" }
                    s += " · ~\(h.estimateMinutes)m"
                    return s
                }
                return lines.isEmpty ? "No homework found on ELE." : lines.joined(separator: "\n")
            },
            AssistantTool(
                name: "lecture_review",
                description: "Compares the student's notes for a module week with the lecture slides: topics they may have missed (with slide numbers) and answers to questions they wrote in their notes.",
                arguments: ["module": "code or name", "week": "number (optional; latest if omitted)"]
            ) { args in
                let kb = await data.courseKnowledge()
                guard let code = args["module"]?.string.flatMap({ resolveModule($0, kb) }) else { return "error: need a module" }
                var reviews = await data.lectureReviews().filter { $0.moduleCode == code }
                if let week = args["week"]?.int {
                    reviews = reviews.filter { $0.week == week }
                    if reviews.isEmpty, let fresh = await data.runLectureReview(module: code, week: week) { reviews = [fresh] }
                }
                guard !reviews.isEmpty else { return "No review yet for \(code)\(args["week"]?.int.map { " week \($0)" } ?? "") (needs notes and slides)." }
                return reviews.sorted { ($0.week ?? 0) > ($1.week ?? 0) }.prefix(args["week"] == nil ? 2 : 1)
                    .map { $0.text() }.joined(separator: "\n\n")
            },
            AssistantTool(
                name: "read_resource",
                description: "The text of one ELE resource or note (slides, sheet, brief…) by id or name. Use after course_search/week_materials.",
                arguments: ["name": "id or title", "module": "code (optional)", "offset": "character offset (optional)"]
            ) { args in
                let kb = await data.courseKnowledge()
                let name = args["name"]?.string ?? args["id"]?.string ?? ""
                let code = args["module"]?.string.flatMap { resolveModule($0, kb) }
                guard let doc = kb.document(named: name, moduleCode: code) else { return "No resource matching '\(name)'." }
                let offset = max(0, min(doc.text.count, args["offset"]?.int ?? 0))
                let body = doc.text.dropFirst(offset).prefix(5000)
                let more = doc.text.count > offset + body.count ? "\n… (\(doc.text.count - offset - body.count) more characters; pass offset \(offset + body.count))" : ""
                return "\(doc.info.citation)\(doc.url.map { "\n\($0)" } ?? "")\n\n\(body)\(more)"
            },
            AssistantTool(
                name: "ele_activity",
                description: "What's new on ELE: new files, announcements, forum posts, grades, feedback, notifications and messages.",
                arguments: ["since": "ISO date or e.g. '3 days' (optional, default 7 days)", "module": "code (optional)"]
            ) { args in
                let kb = await data.courseKnowledge()
                let since = sinceArg(args["since"], now: now(), timeZone: timeZone)
                let code = args["module"]?.string.flatMap { resolveModule($0, kb) }
                let items = kb.activity.recent(since: since, moduleCode: code, limit: 40)
                if items.isEmpty { return "Nothing new on ELE since \(KBFormat(timeZone: timeZone).dayTime(since))." }
                let fmt = KBFormat(timeZone: timeZone)
                return items.map { "\(fmt.dayTime($0.date)) \($0.line)" }.joined(separator: "\n")
            },
            AssistantTool(
                name: "feedback_themes",
                description: "Recurring marker feedback per module (what to fix next time). Use when planning or starting an assessment.",
                arguments: ["module": "code (optional)"]
            ) { args in
                let kb = await data.courseKnowledge()
                let code = args["module"]?.string.flatMap { resolveModule($0, kb) }
                let records = kb.feedback.themes.filter { code == nil || $0.modules.contains(code!) }
                guard !records.isEmpty else { return "No marked feedback yet." }
                var lines = records.map { r in
                    "• \(r.label): needs work ×\(r.needsWorkCount), praised ×\(r.praisedCount) (\(r.modules.joined(separator: ", ")); last: \(r.lastAssessment))"
                        + (r.examples.first.map { " — “\($0)”" } ?? "")
                }
                if let code { lines += kb.feedbackReminders(moduleCode: code) }
                return lines.joined(separator: "\n")
            },
        ]
    }

    /// A few lines for the assistant's system prompt: the academic week, this week's
    /// topics and what's due, recent ELE activity and relevant feedback themes.
    public static func context(_ kb: CourseKnowledgeBase, reviews: [LectureReview] = [], now: Date = Date()) -> String {
        let cal = kb.calendar
        var lines: [String] = []
        if kb.isEmpty {
            if let w = cal.week(for: now) { lines.append("Academic week: \(cal.describe(w)).") }
            return lines.joined(separator: "\n")
        }
        let happening = kb.whatsHappening(now: now)
        let compact = happening.compact(calendar: cal)
        if !compact.isEmpty { lines.append(compact) }
        let fresh = kb.activity.recent(since: now.addingTimeInterval(-2 * 86400), limit: 50)
        if !fresh.isEmpty {
            lines.append("New on ELE in the last 2 days: \(fresh.count) item(s), e.g. " + fresh.prefix(3).map { $0.title }.joined(separator: "; ") + ".")
        }
        let dueModules = Set(happening.dueSoon.map(\.moduleCode))
        for code in dueModules.sorted() {
            if let r = kb.feedbackReminders(moduleCode: code, limit: 1).first { lines.append("\(code): \(r)") }
        }
        let missed = reviews.filter { !$0.missed.isEmpty && $0.updatedAt > now.addingTimeInterval(-7 * 86400) }.count
        if missed > 0 { lines.append("\(missed) recent lecture(s) have notes that miss slide content (see lecture_review).") }
        lines.append("Use whats_happening, course_search, week_materials, homework, lecture_review, read_resource and ele_activity for course questions.")
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    /// "bee1022", "BEE 1022", "stats" → "BEE1022".
    static func resolveModule(_ s: String, _ kb: CourseKnowledgeBase) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let code = ModuleCode.find(in: t.uppercased().replacingOccurrences(of: " ", with: "")) { return code }
        let lower = t.lowercased()
        guard lower.count >= 3 else { return nil }
        let terms = Set(NoteIndex.terms(lower))
        return kb.modules.values.map { m -> (String, Int) in
            let name = m.name.lowercased()
            var score = name.contains(lower) ? 10 : 0
            score += Set(NoteIndex.terms(name)).intersection(terms).count
            if lower.hasPrefix("stat") && name.contains("statistic") { score += 5 }
            if (lower.hasPrefix("econ") || lower.contains("micro") || lower.contains("macro")) && name.contains(lower.prefix(5)) { score += 3 }
            return (m.code, score)
        }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }

    static func weekArg(_ v: JSONValue?, happening: WhatsHappening) -> AcademicWeek? {
        if let n = v?.int, let w = happening.currentWeek ?? happening.nextWeek {
            return AcademicCalendar.exeter.academicWeek(term: w.term, week: n) ?? AcademicWeek(term: w.term, week: n, start: w.start)
        }
        if v?.string?.lowercased() == "next" { return happening.nextWeek }
        return happening.currentWeek ?? happening.nextWeek
    }

    static func sinceArg(_ v: JSONValue?, now: Date, timeZone: TimeZone) -> Date {
        guard let s = v?.string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return now.addingTimeInterval(-7 * 86400) }
        if let d = ISO8601.parse(s) ?? FlexibleDate.parse(s, timeZone: timeZone) { return d }
        if let m = UniRegex.first("(\\d+)\\s*(hour|day|week)", in: s), let n = m[1].flatMap(Double.init) {
            let unit: Double = (m[2] ?? "day").lowercased().hasPrefix("hour") ? 3600 : (m[2] ?? "").lowercased().hasPrefix("week") ? 7 * 86400 : 86400
            return now.addingTimeInterval(-n * unit)
        }
        if s.lowercased().contains("yesterday") { return now.addingTimeInterval(-86400) }
        if s.lowercased().contains("week") { return now.addingTimeInterval(-7 * 86400) }
        return now.addingTimeInterval(-7 * 86400)
    }
}
