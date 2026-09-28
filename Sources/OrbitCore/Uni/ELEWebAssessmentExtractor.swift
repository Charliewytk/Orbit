import Foundation

/// An assessment read from a module's "Assessment" section, with the details
/// the table gives beyond `Assessment` itself.
public struct ELEWebAssessment: Codable, Hashable, Sendable {
    public var assessment: Assessment
    /// Raw deadline cell, e.g. "16 November" or "TBA: week 1 of term2".
    public var deadlineText: String
    public var format: String?
    public var type: String?
    /// "1½ hours" for exams.
    public var duration: String?
    public var durationMinutes: Int?
    public var aiStatus: String?
    public var formative: Bool
    /// Why the due date is missing or approximate.
    public var note: String?

    public init(assessment: Assessment, deadlineText: String = "", format: String? = nil, type: String? = nil,
                duration: String? = nil, durationMinutes: Int? = nil, aiStatus: String? = nil, formative: Bool = false,
                note: String? = nil) {
        self.assessment = assessment; self.deadlineText = deadlineText; self.format = format; self.type = type
        self.duration = duration; self.durationMinutes = durationMinutes; self.aiStatus = aiStatus
        self.formative = formative; self.note = note
    }

    /// One line for the UI: "Word or PDF · AI: permitted · Due date TBA: week 1 of term2".
    public var details: String {
        var parts: [String] = []
        if formative { parts.append("Formative") }
        if let d = duration { parts.append(d) }
        if let f = format, !f.isEmpty { parts.append(f) }
        if let a = aiStatus, !a.isEmpty { parts.append("AI: \(a)") }
        if let n = note { parts.append(n) }
        return parts.joined(separator: " · ")
    }
}

/// Reads assessments out of an ELE "Assessment" section: the HTML table first
/// (deterministic), then the brief text for the exact time, and optionally an
/// LLM when there's no table.
public enum ELEAssessmentExtractor {
    public struct Context: Sendable {
        public var moduleCode: String
        public var academicYear: Int
        public var sectionURL: String?
        public var timeZone: TimeZone
        /// Hour used when neither table nor brief gives a time (Exeter's usual noon).
        public var defaultHour: Int
        /// Resolves week-based deadlines ("end of week 5", "week 1 of term 2").
        public var academic: AcademicCalendar?
        /// The module's teaching term, for "week N" with no term stated.
        public var term: Int?

        public init(moduleCode: String, academicYear: Int, sectionURL: String? = nil,
                    timeZone: TimeZone = ELEWebParser.london, defaultHour: Int = 12,
                    academic: AcademicCalendar? = nil, term: Int? = nil) {
            self.moduleCode = moduleCode; self.academicYear = academicYear; self.sectionURL = sectionURL
            self.timeZone = timeZone; self.defaultHour = defaultHour; self.academic = academic; self.term = term
        }
    }

    // MARK: Table

    /// The table as rows of cell text.
    public static func tableRows(_ html: String) -> [[String]] {
        guard let table = UniRegex.first("<table[^>]*>(.*?)</table>", in: html, dotAll: true)?[1] else { return [] }
        return UniRegex.matches("<tr[^>]*>(.*?)</tr>", in: table, dotAll: true).map { row in
            UniRegex.matches("<t[hd][^>]*>(.*?)</t[hd]>", in: row[1] ?? "", dotAll: true).map {
                UniHTML.text($0[1] ?? "").replacingOccurrences(of: "\n", with: " ")
            }
        }.filter { !$0.allSatisfy(\.isEmpty) }
    }

    enum Field { case deadline, title, formative, type, format, value, length, ai }

    static func field(_ label: String) -> Field? {
        let l = label.lowercased()
        if l.contains("deadline") || l.hasPrefix("due") || l.contains("submission date") || l.contains("date") { return .deadline }
        if l.contains("formative") || l.contains("summative") { return .formative }
        if l.hasPrefix("ai") || l.contains(" ai ") || l.contains("artificial") || l.contains("genai") { return .ai }
        if l.contains("word") || l.contains("time") || l.contains("length") || l.contains("duration") { return .length }
        if l.contains("value") || l.contains("weight") || l.contains("%") { return .value }
        if l.contains("title") || l.contains("name") { return .title }
        if l.contains("format") { return .format }
        if l.contains("type") || l.contains("method") { return .type }
        return nil
    }

