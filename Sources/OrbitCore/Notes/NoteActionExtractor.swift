import Foundation

// Handwritten notes are full of notes-to-self: "homework: read chapter 1…",
// "get good with excel… week 6", "DATA ACCESS → ask guy at end", "Quiz… once per week".
// `NoteActionExtractor` finds them with rules (fast, offline, deterministic), and can
// ask the local model (`.privateData`, never the cloud) to tidy titles and catch
// what the rules missed. `NoteActionLedger` remembers what was suggested, added or
// dismissed so re-scanning a page (or the OCR reading it slightly differently) never
// brings the same item back twice.

/// A to-do or note-to-self found in a lecture note.
public struct NoteAction: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// "homework: …", "HW …": set work — added as a Required task.
        case homework
        /// "todo", "to do", checkboxes, "find some…".
        case todo
        /// "remember to", "need to", "don't forget".
        case reminder
        /// "read chapter 3", "read pp. 10–20".
        case reading
        /// Something to ask the lecturer / tutor ("→ ask … at end").
        case ask
        /// A skill to build ("get good with excel").
        case skill
        /// A habit ("quiz… once per week").
        case recurring

        public var label: String {
            switch self {
            case .homework: "Homework"
            case .todo: "To-do"
            case .reminder: "Reminder"
            case .reading: "Reading"
            case .ask: "Ask"
            case .skill: "Skill"
            case .recurring: "Weekly"
            }
        }

        public var symbol: String {
            switch self {
            case .homework: "pencil.and.list.clipboard"
            case .todo: "checklist"
            case .reminder: "bell"
            case .reading: "book"
            case .ask: "questionmark.bubble"
            case .skill: "chart.line.uptrend.xyaxis"
            case .recurring: "arrow.triangle.2.circlepath"
            }
        }
    }

    /// Stable across re-scans: module + normalised words of the title.
    public var id: String { key }
    public var key: String
    public var kind: Kind
    /// Clean task title ("Read chapter 1 “minds …” — consider issues in each case").
    public var title: String
    /// The line(s) as written, for the task notes and the UI.
    public var sourceText: String
    public var noteID: String
    public var noteTitle: String
    public var moduleCode: String?
    /// Week the note is from.
    public var week: Int?
    public var due: Date?
    /// True when `due` was worked out from the lecture week rather than written down.
    public var dueInferred: Bool
    /// "weekly" for habits.
    public var recurrence: String?
    public var confidence: Double
    /// "rules" or "rules+ai" / "ai".
    public var source: String

    public init(key: String, kind: Kind, title: String, sourceText: String, noteID: String, noteTitle: String,
                moduleCode: String?, week: Int?, due: Date?, dueInferred: Bool = false, recurrence: String? = nil,
                confidence: Double, source: String = "rules") {
        self.key = key; self.kind = kind; self.title = title; self.sourceText = sourceText; self.noteID = noteID
        self.noteTitle = noteTitle; self.moduleCode = moduleCode; self.week = week; self.due = due
        self.dueInferred = dueInferred; self.recurrence = recurrence; self.confidence = confidence; self.source = source
    }

    /// Clear homework is added straight away (Required); everything else is a suggestion.
    public var autoAdd: Bool { kind == .homework && confidence >= 0.75 }

    /// The task Orbit makes for it. Homework is Required ("note-homework:" ref); a
    /// suggestion the student accepts is filed as an Orbit recommendation from notes.
    public func task(estimateMinutes: Int? = nil) -> OrbitTask {
        let ref = (kind == .homework ? "note-homework:" : "note-action:") + key
        var notes = "From your notes: \(noteTitle)\n“\(sourceText)”"
        if let recurrence { notes += "\nRepeats \(recurrence)." }
        if dueInferred, due != nil { notes += "\nDue date guessed from the lecture week." }
        let estimate = estimateMinutes ?? {
            switch kind {
            case .homework: 60
            case .reading: 45
            case .skill: 60
            case .ask: 5
            case .recurring: 20
            case .todo, .reminder: 20
            }
        }()
        return OrbitTask(id: StableID.uuid("orbit-note-action|\(key)"), title: title, notes: notes,
                         estimateMinutes: estimate, deadline: due, priority: kind == .homework ? .normal : .low,
                         energy: kind == .homework || kind == .skill ? .high : .low, moduleCode: moduleCode,
                         source: .notes, sourceRef: ref, minBlockMinutes: min(25, estimate),
                         maxBlockMinutes: max(min(25, estimate), 90))
    }

    public var taskID: UUID { StableID.uuid("orbit-note-action|\(key)") }
}

