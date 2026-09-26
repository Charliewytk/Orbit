import Foundation

/// A piece of set work found on ELE: a problem sheet, exercise sheet, quiz,
/// formative test, or lecture prep ("read X before the week 3 lecture").
public struct HomeworkItem: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case homework, problemSet, exerciseSheet, worksheet, tutorialSheet, quiz, test, mock, formative, prep

        public var label: String {
            switch self {
            case .homework: "Homework"
            case .problemSet: "Problem set"
            case .exerciseSheet: "Exercise sheet"
            case .worksheet: "Worksheet"
            case .tutorialSheet: "Tutorial sheet"
            case .quiz: "Quiz"
            case .test: "Test"
            case .mock: "Mock"
            case .formative: "Formative"
            case .prep: "Prep"
            }
        }
    }

    /// Where the due date came from.
    public enum DueSource: String, Codable, Sendable {
        /// A stated date ("due 2 October 5pm").
        case explicit
        /// A teaching-week phrase ("end of week 2").
        case academicWeek
        /// ELE's own deadline (quiz close / assignment due).
        case ele
        /// Not stated: assumed the end of the week it was set in.
        case assumed
        case none
    }

    /// Stable across syncs: "hw-BEE1022-cm12345" or "hw-BEE1022-<hash>".
    public var id: String
    public var moduleCode: String
    public var title: String
    public var kind: Kind
    public var term: Int?
    /// The teaching week it was set in.
    public var week: Int?
    public var due: Date?
    public var dueText: String?
    public var dueSource: DueSource
    public var url: String?
    public var cmid: Int?
    /// What's asked, in a sentence or two.
    public var summary: String
    public var questionCount: Int?
    public var estimateMinutes: Int
    public var formative: Bool

    public init(id: String, moduleCode: String, title: String, kind: Kind, term: Int? = nil, week: Int? = nil,
                due: Date? = nil, dueText: String? = nil, dueSource: DueSource = .none, url: String? = nil,
                cmid: Int? = nil, summary: String = "", questionCount: Int? = nil, estimateMinutes: Int = 60,
                formative: Bool = true) {
        self.id = id; self.moduleCode = moduleCode; self.title = title; self.kind = kind; self.term = term
        self.week = week; self.due = due; self.dueText = dueText; self.dueSource = dueSource; self.url = url
        self.cmid = cmid; self.summary = summary; self.questionCount = questionCount
        self.estimateMinutes = estimateMinutes; self.formative = formative
    }

    /// The OrbitTask id for this item (deterministic, so re-syncs update rather than duplicate).
    public var taskID: UUID { StableID.uuid("orbit-homework|\(id)") }
}

/// Deterministic UUIDs from strings.
public enum StableID {
    public static func uuid(_ key: String) -> UUID {
        var h = Array(MD5.hex(key))
        // Version 3 (name-based, MD5) and RFC 4122 variant bits.
        h[12] = "3"
        let variant: [Character] = ["8", "9", "a", "b"]
        h[16] = variant[Int(String(h[16]), radix: 16).map { $0 % 4 } ?? 0]
        let s = String(h)
        let parts = [s.prefix(8), s.dropFirst(8).prefix(4), s.dropFirst(12).prefix(4), s.dropFirst(16).prefix(4), s.dropFirst(20).prefix(12)]
        return UUID(uuidString: parts.map(String.init).joined(separator: "-")) ?? UUID()
    }
}

/// Finds homework, problem sets, quizzes and tests across all modules from ELE
/// items and resource text, resolves due dates with the teaching calendar, and
/// turns them into to-dos.
public struct HomeworkDetector: Sendable {
    public var calendar: AcademicCalendar
    public var now: Date

    public init(calendar: AcademicCalendar = .exeter, now: Date = Date()) {
        self.calendar = calendar; self.now = now
    }

    // MARK: Keywords

    static let keywordPattern =
        "\\b(hw\\d*|homework|home\\s*work|problem\\s*(?:set|sheet)s?|p\\.?\\s*set|exercise\\s*sheets?|exercises|worksheets?|work\\s*sheets?|"
        + "tutorial\\s*(?:sheet|questions|exercises|problems)|seminar\\s*(?:questions|tasks|prep(?:aration)?)|question\\s*sheets?|"
        + "practice\\s*(?:questions|problems|sheet)|quiz(?:zes)?|class\\s*test|online\\s*test|mock|formative|"
        + "stats?\\s*sheet|problem\\s*class)\\b"