    /// Assessments from the section HTML (table) and brief texts.
    public static func extract(sectionHTML: String, briefs: [String] = [], context: Context) -> [ELEWebAssessment] {
        let rows = tableRows(sectionHTML)
        guard rows.count >= 2 else { return [] }
        let columns = rows.map(\.count).max() ?? 0
        guard columns >= 2 else { return [] }
        // Headers: the first row if it isn't itself a field row.
        let headerRow = field(rows[0][0]) == nil ? rows[0] : []
        var values: [Field: [String]] = [:]
        for row in rows where row.count >= 2 {
            guard let f = field(row[0]), values[f] == nil else { continue }
            values[f] = Array(row.dropFirst())
        }
        guard values[.deadline] != nil || values[.value] != nil || values[.title] != nil else { return [] }
        let briefText = briefs.joined(separator: "\n")
        var out: [ELEWebAssessment] = []
        for col in 0..<(columns - 1) {
            func v(_ f: Field) -> String? {
                guard let list = values[f], col < list.count else { return nil }
                let t = list[col].trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            let header = col + 1 < headerRow.count ? headerRow[col + 1] : "Assessment \(col + 1)"
            guard v(.deadline) != nil || v(.title) != nil || v(.value) != nil else { continue }
            let rawTitle = v(.title) ?? header
            let title = displayTitle(rawTitle, header: header)
            let type = v(.type), format = v(.format)
            let formative = (v(.formative)?.lowercased().contains("formative") ?? false)
                && !(v(.formative)?.lowercased().contains("summative") ?? false)
            let weight = formative ? 0 : (v(.value).flatMap(percent) ?? 0)
            let length = v(.length)
            let words = length.flatMap(AssessmentParsing.wordCount(in:))
            let minutes = length.flatMap(durationMinutes)
            var kind = AssessmentParsing.kind(title: [rawTitle, type ?? "", format ?? ""].joined(separator: " "))
            if kind == .coursework, minutes != nil, words == nil { kind = .exam }
            let deadline = v(.deadline) ?? ""
            let (due, note) = resolveDue(deadline, brief: briefText, kind: kind, context: context)
            let id = "eleweb-\(context.moduleCode)-a\(col + 1)"
            let a = Assessment(id: id, moduleCode: context.moduleCode, title: title, kind: kind, weightPercent: weight,
                               due: due, wordCount: words, eleURL: context.sectionURL)
            out.append(ELEWebAssessment(assessment: a, deadlineText: deadline, format: format, type: type,
                                        duration: minutes != nil ? length : nil, durationMinutes: minutes,
                                        aiStatus: v(.ai), formative: formative, note: note))
        }
        return out
    }

    /// "essay" + "Assessment 1" → "Essay"; keeps longer titles as they are.
    static func displayTitle(_ raw: String, header: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return header }
        return first.uppercased() + t.dropFirst()
    }

    static func percent(_ s: String) -> Double? {
        UniRegex.first("(\\d{1,3}(?:\\.\\d+)?)\\s*%", in: s)?[1].flatMap(Double.init).flatMap { $0 > 0 && $0 <= 100 ? $0 : nil }
    }

    /// "1½ hours" → 90, "2 hours" → 120, "90 minutes" → 90, "1.5 hrs" → 90.
    public static func durationMinutes(_ s: String) -> Int? {
        let t = s.replacingOccurrences(of: "½", with: ".5").replacingOccurrences(of: "¼", with: ".25")
            .replacingOccurrences(of: "¾", with: ".75").replacingOccurrences(of: " .", with: ".")
        if let m = UniRegex.first("(\\d+(?:\\.\\d+)?)\\s*(?:hours?|hrs?|h)\\b(?:\\s*(\\d+)\\s*(?:minutes?|mins?))?", in: t),
           let h = m[1].flatMap(Double.init) {
            return Int((h * 60).rounded()) + (m[2].flatMap(Int.init) ?? 0)
        }
        if let m = UniRegex.first("(\\d+)\\s*(?:minutes?|mins?)\\b", in: t), let v = m[1].flatMap(Int.init) { return v }
        return nil
    }

    // MARK: Dates