public struct NoteActionExtractor: Sendable {
    public var calendar: AcademicCalendar
    public var timeZone: TimeZone

    public init(calendar: AcademicCalendar = .exeter, timeZone: TimeZone? = nil) {
        self.calendar = calendar
        self.timeZone = timeZone ?? calendar.timeZone
    }

    // MARK: Rules

    struct Rule {
        var kind: NoteAction.Kind
        var pattern: NSRegularExpression
        /// Drop the matched trigger from the title ("homework:" → "").
        var stripTrigger: Bool
        var confidence: Double
    }

    private static func re(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    static let bullet = #"^\s*(?:[-–•*·>]+\s*)?"#

    static let rules: [Rule] = [
        Rule(kind: .homework, pattern: re(bullet + #"(?:homework|home\s*work|hw|h/w)\b\s*[:\-–—.…]*\s*"#), stripTrigger: true, confidence: 0.9),
        Rule(kind: .todo, pattern: re(#"^\s*(?:☐|□|▢|◻|\[\s?\]|[-*]\s*\[\s?\])\s*"#), stripTrigger: true, confidence: 0.85),
        Rule(kind: .todo, pattern: re(bullet + #"(?:to\s?-?\s?do|todo)\b\s*[:\-–—.…]*\s*"#), stripTrigger: true, confidence: 0.85),
        Rule(kind: .reminder, pattern: re(bullet + #"(?:remember\s+to|don'?t\s+forget(?:\s+to)?|need\s+to|must|make\s+sure\s+(?:to|i))\b\s*"#), stripTrigger: false, confidence: 0.75),
        Rule(kind: .reading, pattern: re(bullet + #"(?:pre-?)?read(?:ing)?\s+(?:ch(?:apter|\.)?\s*\d|pp?\.?\s*\d|pages?\s*\d|section\s*\d)"#), stripTrigger: false, confidence: 0.75),
        Rule(kind: .skill, pattern: re(bullet + #"(?:get\s+(?:good|better)\s+(?:with|at)|learn\s+(?:how\s+to\s+)?|practi[cs]e\s+)"#), stripTrigger: false, confidence: 0.65),
        Rule(kind: .todo, pattern: re(bullet + #"(?:find|look\s+up|sign\s+up|email|book|print|download|submit|revise|check)\s+\w"#), stripTrigger: false, confidence: 0.55),
    ]

    static let askArrow = re(#"^(.*?)\s*(?:→|->|=>|⇒|—>)\s*(ask\b.*)$"#)
    static let askLine = re(bullet + #"ask\s+(?:the\s+)?(?:lecturer|tutor|prof(?:essor)?|guy|teacher|someone|[a-z]+\s+)?(?:at\s+(?:the\s+)?end|after|about|in\s+(?:the\s+)?seminar|re\b)"#)
    static let recurring = re(#"\b(?:once\s+(?:per|a|every)\s+week|every\s+week|each\s+week|weekly)\b"#)
    static let weekRef = re(#"\b(?:by\s+|before\s+|until\s+|in\s+)?(?:week|wk)\s*(\d{1,2})\b"#)

    /// Actions in one note (rules only).
    public func extract(from note: LectureNote) -> [NoteAction] {
        let reference = note.created
        let lines = Self.lines(of: note)
        var out: [NoteAction] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            guard var found = classify(line) else { continue }
            // Homework / to-dos often wrap onto the next line in handwriting.
            var source = line
            if found.kind == .homework || found.kind == .todo || found.kind == .reading {
                var extra = 0
                while i < lines.count, extra < 2, Self.isContinuation(lines[i]) {
                    source += " " + lines[i]
                    found.body += " " + lines[i]
                    i += 1; extra += 1
                }
            }
            let (due, inferred) = dueDate(for: found.kind, text: source, noteWeek: note.week, reference: reference)
            let title = Self.title(kind: found.kind, body: found.body)
            guard title.count >= 3 else { continue }
            out.append(NoteAction(key: Self.key(moduleCode: note.moduleCode, title: title), kind: found.kind, title: title,
                                  sourceText: Self.tidy(source), noteID: note.id, noteTitle: note.title,
                                  moduleCode: note.moduleCode, week: note.week, due: due, dueInferred: inferred,
                                  recurrence: found.kind == .recurring ? "weekly" : nil, confidence: found.confidence))
        }
        return Self.dedupe(out)
    }

    struct Classified {
        var kind: NoteAction.Kind
        var body: String
        var confidence: Double
    }

    func classify(_ line: String) -> Classified? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        // Explicit triggers first (homework beats "read chapter" on the same line).
        for rule in Self.rules {
            guard let m = rule.pattern.firstMatch(in: line, range: full) else { continue }
            let body = rule.stripTrigger ? ns.substring(from: m.range.upperBound) : ns.substring(from: m.range.location)
            if rule.kind != .homework, Self.recurring.firstMatch(in: line, range: full) != nil {
                return Classified(kind: .recurring, body: body, confidence: 0.7)
            }
            return Classified(kind: rule.kind, body: body, confidence: rule.confidence)
        }
        if let m = Self.askArrow.firstMatch(in: line, range: full) {
            let topic = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let ask = ns.substring(with: m.range(at: 2))
            let body = topic.isEmpty ? ask : "\(ask) about \(Self.softenCaps(topic))"
            return Classified(kind: .ask, body: body, confidence: 0.75)
        }
        if Self.askLine.firstMatch(in: line, range: full) != nil {
            return Classified(kind: .ask, body: line, confidence: 0.7)
        }
        if Self.recurring.firstMatch(in: line, range: full) != nil {
            return Classified(kind: .recurring, body: line, confidence: 0.6)
        }
        return nil
    }

    /// A due date: one written in the line ("Fri 2 Oct", "week 6"), else for homework
    /// the start of the next teaching week after the lecture.
    func dueDate(for kind: NoteAction.Kind, text: String, noteWeek: Int?, reference: Date) -> (Date?, Bool) {
        let ns = text as NSString
        if let m = Self.weekRef.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
           let n = Int(ns.substring(with: m.range(at: 1))), (1...15).contains(n) {
            let term = calendar.week(for: reference)?.term ?? calendar.defaultTerm(for: reference)
            // "by week 6" → the Friday of week 6, end of the day.
            if let d = calendar.date(term: term, week: n, weekday: 5, hour: 17) { return (d, false) }
        }
        let extractor = DateExtractor(now: reference, timeZone: timeZone, academic: calendar)
        if let m = extractor.extract(from: text).first(where: { $0.date > reference.addingTimeInterval(-3600) }) {
            return (m.date, false)
        }
        if kind == .homework {
            let current = calendar.week(for: reference)
            let term = current?.term ?? calendar.defaultTerm(for: reference)
            if let w = noteWeek ?? current?.week, let d = calendar.date(term: term, week: w + 1, weekday: 1, hour: 9) {
                return (d, true)
            }
        }
        return (nil, false)
    }

    // MARK: Text helpers

    /// Lines of the note, typed and handwritten, split on newlines and " / ".
    static func lines(of note: LectureNote) -> [String] {
        note.segments.filter { $0.kind != .diagram }
            .flatMap { $0.text.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A wrapped line: starts lower-case (or with "&", "+", "..."), and isn't a new item.
    static func isContinuation(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        let startsLower = first.isLowercase || "&+…(\"“".contains(first) || line.hasPrefix("...")
        guard startsLower else { return false }
        let probe = NoteActionExtractor(calendar: .exeter)
        return probe.classify(line) == nil
    }

    static let abbreviations: [(String, String)] = [
        (#"\bYT\b"#, "YouTube"), (#"\bexcel\b"#, "Excel"), (#"\bw/"#, "with "), (#"\bch\.\s*"#, "chapter "),
        (#"\b(?:ch)\s+(?=\d)"#, "chapter "), (#"\bwk\s*(?=\d)"#, "week "), (#"\bstats\b"#, "statistics"),
    ]

    static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "...", with: "…")
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func title(kind: NoteAction.Kind, body: String) -> String {
        var t = tidy(body)
        for (p, r) in abbreviations { t = t.replacingOccurrences(of: p, with: r, options: [.regularExpression, .caseInsensitive]) }
        // Arrows and ellipses read as separators.
        t = t.replacingOccurrences(of: #"\s*(?:→|->|=>|⇒)\s*"#, with: " — ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*…\s*(?=[&+])"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*…\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*…\s*(?=[a-z])"#, with: " — ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*&\s*(?:…\s*)?"#, with: "; ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+([,.;:])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:;,.").union(.whitespaces))
        if kind == .recurring {
            t = t.replacingOccurrences(of: #"\s*—\s*(?=once|every|each|weekly)"#, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        if t.count > 110 { t = String(t.prefix(107)).trimmingCharacters(in: .whitespaces) + "…" }
        guard let f = t.first else { return t }
        return f.uppercased() + t.dropFirst()
    }

    /// "DATA INSTITUTIONAL ACCESS" → "data institutional access" (keeps real acronyms short).
    static func softenCaps(_ s: String) -> String {
        let letters = s.filter(\.isLetter)
        guard letters.count > 5, letters.allSatisfy(\.isUppercase) else { return s }
        return s.lowercased()
    }

    static let keyStopWords: Set<String> = ["the", "a", "an", "to", "of", "and", "for", "in", "on", "at", "it", "some",
                                            "with", "about", "my", "i", "is", "be", "each", "every"]

    /// Module + up to eight content words, sorted, so small OCR/word-order changes don't matter.
    public static func key(moduleCode: String?, title: String) -> String {
        let words = title.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 && !keyStopWords.contains($0) }
        let core = Array(Set(words.prefix(8))).sorted().joined(separator: "-")
        return "\(moduleCode ?? "none")|\(core)"
    }

    /// Two actions are the same when their keys match, or one's words mostly contain the other's.
    public static func isSame(_ a: NoteAction, _ b: NoteAction) -> Bool {
        if a.key == b.key { return true }
        guard a.moduleCode == b.moduleCode else { return false }
        let wa = Set(a.key.split(separator: "|").last?.split(separator: "-").map(String.init) ?? [])
        let wb = Set(b.key.split(separator: "|").last?.split(separator: "-").map(String.init) ?? [])
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        let overlap = Double(wa.intersection(wb).count) / Double(min(wa.count, wb.count))
        return overlap >= 0.8 && min(wa.count, wb.count) >= 2
    }

    static func dedupe(_ actions: [NoteAction]) -> [NoteAction] {
        var out: [NoteAction] = []
        for a in actions where !out.contains(where: { isSame($0, a) }) { out.append(a) }
        return out
    }

    // MARK: Local AI refinement

    struct AIItem: Decodable {
        var title: String
        var kind: String?
        var line: String?
        var week: Int?
    }

    struct AIReply: Decodable {
        var items: [AIItem]
    }

    /// Asks the local model (`.privateData` — Ollama only) to tidy titles and add to-dos
    /// the rules missed. Falls back to the rule results on any failure.
    public func refine(_ actions: [NoteAction], note: LectureNote, router: LLMRouter) async -> [NoteAction] {
        let text = Self.lines(of: note).joined(separator: "\n")
        guard !text.isEmpty else { return actions }
        let found = actions.map { "- [\($0.kind.rawValue)] \($0.title)" }.joined(separator: "\n")
        let system = """
        You read a student's lecture notes (OCR of handwriting, may contain mistakes) and list only the \
        to-dos and notes-to-self the student wrote for themselves: homework, things to read, find, learn, \
        practise, ask the lecturer, or do regularly. Ignore lecture content. Reply with JSON only: \
        {"items":[{"title":"short imperative task","kind":"homework|todo|reminder|reading|ask|skill|recurring",\
        "line":"the line as written","week":null}]}
        """
        let user = "Notes:\n\(text.prefix(4000))\n\nAlready found:\n\(found.isEmpty ? "(none)" : found)"
        let request = LLMRequest(messages: [.system(system), .user(user)], purpose: .privateData, json: true)
        guard let reply = try? await router.completeJSON(AIReply.self, request) else { return actions }
        var out = actions
        let lowerText = text.lowercased()
        for item in reply.items.prefix(12) {
            let title = Self.title(kind: .todo, body: item.title)
            guard title.count >= 3 else { continue }
            // Only keep items grounded in the page (the line, or most of the title's words, appear in it).
            let line = item.line.map(Self.tidy) ?? ""
            let words = title.lowercased().split(whereSeparator: { !$0.isLetter }).filter { $0.count > 3 }
            let grounded = (!line.isEmpty && lowerText.contains(line.lowercased().prefix(24)))
                || (!words.isEmpty && Double(words.filter { lowerText.contains($0) }.count) / Double(words.count) >= 0.6)
            guard grounded else { continue }
            let kind = NoteAction.Kind(rawValue: item.kind ?? "") ?? .todo
            let key = Self.key(moduleCode: note.moduleCode, title: title)
            if let i = out.firstIndex(where: { $0.key == key || (!line.isEmpty && $0.sourceText.lowercased().hasPrefix(line.lowercased().prefix(20))) }) {
                // Same item: take the model's cleaner title, keep the rule's kind and key (stable ids).
                if out[i].kind != .homework { out[i].title = title }
                out[i].source = "rules+ai"
                continue
            }
            var candidate = NoteAction(key: key, kind: kind == .homework ? .todo : kind, title: title,
                                       sourceText: line.isEmpty ? title : line, noteID: note.id, noteTitle: note.title,
                                       moduleCode: note.moduleCode, week: note.week, due: nil,
                                       recurrence: kind == .recurring ? "weekly" : nil, confidence: 0.5, source: "ai")
            // The model never auto-adds work: its homework guesses become suggestions.
            let (due, inferred) = dueDate(for: candidate.kind, text: line + " " + (item.week.map { "week \($0)" } ?? ""),
                                          noteWeek: note.week, reference: note.created)
            candidate.due = due; candidate.dueInferred = inferred
            if !out.contains(where: { Self.isSame($0, candidate) }) { out.append(candidate) }
        }
        return out
    }
}

// MARK: - Ledger (de-duplication across re-scans)

/// What happened to each action, keyed by `NoteAction.key`. Kept on the Mac.
public struct NoteActionLedger: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case suggested, added, dismissed
    }

    public struct Entry: Codable, Hashable, Sendable {
        public var action: NoteAction
        public var status: Status
        public var firstSeen: Date
        public var lastSeen: Date
    }

    public var entries: [String: Entry] = [:]

    public init() {}

    /// Open suggestions, newest first.
    public var suggestions: [NoteAction] {
        entries.values.filter { $0.status == .suggested }
            .sorted { ($0.lastSeen, $0.action.title) > ($1.lastSeen, $1.action.title) }
            .map(\.action)
    }

    public func actions(noteID: String) -> [Entry] {
        entries.values.filter { $0.action.noteID == noteID }.sorted { $0.action.title < $1.action.title }
    }

    public func entry(matching a: NoteAction) -> Entry? {
        if let e = entries[a.key] { return e }
        return entries.values.first { NoteActionExtractor.isSame($0.action, a) }
    }

    public struct Update: Sendable {
        /// New homework to add as tasks now.
        public var toAdd: [NoteAction] = []
        /// New suggestions (not seen before).
        public var newSuggestions: [NoteAction] = []
    }

    /// Records a scan of one note. Items already known keep their status (a dismissed or
    /// deleted item never comes back); suggestions no longer on the page are dropped.
    public mutating func record(_ actions: [NoteAction], noteID: String, now: Date = Date()) -> Update {
        var update = Update()
        var seen: Set<String> = []
        for a in actions {
            if let existing = entry(matching: a) {
                var e = existing
                e.lastSeen = now
                if e.status == .suggested {
                    // Refresh wording/due date; keep the original key so ids stay stable.
                    let key = e.action.key
                    e.action = a
                    e.action.key = key
                }
                entries[e.action.key] = e
                seen.insert(e.action.key)
                continue
            }
            let status: Status = a.autoAdd ? .added : .suggested
            entries[a.key] = Entry(action: a, status: status, firstSeen: now, lastSeen: now)
            seen.insert(a.key)
            if a.autoAdd { update.toAdd.append(a) } else { update.newSuggestions.append(a) }
        }
        for (k, e) in entries where e.action.noteID == noteID && e.status == .suggested && !seen.contains(k) {
            entries.removeValue(forKey: k)
        }
        return update
    }

    public mutating func mark(_ key: String, _ status: Status) {
        entries[key]?.status = status
    }
}
