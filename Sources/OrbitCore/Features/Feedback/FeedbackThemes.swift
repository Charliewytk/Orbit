import Foundation

/// Marker feedback on one piece of assessed work. The academic side fills
/// these from ELE (grades + feedback comments); `init(grade:)` converts an
/// `ELEGrade` directly.
public struct AssessmentFeedback: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var moduleCode: String
    public var assessmentTitle: String
    public var assessmentID: String?
    /// 0–100, if marked.
    public var mark: Double?
    public var comments: String
    public var receivedAt: Date?

    public init(id: String? = nil, moduleCode: String, assessmentTitle: String, assessmentID: String? = nil,
                mark: Double? = nil, comments: String, receivedAt: Date? = nil) {
        self.id = id ?? "fb-" + MD5.hex(moduleCode + "|" + assessmentTitle)
        self.moduleCode = moduleCode; self.assessmentTitle = assessmentTitle; self.assessmentID = assessmentID
        self.mark = mark; self.comments = comments; self.receivedAt = receivedAt
    }

    /// From an ELE gradebook entry (nil when there are no comments).
    public init?(grade: ELEGrade) {
        guard !grade.isCourseTotal, let text = grade.feedback?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        self.init(id: "fb-" + grade.id, moduleCode: grade.moduleCode, assessmentTitle: grade.itemName,
                  assessmentID: grade.assessmentID, mark: grade.percent, comments: text, receivedAt: grade.gradedAt)
    }

    /// Content fingerprint, so edited feedback is re-read.
    public var fingerprint: String { MD5.hex(comments + "|" + (mark.map { String($0) } ?? "")) }
}

/// A recurring thing markers comment on.
public struct FeedbackTheme: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    /// What to do about it when planning the next piece of work.
    public var advice: String
    public var keywords: [String]

    public static let criticalAnalysis = FeedbackTheme(
        id: "critical-analysis", label: "critical analysis",
        advice: "plan an evaluation paragraph for each main point (strengths, limits, assumptions)",
        keywords: ["critical", "critically", "evaluat", "analysis", "analytical", "descriptive", "assumption", "limitation", "critique", "depth"])
    public static let structure = FeedbackTheme(
        id: "structure", label: "structure",
        advice: "outline the sections and signposting before drafting",
        keywords: ["structure", "structured", "organis", "organiz", "signpost", "paragraph", "flow", "introduction", "conclusion", "logical order"])
    public static let referencing = FeedbackTheme(
        id: "referencing", label: "referencing",
        advice: "keep a reference list as you read and check every citation against Harvard style",
        keywords: ["referenc", "citation", "cite", "cited", "harvard", "bibliograph", "sources", "plagiar"])
    public static let evidence = FeedbackTheme(
        id: "evidence", label: "evidence",
        advice: "back each claim with data, a study or a worked example",
        keywords: ["evidence", "empirical", "data", "example", "examples", "support your", "unsupported", "literature", "research"])
    public static let clarity = FeedbackTheme(
        id: "clarity", label: "clarity",
        advice: "leave time to edit for short, plain sentences and define key terms",
        keywords: ["clarity", "clear", "unclear", "concise", "wordy", "expression", "grammar", "spelling", "writing style", "readab", "precise", "definition"])
    public static let argument = FeedbackTheme(
        id: "argument", label: "argument",
        advice: "write a one-sentence thesis first and make each paragraph push it forward",
        keywords: ["argument", "argue", "thesis", "position", "answer the question", "focus on the question", "stance", "coheren", "line of reasoning"])

    public static let catalogue: [FeedbackTheme] = [criticalAnalysis, structure, referencing, evidence, clarity, argument]

    public init(id: String, label: String, advice: String, keywords: [String] = []) {
        self.id = id; self.label = label; self.advice = advice; self.keywords = keywords
    }

    public static func known(_ id: String) -> FeedbackTheme? { catalogue.first { $0.id == id } }
}

/// One theme found in one piece of feedback.
public struct FeedbackPoint: Codable, Hashable, Sendable {
    public var themeID: String
    public var label: String
    /// True for "do more of this / fix this", false for praise.
    public var needsWork: Bool
    public var quote: String