    static let monthPattern = "(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"

    /// Day + month in text ("16 November", "November 16th", "16th Nov").
    public static func dayMonth(in text: String) -> (day: Int, month: Int)? {
        if let m = UniRegex.first("\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?\(monthPattern)\\b", in: text),
           let d = m[1].flatMap(Int.init), let mo = m[2].flatMap(ELEWebParser.month), (1...31).contains(d) { return (d, mo) }
        if let m = UniRegex.first("\\b\(monthPattern)\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b", in: text),
           let d = m[2].flatMap(Int.init), let mo = m[1].flatMap(ELEWebParser.month), (1...31).contains(d) { return (d, mo) }
        return nil
    }

    /// A clock time: "3pm", "3.00 pm", "15:00", "noon", "midday".
    public static func time(in text: String) -> (hour: Int, minute: Int)? {
        if let m = UniRegex.first("\\b(\\d{1,2})(?:[:.](\\d{2}))?\\s*(am|pm|a\\.m\\.|p\\.m\\.)", in: text),
           var h = m[1].flatMap(Int.init), h <= 12 {
            let pm = (m[3] ?? "").lowercased().hasPrefix("p")
            if pm && h < 12 { h += 12 }
            if !pm && h == 12 { h = 0 }
            return (h, m[2].flatMap(Int.init) ?? 0)
        }
        if let m = UniRegex.first("\\b([01]?\\d|2[0-3])[:.]([0-5]\\d)\\b(?!\\s*%)", in: text),
           let h = m[1].flatMap(Int.init), let mi = m[2].flatMap(Int.init) { return (h, mi) }
        if UniRegex.first("\\b(noon|midday)\\b", in: text) != nil { return (12, 0) }
        if UniRegex.first("\\bmidnight\\b", in: text) != nil { return (23, 59) }
        return nil
    }

    /// The time stated next to a given day+month in the brief ("3pm 16 November", "16 November at 15:00").
    static func briefTime(for dm: (day: Int, month: Int), in brief: String) -> (hour: Int, minute: Int)? {
        let ns = brief as NSString
        let pattern = "\\b\(dm.day)(?:st|nd|rd|th)?\\s+(?:of\\s+)?\(monthPattern)"
        for m in UniRegex.regex(pattern).matches(in: brief, range: NSRange(location: 0, length: ns.length)) {
            guard ELEWebParser.month(ns.substring(with: m.range(at: 1))) == dm.month else { continue }
            let start = max(0, m.range.location - 40)
            let end = min(ns.length, m.range.location + m.range.length + 40)
            let before = ns.substring(with: NSRange(location: start, length: m.range.location - start))
            let after = ns.substring(with: NSRange(location: m.range.location + m.range.length,
                                                   length: end - m.range.location - m.range.length))
            // Prefer the time closest to the date: end of "before", start of "after".
            if let t = lastTime(in: before) { return t }
            if let t = time(in: after) { return t }
        }
        return nil
    }

    static func lastTime(in text: String) -> (hour: Int, minute: Int)? {
        // Try successively shorter suffixes so the nearest time wins.
        let chars = Array(text)
        for start in stride(from: max(0, chars.count - 12), through: 0, by: -4) {
            if let t = time(in: String(chars[start...])) { return t }
        }
        return nil
    }

    /// Deadline cell (+ brief) → date and a note when it can't be resolved.
    public static func resolveDue(_ deadline: String, brief: String, kind: AssessmentKind,
                                  context: Context) -> (Date?, String?) {
        let lower = deadline.lowercased()
        let tentative = lower.contains("tba") || lower.contains("tbc") || lower.contains("to be") || lower.contains("exam period")
        if !tentative, dayMonth(in: deadline) == nil, let academic = context.academic,
           let m = academic.resolve(deadline, reference: Date(), term: context.term) {
            var due = m.dueDate(in: academic)
            if let t = time(in: deadline), !m.isPeriod {
                due = academic.dayCalendar.date(minute: t.hour * 60 + t.minute, of: m.date)
            }
            let week = academic.academicWeek(term: m.term, week: m.week).map(\.label) ?? "week \(m.week)"
            return (due, "Due \(deadline) (\(week)); check the exact time on ELE")
        }
        if lower.contains("tba") || lower.contains("tbc") || lower.contains("to be") || lower.contains("exam period")
            || (dayMonth(in: deadline) == nil && (lower.contains("term") || lower.contains("week"))) {
            return (nil, deadline.isEmpty ? nil : "Due date \(deadline)")
        }
        guard let dm = dayMonth(in: deadline) else {
            return (nil, deadline.isEmpty ? "No deadline on ELE yet" : "Due date \(deadline)")
        }
        let t = time(in: deadline) ?? briefTime(for: dm, in: brief)
        let date = ELEWebParser.date(day: dm.day, month: dm.month, academicYear: context.academicYear,
                                     hour: t?.hour ?? context.defaultHour, minute: t?.minute ?? 0,
                                     timeZone: context.timeZone)
        return (date, t == nil ? "Time not stated; assumed \(context.defaultHour):00" : nil)
    }