    /// True when a name reads like set work ("HW stats sheet", "Problem Set 2", "Week 3 quiz").
    public static func looksLikeHomework(_ name: String) -> Bool {
        let n = name.lowercased()
        if UniRegex.first("\\b(solutions?|answers?|model\\s+answers?|worked\\s+solutions?|feedback|marking|past\\s+paper|exemplar)\\b", in: n) != nil {
            return false
        }
        return UniRegex.first(keywordPattern, in: n) != nil || UniRegex.first("\\btest\\b", in: n) != nil
    }

    static func isSolutions(_ name: String) -> Bool {
        UniRegex.first("\\b(solutions?|answers?|worked\\s+solutions?|mark\\s*scheme)\\b", in: name) != nil
    }

    static func kind(of text: String) -> HomeworkItem.Kind {
        let t = text.lowercased()
        func has(_ p: String) -> Bool { UniRegex.first(p, in: t) != nil }
        if has("\\bmock\\b") { return .mock }
        if has("\\bquiz") { return .quiz }
        if has("\\b(class|online|progress)\\s*test\\b|\\btest\\s*\\d") { return .test }
        if has("problem\\s*(set|sheet)|p\\.?\\s*set") { return .problemSet }
        if has("exercise") { return .exerciseSheet }
        if has("tutorial|seminar") { return .tutorialSheet }
        if has("work\\s*sheet") { return .worksheet }
        if has("\\bhw\\d*\\b|homework|home\\s*work|stats?\\s*sheet") { return .homework }
        if has("formative") { return .formative }
        if has("\\btest\\b") { return .test }
        return .homework
    }

    // MARK: Detection

    /// Items from one module's course page. `texts` maps cmid → extracted document text.
    public func detect(content: ELEWebCourseContent, moduleTerm: Int? = nil, texts: [Int: String] = [:],
                       events: [ELEWebEvent] = []) -> [HomeworkItem] {
        let code = content.moduleCode
        let term = moduleTerm ?? calendar.inferTerm(for: content.sections) ?? 1
        var found: [HomeworkItem] = []
        for s in content.sections where s.kind != .pastPapers && s.kind != .exemplars && s.kind != .recordings {
            let week = s.kind == .week ? s.week : nil
            let reference = week.flatMap { calendar.weekStart(term: term, week: $0) } ?? now
            // Labels and section summaries: one line at a time.
            let lines = ([s.summary] + s.items.filter { $0.kind == .label }.map(\.text))
                .flatMap { $0.components(separatedBy: .newlines) }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for line in lines {
                if let prep = prepItem(line: line, code: code, term: term, week: week, reference: reference, url: s.url) { found.append(prep); continue }
                guard Self.looksLikeHomework(line), line.count <= 400,
                      !Self.isSolutions(line) else { continue }
                // A plain "Quiz" heading with nothing else isn't set work.
                guard line.split(separator: " ").count >= 2 else { continue }
                found.append(item(name: Self.titleFromLine(line), context: line, text: nil, code: code, term: term, week: week,
                                  reference: reference, url: s.url, cmid: nil))
            }
            for it in s.items where it.kind != .label && it.kind != .forum && it.role != .recording && it.role != .pastPaper
                && it.role != .exemplar && it.role != .readingList {
                let isQuiz = it.kind == .quiz
                let isSet = isQuiz || Self.looksLikeHomework(it.name) || (it.role == .tutorial && it.kind != .page)
                guard isSet, !Self.isSolutions(it.name) else { continue }
                // Summative assessments are planned from the assessment table instead.
                if s.kind == .assessment && !AssessmentParsing.isFormative(it.name + " " + it.text) && !isQuiz { continue }
                var h = item(name: it.name, context: [it.text, s.summary].joined(separator: "\n"), text: it.cmid.flatMap { texts[$0] },
                             code: code, term: term, week: week, reference: reference, url: it.url, cmid: it.cmid)
                if isQuiz {
                    let k = Self.kind(of: it.name)
                    h.kind = k == .test || k == .mock ? k : .quiz
                }
                if let cmid = it.cmid, let e = events.first(where: { $0.url?.contains("id=\(cmid)") ?? false }) {
                    h.due = e.timesort; h.dueSource = .ele; h.dueText = "ELE deadline"
                }
                found.append(h)
            }
        }
        return Self.merge(found)
    }