    public init(themeID: String, label: String, needsWork: Bool, quote: String) {
        self.themeID = themeID; self.label = label; self.needsWork = needsWork; self.quote = quote
    }
}

public enum FeedbackThemeExtractor {
    static let negativeCues = ["more", "lack", "lacks", "lacking", "needs", "need to", "needed", "could", "should", "weak",
                               "limited", "improve", "further", "insufficient", "missing", "consider", "better", "not enough",
                               "unclear", "too descriptive", "would benefit", "try to", "absent", "little", "underdeveloped",
                               "inconsistent", "errors", "however", "rather than", "at times", "occasionally"]
    static let positiveCues = ["good", "excellent", "strong", "well", "clear", "impressive", "effective", "thorough", "great",
                               "nicely", "solid", "convincing", "accurate"]

    /// Sentences of the feedback (split on . ! ? ; and new lines).
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            if ".!?;\n•".contains(ch) {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { out.append(t) }
        // "Well structured, but the argument lacks evidence" is two clauses with different tones.
        return out.flatMap { s in
            s.components(separatedBy: ", but ").flatMap { $0.components(separatedBy: " but ") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
    }

    static func contains(_ haystack: String, _ cue: String) -> Bool {
        // Whole-word-ish match for short cues so "clear" doesn't hit "unclear" twice etc.
        if cue.count <= 4 {
            let pattern = "(?<![a-z])" + NSRegularExpression.escapedPattern(for: cue) + "(?![a-z])"
            return haystack.range(of: pattern, options: .regularExpression) != nil
        }
        return haystack.contains(cue)
    }

    /// Keyword heuristics: each sentence mentioning a theme counts; negative cues make it
    /// "needs work", otherwise positive cues make it praise. One point per theme (needs work wins).
    public static func heuristic(_ comments: String) -> [FeedbackPoint] {
        var best: [String: FeedbackPoint] = [:]
        for sentence in sentences(comments) {
            let s = sentence.lowercased()
            for theme in FeedbackTheme.catalogue where theme.keywords.contains(where: { s.contains($0) }) {
                let negative = negativeCues.contains { contains(s, $0) }
                    || s.contains("unclear") || s.contains("descriptive") || s.contains("unsupported")
                let positive = positiveCues.contains { contains(s, $0) }
                guard negative || positive else { continue }
                let point = FeedbackPoint(themeID: theme.id, label: theme.label, needsWork: negative, quote: String(sentence.prefix(200)))
                if let existing = best[theme.id], existing.needsWork || !point.needsWork { continue }
                best[theme.id] = point
            }
        }
        return FeedbackTheme.catalogue.compactMap { best[$0.id] }
    }

    struct LLMReply: Decodable {
        struct Point: Decodable { let theme: String; let needs_work: Bool?; let quote: String? }
        let points: [Point]
    }

    /// AI extraction (local only), falling back to the heuristics if the AI is unavailable
    /// or returns nothing usable.
    public static func extract(_ feedback: AssessmentFeedback, router: LLMRouter?) async -> [FeedbackPoint] {
        guard let router else { return heuristic(feedback.comments) }
        let known = FeedbackTheme.catalogue.map(\.id).joined(separator: ", ")
        let system = """
        You read a university marker's feedback and list the recurring writing/skill themes it raises.
        Use these theme ids when they fit: \(known). Otherwise use a short lower-case label (e.g. "use of diagrams").
        For each theme say whether it needs work (true) or was praised (false), with a short quote.
        Reply with JSON only: {"points": [{"theme": "critical-analysis", "needs_work": true, "quote": "…"}]}
        """
        let user = "Module: \(feedback.moduleCode)\nAssessment: \(feedback.assessmentTitle)\n"
            + (feedback.mark.map { "Mark: \(Int($0.rounded()))%\n" } ?? "") + "Feedback:\n" + String(feedback.comments.prefix(6000))
        do {
            let reply = try await router.completeJSON(LLMReply.self, LLMRequest(
                messages: [.system(system), .user(user)], purpose: .privateData, temperature: 0.1))
            var seen = Set<String>()
            let points = reply.points.compactMap { p -> FeedbackPoint? in
                let raw = p.theme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !raw.isEmpty else { return nil }
                let normalised = raw.replacingOccurrences(of: " ", with: "-")
                let theme = FeedbackTheme.known(normalised)
                    ?? FeedbackTheme.catalogue.first { $0.label == raw || $0.keywords.contains(where: { raw.contains($0) }) }
                let id = theme?.id ?? normalised
                guard seen.insert(id).inserted else { return nil }
                return FeedbackPoint(themeID: id, label: theme?.label ?? raw, needsWork: p.needs_work ?? true,
                                     quote: String((p.quote ?? "").prefix(200)))
            }
            return points.isEmpty ? heuristic(feedback.comments) : points
        } catch {
            return heuristic(feedback.comments)
        }
    }
}

/// The running list of feedback themes across all marked work.
public struct FeedbackLedger: Codable, Hashable, Sendable {
    public struct ThemeRecord: Codable, Hashable, Sendable, Identifiable {
        public var id: String { themeID }
        public var themeID: String
        public var label: String
        /// Times it was raised as needing work / praised.
        public var needsWorkCount: Int
        public var praisedCount: Int
        public var modules: [String]
        public var lastSeen: Date
        public var lastAssessment: String
        public var examples: [String]

        public var isRecurring: Bool { needsWorkCount >= 2 }
    }

    public var themes: [ThemeRecord]
    /// Feedback id → fingerprint already processed.
    public var processed: [String: String]

    public init(themes: [ThemeRecord] = [], processed: [String: String] = [:]) {
        self.themes = themes; self.processed = processed
    }

    public func isNew(_ feedback: AssessmentFeedback) -> Bool { processed[feedback.id] != feedback.fingerprint }

    public mutating func ingest(_ feedback: AssessmentFeedback, points: [FeedbackPoint], now: Date = Date()) {
        guard isNew(feedback) else { return }
        processed[feedback.id] = feedback.fingerprint
        let when = feedback.receivedAt ?? now
        for p in points {
            if let i = themes.firstIndex(where: { $0.themeID == p.themeID }) {
                if p.needsWork { themes[i].needsWorkCount += 1 } else { themes[i].praisedCount += 1 }
                if !themes[i].modules.contains(feedback.moduleCode) { themes[i].modules.append(feedback.moduleCode) }
                if when >= themes[i].lastSeen { themes[i].lastSeen = when; themes[i].lastAssessment = feedback.assessmentTitle }
                if !p.quote.isEmpty { themes[i].examples = Array(([p.quote] + themes[i].examples).prefix(5)) }
            } else {
                themes.append(ThemeRecord(themeID: p.themeID, label: p.label, needsWorkCount: p.needsWork ? 1 : 0,
                                          praisedCount: p.needsWork ? 0 : 1, modules: [feedback.moduleCode], lastSeen: when,
                                          lastAssessment: feedback.assessmentTitle, examples: p.quote.isEmpty ? [] : [p.quote]))
            }
        }
        themes.sort { ($0.needsWorkCount, $0.lastSeen) > ($1.needsWorkCount, $1.lastSeen) }
    }

    /// Themes to work on, most frequent first.
    public var toWorkOn: [ThemeRecord] { themes.filter { $0.needsWorkCount > 0 } }
    public var strengths: [ThemeRecord] { themes.filter { $0.praisedCount > 0 && $0.needsWorkCount == 0 } }

    /// Reminders for planning a new assessment: same-module themes first, then any
    /// recurring theme. "Last time: needed more critical analysis — plan an evaluation paragraph …"
    public func reminders(for assessment: Assessment, limit: Int = 3) -> [String] {
        let relevant = toWorkOn.sorted { a, b in
            let am = a.modules.contains(assessment.moduleCode), bm = b.modules.contains(assessment.moduleCode)
            if am != bm { return am }
            return (a.needsWorkCount, a.lastSeen) > (b.needsWorkCount, b.lastSeen)
        }.filter { $0.modules.contains(assessment.moduleCode) || $0.isRecurring }
        return relevant.prefix(limit).map { r in
            let advice = FeedbackTheme.known(r.themeID)?.advice ?? "plan time to work on it"
            let times = r.needsWorkCount >= 2 ? " (raised \(r.needsWorkCount) times)" : ""
            return "Last time: needed more \(r.label)\(times) — \(advice)."
        }
    }
}