    // MARK: LLM fallback

    struct LLMItem: Decodable {
        var title: String
        var kind: String?
        var weightPercent: Double?
        var deadline: String?
        var wordCount: Int?
        var format: String?
    }
    struct LLMReply: Decodable { var assessments: [LLMItem] }

    /// When there's no usable table: asks the local model to read the section
    /// and briefs. Results are still date-resolved deterministically.
    public static func extractWithLLM(router: LLMRouter, sectionText: String, briefs: [String],
                                      context: Context) async -> [ELEWebAssessment] {
        let system = """
        You read a UK university module's assessment information and reply with JSON only:
        {"assessments":[{"title":"Essay","kind":"essay|exam|report|presentation|quiz|coursework|groupwork|other",\
        "weightPercent":20,"deadline":"16 November 3pm","wordCount":1500,"format":"word or pdf"}]}
        Copy the deadline wording exactly as written (day, month and time). Use null when not stated. Only list summative assessments.
        """
        let user = "Module \(context.moduleCode)\n\nSECTION:\n\(sectionText.prefix(6000))\n\nBRIEFS:\n\(briefs.joined(separator: "\n---\n").prefix(8000))"
        let req = LLMRequest(messages: [.system(system), .user(user)], purpose: .privateData, json: true, temperature: 0)
        guard let reply = try? await router.completeJSON(LLMReply.self, req) else { return [] }
        let brief = briefs.joined(separator: "\n")
        return reply.assessments.enumerated().map { i, item in
            let kind = item.kind.flatMap(AssessmentKind.init(rawValue:)) ?? AssessmentParsing.kind(title: item.title)
            let (due, note) = resolveDue(item.deadline ?? "", brief: brief, kind: kind, context: context)
            let a = Assessment(id: "eleweb-\(context.moduleCode)-a\(i + 1)", moduleCode: context.moduleCode, title: item.title,
                               kind: kind, weightPercent: item.weightPercent ?? 0, due: due, wordCount: item.wordCount,
                               eleURL: context.sectionURL)
            return ELEWebAssessment(assessment: a, deadlineText: item.deadline ?? "", format: item.format,
                                    note: [note, "Read by AI; check on ELE"].compactMap { $0 }.joined(separator: " · "))
        }
    }

    // MARK: Merge with the timeline

    /// Attaches exact timeline deadlines (and submission links) to table
    /// assessments of the same module, and appends timeline items with no match.
    public static func merge(table: [ELEWebAssessment], events: [Assessment]) -> [ELEWebAssessment] {
        var out = table
        var used = Set<Int>()
        for e in events {
            let candidates = out.indices.filter { !used.contains($0) && out[$0].assessment.moduleCode == e.moduleCode }
            let match = candidates.first { i in
                guard let d = out[i].assessment.due, let ed = e.due else { return false }
                return abs(d.timeIntervalSince(ed)) < 3 * 86400
            } ?? candidates.first { i in
                out[i].assessment.due == nil && out[i].assessment.kind == e.kind && e.kind != .coursework
            }
            if let i = match {
                used.insert(i)
                if let ed = e.due { out[i].assessment.due = ed; out[i].note = nil }
                if let url = e.eleURL { out[i].assessment.eleURL = url }
            } else if !out.contains(where: { $0.assessment.id == e.id }) {
                out.append(ELEWebAssessment(assessment: e, deadlineText: ""))
            }
        }
        return out
    }
}