    /// All modules in a snapshot.
    public func detect(snapshot: ELEWebSnapshot, texts: [Int: String] = [:], moduleTerms: [String: Int] = [:]) -> [HomeworkItem] {
        snapshot.contents.keys.sorted().flatMap { code in
            detect(content: snapshot.contents[code]!, moduleTerm: moduleTerms[code], texts: texts, events: snapshot.events)
        }
    }

    /// "HW stats sheet – due end of week 2" → "HW stats sheet".
    static func titleFromLine(_ line: String) -> String {
        var t = line
        for p in ["\\s*[-–—:,(]?\\s*(?:is\\s+)?(?:due|deadline|submit|to\\s+be\\s+(?:submitted|completed|handed\\s+in)|hand\\s+in|complete\\s+by|by)\\b.*$"] {
            t = UniRegex.replace(p, in: t, with: "")
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " •-–—:.").union(.whitespaces))
        if t.count > 90 { t = String(t.prefix(90)).trimmingCharacters(in: .whitespaces) + "…" }
        return t.isEmpty ? line : t
    }

    func item(name: String, context: String, text: String?, code: String, term: Int, week: Int?, reference: Date,
              url: String?, cmid: Int?) -> HomeworkItem {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = Self.kind(of: title + " " + context.prefix(200))
        let (due, dueText, source) = resolveDue(texts: [title, context, String((text ?? "").prefix(4000))], term: term, week: week, reference: reference)
        let questions = text.flatMap(Self.questionCount)
        let id = "hw-\(code)-" + (cmid.map { "cm\($0)" } ?? String(MD5.hex("\(Self.normalise(title))|\(week ?? 0)").prefix(12)))
        let formative = !(AssessmentParsing.weightPercent(in: context) ?? 0 > 0) || AssessmentParsing.isFormative(context)
        return HomeworkItem(id: id, moduleCode: code, title: title, kind: kind, term: term, week: week, due: due,
                            dueText: dueText, dueSource: source, url: url, cmid: cmid,
                            summary: Self.summary(name: title, context: context, text: text, questions: questions),
                            questionCount: questions, estimateMinutes: Self.estimate(kind: kind, questions: questions, text: text),
                            formative: formative)
    }

    /// Due date from the item's texts: stated dates near "due/submit/by", teaching-week
    /// phrases, else the end of the week it was set in.
    func resolveDue(texts: [String], term: Int, week: Int?, reference: Date) -> (Date?, String?, HomeworkItem.DueSource) {
        let dateExtractor = DateExtractor(now: reference, timeZone: calendar.timeZone)
        for text in texts where !text.isEmpty {
            // Look at the phrase after a due word first.
            for m in UniRegex.matches("\\b(?:due|deadline|submit(?:ted)?|hand\\s*(?:it\\s+)?in|complete(?:d)?|attempt|finish|before|by)\\b([^\\n]{0,80})", in: text) {
                let tail = m[1] ?? ""
                if let a = calendar.resolve(tail, reference: reference, term: term), a.range.location <= 12 {
                    return (a.dueDate(in: calendar), a.text, .academicWeek)
                }
                if let d = dateExtractor.extract(from: tail).first(where: { $0.range.lowerBound.utf16Offset(in: tail) <= 16 }) {
                    let due = d.hasTime ? d.date : calendar.dayCalendar.date(minute: 23 * 60 + 59, of: d.date)
                    return (due, d.text, .explicit)
                }
            }
        }
        if let week, let d = calendar.date(term: term, week: week, weekday: 5, hour: 23, minute: 59) {
            return (d, nil, .assumed)
        }
        return (nil, nil, .none)
    }

    // MARK: Lecture prep

    /// "Read chapter 3 before the week 5 lecture", "Please read Smith (2019) before Monday's lecture",
    /// "Pre-reading for week 4: …" → a prep item due the Monday morning of that week.
    func prepItem(line: String, code: String, term: Int, week: Int?, reference: Date, url: String?) -> HomeworkItem? {
        let patterns = [
            "\\b(?:please\\s+)?(read|watch|prepare|review|complete)\\s+(.{3,160}?)\\s+(?:before|ahead\\s+of|prior\\s+to|in\\s+preparation\\s+for)\\s+(?:the\\s+|next\\s+|this\\s+)?(.{0,40}?\\b(?:lecture|seminar|tutorial|class|workshop)s?)\\b",
            "\\b(?:pre-?reading|preparatory\\s+reading|preparation)\\s+(?:for\\s+)?((?:week|wk)\\s*\\d{1,2}[^:]*)[:\\-–]\\s*(.{3,200})",
        ]
        if let m = UniRegex.first(patterns[0], in: line) {
            let verb = (m[1] ?? "read").capitalized
            let what = (m[2] ?? "").trimmingCharacters(in: .whitespaces)
            let when = m[3] ?? ""
            var target = calendar.resolve(when, reference: reference, term: term)
            if target == nil, UniRegex.first("\\bnext\\b", in: when) != nil, let w = week {
                target = calendar.resolve("week \(w + 1)", reference: reference, term: term)
            }
            let due = target.map { t in calendar.dayCalendar.date(minute: 9 * 60, of: t.isPeriod ? t.date : t.date) }
                ?? week.flatMap { calendar.date(term: term, week: $0 + 1, weekday: 1, hour: 9) }
            return HomeworkItem(id: "prep-\(code)-" + String(MD5.hex(Self.normalise(line)).prefix(12)), moduleCode: code,
                                title: "\(verb) \(what)", kind: .prep, term: term, week: week, due: due, dueText: when,
                                dueSource: target != nil ? .academicWeek : .assumed, url: url,
                                summary: line, estimateMinutes: verb == "Watch" ? 60 : 45)
        }
        if let m = UniRegex.first(patterns[1], in: line), let target = calendar.resolve(m[1] ?? "", reference: reference, term: term) {
            let what = (m[2] ?? "").trimmingCharacters(in: .whitespaces)
            return HomeworkItem(id: "prep-\(code)-" + String(MD5.hex(Self.normalise(line)).prefix(12)), moduleCode: code,
                                title: "Read \(what)", kind: .prep, term: term, week: target.week,
                                due: calendar.date(term: target.term, week: target.week, weekday: 1, hour: 9), dueText: m[1],
                                dueSource: .academicWeek, url: url, summary: line, estimateMinutes: 45)
        }
        return nil
    }

    // MARK: Effort

    /// Numbered questions in a sheet: "1.", "Q1", "Question 2", "Exercise 3", top-level only.
    public static func questionCount(_ text: String) -> Int? {
        var numbers = Set<Int>()
        for m in UniRegex.matches("(?:^|\\n)\\s*(?:#\\s*slide\\s*\\d+[^\\n]*\\n\\s*)?(?:q(?:uestion)?\\.?\\s*|exercise\\s+|problem\\s+|task\\s+)?(\\d{1,2})\\s*[.):]\\s+\\S", in: text) {
            if let n = m[1].flatMap(Int.init), n > 0, n <= 40 { numbers.insert(n) }
        }
        for m in UniRegex.matches("\\b(?:question|exercise|problem|task)\\s+(\\d{1,2})\\b", in: text) {
            if let n = m[1].flatMap(Int.init), n > 0, n <= 40 { numbers.insert(n) }
        }
        guard !numbers.isEmpty else { return nil }
        // Count the run 1…k so stray numbers (years, page refs) don't inflate it.
        var k = 0
        while numbers.contains(k + 1) { k += 1 }
        return k > 0 ? k : nil
    }

    static func estimate(kind: HomeworkItem.Kind, questions: Int?, text: String?) -> Int {
        switch kind {
        case .quiz: return 30
        case .test, .mock: return 60
        case .prep: return 45
        default: break
        }
        if let q = questions { return min(240, max(30, q * 15)) }
        if let t = text, t.count > 6000 { return 120 }
        return 60
    }

    static func summary(name: String, context: String, text: String?, questions: Int?) -> String {
        var parts: [String] = []
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty, ctx.lowercased() != name.lowercased() { parts.append(String(ctx.prefix(200))) }
        if let questions { parts.append("\(questions) question\(questions == 1 ? "" : "s")") }
        if let text {
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count > 20 && !$0.hasPrefix("#") }
            if let first = lines.first { parts.append("Starts: “\(first.prefix(160))”") }
        }
        return parts.joined(separator: " · ")
    }

    static func normalise(_ s: String) -> String {
        NoteIndex.terms(s).joined(separator: " ")
    }

    /// Same work mentioned twice (a label "HW stats sheet due end of week 2" and the file
    /// "HW stats sheet.pdf"): keep one, preferring the ELE item, and the most precise due date.
    static func merge(_ items: [HomeworkItem]) -> [HomeworkItem] {
        var out: [HomeworkItem] = []
        for item in items {
            let terms = Set(NoteIndex.terms(item.title)).subtracting(["hw", "homework", "sheet", "week"])
            if let i = out.firstIndex(where: { o in
                guard o.moduleCode == item.moduleCode, o.week == item.week, o.kind != .prep || item.kind == .prep else { return false }
                if o.id == item.id { return true }
                let ot = Set(NoteIndex.terms(o.title)).subtracting(["hw", "homework", "sheet", "week"])
                guard !ot.isEmpty, !terms.isEmpty else { return false }
                return Double(ot.intersection(terms).count) / Double(min(ot.count, terms.count)) >= 0.6
            }) {
                var keep = out[i].cmid != nil || item.cmid == nil ? out[i] : item
                let other = keep == out[i] ? item : out[i]
                if rank(other.dueSource) > rank(keep.dueSource) {
                    keep.due = other.due; keep.dueText = other.dueText; keep.dueSource = other.dueSource
                }
                if keep.questionCount == nil, other.questionCount != nil {
                    keep.questionCount = other.questionCount; keep.estimateMinutes = other.estimateMinutes
                }
                if keep.summary.count < other.summary.count { keep.summary = other.summary }
                out[i] = keep
            } else {
                out.append(item)
            }
        }
        return out
    }

    static func rank(_ s: HomeworkItem.DueSource) -> Int {
        switch s {
        case .ele: 4
        case .explicit: 3
        case .academicWeek: 2
        case .assumed: 1
        case .none: 0
        }
    }

    // MARK: Tasks

    /// To-dos for the items due in the window (not long past, not too far ahead).
    public func tasks(for items: [HomeworkItem], horizonDays: Int = 21, graceDays: Int = 2) -> [OrbitTask] {
        let from = now.addingTimeInterval(-Double(graceDays) * 86400)
        let until = now.addingTimeInterval(Double(horizonDays) * 86400)
        return items.compactMap { h in
            if let d = h.due, d < from || d > until { return nil }
            if h.due == nil, let w = h.week, let start = calendar.weekStart(term: h.term ?? 1, week: w), start > until { return nil }
            return task(for: h)
        }
    }

    public func task(for h: HomeworkItem) -> OrbitTask {
        let daysLeft = h.due.map { $0.timeIntervalSince(now) / 86400 } ?? 7
        let priority: Priority = daysLeft <= 2 ? .high : (h.kind == .prep ? .low : .normal)
        var notes = h.summary
        if let text = h.dueText, h.dueSource != .assumed { notes += (notes.isEmpty ? "" : "\n") + "Due: \(text)" }
        if h.dueSource == .assumed { notes += (notes.isEmpty ? "" : "\n") + "No due date given on ELE; planned for the end of the week it was set." }
        if let url = h.url { notes += (notes.isEmpty ? "" : "\n") + url }
        let label = h.kind == .prep ? "Prep" : h.kind.label
        let title = h.title.lowercased().hasPrefix(label.lowercased()) || h.kind == .prep ? h.title : "\(label): \(h.title)"
        return OrbitTask(id: h.taskID, title: "\(h.moduleCode) \(title)", notes: notes, estimateMinutes: h.estimateMinutes,
                         deadline: h.due, priority: priority, energy: h.kind == .prep ? .medium : .high, moduleCode: h.moduleCode,
                         source: .ele, sourceRef: h.id, minBlockMinutes: min(25, h.estimateMinutes),
                         maxBlockMinutes: max(min(25, h.estimateMinutes), 90))
    }
}
