import Foundation

/// A slide topic the notes don't seem to cover.
public struct MissedTopic: Codable, Hashable, Sendable {
    public var topic: String
    public var slides: [Int]
    /// One line on what the slides say about it (from the AI, when it ran).
    public var detail: String?

    public init(topic: String, slides: [Int], detail: String? = nil) {
        self.topic = topic; self.slides = slides; self.detail = detail
    }

    /// "slides 12–15", "slide 3", "slides 3, 7".
    public var slideText: String { NotesReview.slideRange(slides) }
}

/// A question the student wrote in their notes.
public struct NoteQuestion: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var noteID: String
    public var noteTitle: String

    public init(id: String, text: String, noteID: String, noteTitle: String) {
        self.id = id; self.text = text; self.noteID = noteID; self.noteTitle = noteTitle
    }
}

public struct KBCitation: Codable, Hashable, Sendable {
    public var index: Int
    public var documentID: String
    public var title: String
    public var moduleCode: String?
    public var week: Int?
    public var kind: CourseDocKind
    public var slide: Int?

    /// "BEE1022 week 2 · Lecture 2 slides, slide 14".
    public var text: String {
        ([moduleCode, week.map { "week \($0)" }].compactMap { $0 }.joined(separator: " ") + " · \(title)"
            + (slide.map { ", slide \($0)" } ?? "")).trimmingCharacters(in: CharacterSet(charactersIn: " ·"))
    }
}

public struct AnsweredQuestion: Codable, Hashable, Sendable {
    public var question: NoteQuestion
    public var answer: String?
    public var citations: [KBCitation]
    public var answeredAt: Date?
    /// True when the course materials had nothing on it.
    public var notFound: Bool

    public init(question: NoteQuestion, answer: String? = nil, citations: [KBCitation] = [], answeredAt: Date? = nil,
                notFound: Bool = false) {
        self.question = question; self.answer = answer; self.citations = citations; self.answeredAt = answeredAt
        self.notFound = notFound
    }

    public var isAnswered: Bool { answeredAt != nil }
}

/// The review of one module-week's notes against its slides.
public struct LectureReview: Codable, Hashable, Sendable, Identifiable {
    /// "BEE1022-t1-w2", or "note-<id>" for notes with no week.
    public var id: String
    public var moduleCode: String
    public var term: Int?
    public var week: Int?
    public var title: String
    public var lectureIDs: [String]
    public var noteIDs: [String]
    public var slideDocumentIDs: [String]
    /// Share of the slides' topics found in the notes (0–1); nil without slides.
    public var coverage: Double?
    public var missed: [MissedTopic]
    public var questions: [AnsweredQuestion]
    /// Fingerprint of the notes + slides the missed-content check used.
    public var inputHash: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, moduleCode: String, term: Int? = nil, week: Int? = nil, title: String, lectureIDs: [String] = [],
                noteIDs: [String] = [], slideDocumentIDs: [String] = [], coverage: Double? = nil, missed: [MissedTopic] = [],
                questions: [AnsweredQuestion] = [], inputHash: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.moduleCode = moduleCode; self.term = term; self.week = week; self.title = title
        self.lectureIDs = lectureIDs; self.noteIDs = noteIDs; self.slideDocumentIDs = slideDocumentIDs
        self.coverage = coverage; self.missed = missed; self.questions = questions; self.inputHash = inputHash
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public static func id(moduleCode: String, term: Int?, week: Int?, noteID: String? = nil) -> String {
        if let week { return "\(moduleCode)-t\(term ?? 1)-w\(week)" }
        return "note-\(noteID ?? moduleCode)"
    }

    var place: String {
        guard let week else { return "\(moduleCode) “\(title)”" }
        return (term ?? 1) > 1 ? "\(moduleCode) T\(term!) week \(week)" : "\(moduleCode) week \(week)"
    }

    /// "BEE1022 week 2: you may have missed 'sampling distributions' (slides 12–15)".
    public var missedNotification: (title: String, body: String)? {
        guard let first = missed.first else { return nil }
        var body = "You may have missed ‘\(first.topic)’ (\(first.slideText))"
        if missed.count > 1 {
            body += " and " + (missed.count == 2 ? "‘\(missed[1].topic)’ (\(missed[1].slideText))" : "\(missed.count - 1) more topics")
        }
        return ("\(place): notes vs slides", body + ".")
    }

    /// "Answered 2 questions from your BEE1032 notes".
    public func answeredNotification(newlyAnswered: Int) -> (title: String, body: String)? {
        guard newlyAnswered > 0 else { return nil }
        let q = questions.filter { $0.isAnswered && !$0.notFound }.prefix(1).first
        let title = "Answered \(newlyAnswered) question\(newlyAnswered == 1 ? "" : "s") from your \(moduleCode) notes"
        return (title, q.map { "“\($0.question.text)” — \(String(($0.answer ?? "").prefix(140)))" } ?? place)
    }

    /// Plain text for chat.
    public func text() -> String {
        var lines = ["\(place) — \(title)"]
        if let c = coverage { lines.append("Slide coverage: \(Int((c * 100).rounded()))%") }
        if missed.isEmpty { lines.append(coverage == nil ? "No slides to compare yet." : "Nothing obvious missing from your notes.") }
        for m in missed { lines.append("• May have missed: \(m.topic) (\(m.slideText))\(m.detail.map { " — \($0)" } ?? "")") }
        for q in questions {
            lines.append("Q: \(q.question.text)")
            if let a = q.answer { lines.append("A: \(a)") }
            if !q.citations.isEmpty { lines.append("   Sources: " + q.citations.map(\.text).joined(separator: "; ")) }
        }
        return lines.joined(separator: "\n")
    }
}

public struct MissedContentResult: Hashable, Sendable {
    public var missed: [MissedTopic]
    /// Share of slide topics covered by the notes (0–1).
    public var coverage: Double
    public var topicCount: Int
    public var usedAI: Bool
}

/// Compares lecture notes with the lecture's slides, and answers questions the
/// student wrote in their notes from the course materials. Uses `.privateData`
/// so notes stay on the Mac.
public enum NotesReview {
    // MARK: Topics from slides

    public struct SlideTopic: Hashable, Sendable {
        public var topic: String
        public var slides: [Int]
        public var isHeading: Bool
    }

    static let genericTitles: Set<String> = [
        "outline", "overview", "summary", "agenda", "contents", "introduction", "intro", "questions", "any questions",
        "references", "reading", "readings", "further reading", "learning outcomes", "learning objectives", "objectives",
        "thank you", "thanks", "recap", "last week", "this week", "today", "plan", "plan for today", "example", "examples",
        "exercise", "exercises", "activity", "discussion", "break", "welcome", "conclusion", "conclusions", "key points",
        "next week", "admin", "housekeeping", "announcements",
    ]

    static func cleanTitle(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\s*\\((?:cont(?:inued|'d|d)?\\.?)\\)\\s*$", with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "\\s*[-–:]\\s*(?:cont(?:inued|'d|d)?\\.?|part\\s*\\d+|\\d+)\\s*$", with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "\\s+\\d+/\\d+\\s*$", with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:")))
    }

    static func isGeneric(_ title: String) -> Bool {
        let t = title.lowercased()
        if t.isEmpty || genericTitles.contains(t) { return true }
        if UniRegex.first("^(week|lecture|session|topic)\\s*\\d+$", in: t) != nil { return true }
        if UniRegex.first("^[A-Z]{3}\\d{4}\\b", in: title, caseInsensitive: false) != nil && t.count < 30 { return true }
        return NoteIndex.terms(t).isEmpty
    }

    /// Topics a deck teaches: its slide titles (merged across "(cont.)" slides) plus
    /// terms repeated in the body of two or more slides.
    public static func topics(in deck: SlideDeckText, maxBodyTopics: Int = 10) -> [SlideTopic] {
        var headings: [String: SlideTopic] = [:]
        var order: [String] = []
        let titles = deck.slides.map { cleanTitle($0.title) }
        let titleCounts = titles.reduce(into: [String: Int]()) { $0[$1.lowercased(), default: 0] += 1 }
        for (s, title) in zip(deck.slides, titles) {
            // Skip generic titles, the cover slide, and a title repeated on most slides (a running header).
            guard !isGeneric(title), s.number != 1 || deck.slides.count <= 2,
                  (titleCounts[title.lowercased()] ?? 0) <= max(3, deck.slides.count / 3) else { continue }
            let key = NoteIndex.terms(title).joined(separator: " ")
            if headings[key] == nil { order.append(key); headings[key] = SlideTopic(topic: title, slides: [], isHeading: true) }
            headings[key]!.slides.append(s.number)
        }
        var out = order.compactMap { headings[$0] }

        // Body phrases: bigrams of content words found on 2+ slides.
        var phraseSlides: [String: Set<Int>] = [:]
        var display: [String: String] = [:]
        let headingTerms = Set(out.flatMap { NoteIndex.terms($0.topic) })
        for s in deck.slides {
            for line in s.lines {
                let words = line.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-") }).map(String.init)
                let content = words.filter { $0.count > 2 && !NoteIndex.stopwords.contains($0.lowercased()) && !$0.allSatisfy(\.isNumber) }
                guard content.count >= 2 else { continue }
                for i in 0..<(content.count - 1) {
                    let pair = [content[i], content[i + 1]]
                    let key = pair.map { NoteIndex.stem($0.lowercased()) }.joined(separator: " ")
                    phraseSlides[key, default: []].insert(s.number)
                    if display[key] == nil { display[key] = pair.joined(separator: " ").lowercased() }
                }
            }
        }
        let body = phraseSlides.filter { $0.value.count >= 2 }
            .filter { !Set($0.key.split(separator: " ").map(String.init)).isSubset(of: headingTerms) }
            .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            .prefix(maxBodyTopics)
        out += body.map { SlideTopic(topic: display[$0.key] ?? $0.key, slides: $0.value.sorted(), isHeading: false) }
        return out
    }

    // MARK: Coverage

    /// Stemmed words of the notes, for fuzzy matching.
    struct NoteVocabulary {
        var stems: Set<String>
        var prefixes: Set<String>
        var words: [String]

        init(_ text: String) {
            let terms = NoteIndex.terms(text)
            stems = Set(terms)
            prefixes = Set(terms.filter { $0.count >= 6 }.map { String($0.prefix(5)) })
            words = Array(stems.filter { $0.count >= 5 })
        }

        /// Exact stem, shared 5-letter prefix (e.g. "distribut…"), or one edit away (OCR slips).
        func contains(_ term: String) -> Bool {
            if stems.contains(term) { return true }
            if term.count >= 6, prefixes.contains(String(term.prefix(5))) { return true }
            if term.count >= 5 { return words.contains { abs($0.count - term.count) <= 1 && NotesReview.editDistance($0, term, limit: 1) <= 1 } }
            return false
        }
    }

    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > limit { return limit + 1 }
        var prev = Array(0...y.count)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var cur = [i] + Array(repeating: 0, count: y.count)
            var rowMin = cur[0]
            for j in 1...max(1, y.count) where !y.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            prev = cur
        }
        return x.isEmpty ? y.count : prev[y.count]
    }

    /// True when most of a topic's words appear (fuzzily) in the notes.
    static func covered(_ topic: String, _ vocab: NoteVocabulary) -> Bool {
        let terms = NoteIndex.terms(topic)
        guard !terms.isEmpty else { return true }
        let hits = terms.filter(vocab.contains).count
        return Double(hits) / Double(terms.count) >= (terms.count <= 2 ? 0.99 : 0.6)
    }

    /// The deterministic check: topics in the slides that the notes don't mention.
    public static func coverageCheck(notesText: String, deck: SlideDeckText) -> MissedContentResult {
        let topics = topics(in: deck)
        guard !topics.isEmpty else { return MissedContentResult(missed: [], coverage: 1, topicCount: 0, usedAI: false) }
        let vocab = NoteVocabulary(notesText)
        let missing = topics.filter { !covered($0.topic, vocab) }
        // Weight headings double: they're what the lecture was about.
        let total = topics.reduce(0.0) { $0 + ($1.isHeading ? 2 : 1) }
        let lost = missing.reduce(0.0) { $0 + ($1.isHeading ? 2 : 1) }
        let ranked = missing.sorted { a, b in
            (a.isHeading ? 1 : 0, a.slides.count, -(a.slides.first ?? 0)) > (b.isHeading ? 1 : 0, b.slides.count, -(b.slides.first ?? 0))
        }
        return MissedContentResult(missed: ranked.prefix(8).map { MissedTopic(topic: $0.topic, slides: $0.slides) },
                                   coverage: max(0, 1 - lost / total), topicCount: topics.count, usedAI: false)
    }

    struct AIReply: Decodable {
        struct Item: Decodable { var topic: String; var slides: [Int]?; var why: String? }
        var missed: [Item]
    }

    /// Topics in the slides not covered by the notes: the key-term check first, then the
    /// local AI (if given) confirms and phrases a short "you may have missed" list.
    public static func missedContent(notes: [LectureNote], slides deck: SlideDeckText, router: LLMRouter?,
                                     purpose: LLMPurpose = .privateData) async -> MissedContentResult {
        let notesText = notes.map { "\($0.title)\n\($0.allText)" }.joined(separator: "\n\n")
        var result = coverageCheck(notesText: notesText, deck: deck)
        guard let router, !result.missed.isEmpty else { return result }
        let candidates = result.missed.map { "- \($0.topic) (slides \($0.slides.map(String.init).joined(separator: ", ")))" }.joined(separator: "\n")
        let wanted = Set(result.missed.flatMap(\.slides))
        let slideText = deck.slides.filter { wanted.contains($0.number) }.map { s in
            "Slide \(s.number): \(s.title)\n" + s.lines.prefix(8).joined(separator: "\n")
        }.joined(separator: "\n\n")
        let system = """
        You compare a university student's lecture notes with the lecture slides. You get candidate topics that a \
        keyword check could not find in the notes. Keep only topics that are really absent from the notes (the notes \
        may use different words, abbreviations or handwriting transcription errors — if the idea is there, drop it). \
        Reply with JSON only: {"missed":[{"topic":"sampling distributions","slides":[12,13],"why":"one short line on what the slides say"}]}. \
        At most 5 items, most important first. Short lowercase topic names. UK English.
        """
        let user = "CANDIDATES:\n\(candidates)\n\nSLIDES:\n\(slideText.prefix(6000))\n\nNOTES:\n\(notesText.prefix(7000))"
        do {
            let reply = try await router.completeJSON(AIReply.self, LLMRequest(messages: [.system(system), .user(user)],
                                                                                purpose: purpose, json: true, temperature: 0))
            let allowed = Set(deck.slides.map(\.number))
            result.missed = reply.missed.prefix(5).map { item in
                let slides = (item.slides ?? []).filter(allowed.contains)
                let fallback = result.missed.first { $0.topic.lowercased() == item.topic.lowercased() }?.slides ?? []
                return MissedTopic(topic: item.topic.trimmingCharacters(in: .whitespacesAndNewlines),
                                   slides: slides.isEmpty ? fallback : slides.sorted(), detail: item.why)
            }.filter { !$0.topic.isEmpty }
            result.usedAI = true
        } catch {
            // Keep the keyword result.
        }
        return result
    }

    // MARK: Questions

    /// Questions the student wrote: lines ending "?", "Q:"/"Question:" lines, "ask …" reminders,
    /// and lines flagged with "(?)" or "??".
    public static func extractQuestions(_ note: LectureNote) -> [NoteQuestion] {
        var out: [NoteQuestion] = []
        var seen = Set<String>()
        for segment in note.segments where segment.kind == .typed || segment.kind == .handwriting {
            for raw in segment.text.components(separatedBy: .newlines) {
                var line = raw.trimmingCharacters(in: .whitespaces)
                line = line.replacingOccurrences(of: "^([-*•–>]|\\d+[.)])\\s*", with: "", options: .regularExpression)
                guard line.count >= 8, line.count <= 300, !line.hasPrefix("#") else { continue }
                guard let q = question(from: line) else { continue }
                let key = NoteIndex.terms(q).joined(separator: " ")
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                out.append(NoteQuestion(id: String(MD5.hex("\(note.id)|\(key)").prefix(16)), text: q, noteID: note.id, noteTitle: note.title))
            }
        }
        return out
    }

    static func question(from line: String) -> String? {
        let lower = line.lowercased()
        if let m = UniRegex.first("^(?:q|qu|question|qn)\\s*\\d*\\s*[:.)\\-]\\s*(.+)$", in: line) { return finish(m[1] ?? "") }
        if let m = UniRegex.first("^(?:ask|check|look\\s+up|find\\s+out|clarify|confused\\s+about|not\\s+sure\\s+(?:about|why|how|what))\\b[:\\s]+(.+)$", in: line) {
            var rest = (m[1] ?? "").trimmingCharacters(in: .whitespaces)
            rest = rest.replacingOccurrences(of: "^(?:the\\s+)?(?:lecturer|tutor|prof(?:essor)?|in\\s+(?:the\\s+)?(?:tutorial|seminar))\\s+(?:about\\s+|whether\\s+|why\\s+|how\\s+)?",
                                             with: "", options: [.regularExpression, .caseInsensitive])
            return rest.count >= 4 ? finish(rest) : nil
        }
        if line.hasSuffix("?") || lower.contains("(?)") || lower.contains("??") {
            let cleaned = line.replacingOccurrences(of: "\\(\\?\\)|\\?{2,}", with: "?", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            // Rhetorical slide headings like "Why?" alone aren't useful.
            guard NoteIndex.terms(cleaned).count >= 2 else { return nil }
            return finish(cleaned)
        }
        return nil
    }

    static func finish(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "\\s*\\?+\\s*$", with: "", options: .regularExpression)
        guard let first = t.first else { return t }
        return first.uppercased() + t.dropFirst() + "?"
    }

    // MARK: Answers

    /// Answers a note question from the course materials (slides, readings, briefs, notes),
    /// citing module, week and resource.
    public static func answer(_ question: NoteQuestion, kb: CourseKnowledgeBase, router: LLMRouter, moduleCode: String? = nil,
                              week: Int? = nil, embedder: NoteEmbedder? = nil, purpose: LLMPurpose = .privateData,
                              now: Date = Date()) async -> AnsweredQuestion {
        var hits: [KBHit]
        if let embedder { hits = await kb.search(question.text, moduleCode: moduleCode, limit: 6, embedder: embedder) }
        else { hits = kb.search(question.text, moduleCode: moduleCode, limit: 6) }
        // Prefer material from the same week, then the rest of the module, then everything.
        if let week { hits.sort { ($0.document.week == week ? 1 : 0, $0.score) > ($1.document.week == week ? 1 : 0, $1.score) } }
        if hits.isEmpty, moduleCode != nil { hits = kb.search(question.text, limit: 6) }
        // Don't answer from the very note the question is in.
        hits = hits.filter { $0.document.id != "note:\(question.noteID)" || hits.count == 1 }
        guard !hits.isEmpty else {
            return AnsweredQuestion(question: question, answer: "I couldn't find this in your course materials — worth asking in the tutorial.",
                                    answeredAt: now, notFound: true)
        }
        var sources = ""
        for (n, h) in hits.enumerated() {
            sources += "[\(n + 1)] \(h.citation)\n\(h.text.prefix(1200))\n\n"
        }
        let system = """
        You answer a first-year economics student's question from their own course materials, given below as numbered \
        sources (lecture slides, handouts, readings, assessment briefs and their notes). Answer in 2–5 sentences, in UK English, \
        explaining clearly as a good tutor would. Cite sources inline like [1] or [2][3]. If the sources don't cover it, say so \
        briefly and give your best short explanation, marked as not from the materials.
        """
        do {
            let text = try await router.complete(LLMRequest(messages: [.system(system), .user("Sources:\n\n\(sources)Question: \(question.text)")],
                                                            purpose: purpose, temperature: 0.2))
            return AnsweredQuestion(question: question, answer: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                    citations: citations(in: text, hits: hits), answeredAt: now)
        } catch {
            return AnsweredQuestion(question: question)
        }
    }

    static func citations(in text: String, hits: [KBHit]) -> [KBCitation] {
        var seen = Set<Int>(), out: [KBCitation] = []
        for m in UniRegex.matches("\\[(\\d{1,2})\\]", in: text) {
            guard let n = m[1].flatMap(Int.init), (1...hits.count).contains(n), seen.insert(n).inserted else { continue }
            let d = hits[n - 1].document
            out.append(KBCitation(index: n, documentID: d.id, title: d.title, moduleCode: d.moduleCode, week: d.week,
                                  kind: d.kind, slide: hits[n - 1].slide))
        }
        return out
    }

    // MARK: Whole review

    /// Reviews one module-week: missed content (re-run only when the notes or slides
    /// changed) and answers to new questions (already-answered ones are kept, never re-asked).
    public static func review(moduleCode: String, term: Int?, week: Int?, title: String, lectureIDs: [String] = [],
                              notes: [LectureNote], slides: [CourseDocument], kb: CourseKnowledgeBase, router: LLMRouter?,
                              previous: LectureReview?, embedder: NoteEmbedder? = nil, maxNewAnswers: Int = 4,
                              now: Date = Date()) async -> LectureReview {
        let id = LectureReview.id(moduleCode: moduleCode, term: term, week: week, noteID: notes.first?.id)
        let hash = MD5.hex(notes.map { "\($0.id)|\($0.allText)" }.sorted().joined(separator: "¦")
                           + slides.map(\.contentHash).sorted().joined())
        var review = previous ?? LectureReview(id: id, moduleCode: moduleCode, term: term, week: week, title: title, createdAt: now)
        review.title = title
        review.lectureIDs = Array(Set(review.lectureIDs + lectureIDs)).sorted()
        review.noteIDs = notes.map(\.id)
        review.slideDocumentIDs = slides.map(\.id)
        if review.inputHash != hash {
            if slides.isEmpty {
                review.coverage = nil; review.missed = []
            } else {
                let deck = SlideDeckText(slides: slides.flatMap { SlideDeckText.parse($0.text).slides })
                let result = await missedContent(notes: notes, slides: deck, router: router)
                review.coverage = result.coverage
                review.missed = result.missed
            }
            review.inputHash = hash
        }
        // Questions: keep answered ones, add new ones, answer a few per run.
        let found = notes.flatMap(extractQuestions)
        var byID = Dictionary(review.questions.map { ($0.question.id, $0) }, uniquingKeysWith: { a, _ in a })
        var answered = 0
        for q in found {
            if byID[q.id]?.isAnswered == true { continue }
            if let router, answered < maxNewAnswers {
                byID[q.id] = await answer(q, kb: kb, router: router, moduleCode: moduleCode, week: week, embedder: embedder, now: now)
                if byID[q.id]?.isAnswered == true { answered += 1 }
            } else if byID[q.id] == nil {
                byID[q.id] = AnsweredQuestion(question: q)
            }
        }
        let order = found.map(\.id)
        review.questions = order.compactMap { byID[$0] } + byID.values.filter { !order.contains($0.question.id) && $0.isAnswered }
        review.updatedAt = now
        return review
    }

    /// "slides 12–15", "slide 3", "slides 3, 7–8".
    public static func slideRange(_ slides: [Int]) -> String {
        let s = Array(Set(slides)).sorted()
        guard !s.isEmpty else { return "the slides" }
        var parts: [String] = []
        var start = s[0], prev = s[0]
        for n in s.dropFirst() {
            if n == prev + 1 { prev = n; continue }
            parts.append(start == prev ? "\(start)" : "\(start)–\(prev)")
            start = n; prev = n
        }
        parts.append(start == prev ? "\(start)" : "\(start)–\(prev)")
        return (s.count == 1 ? "slide " : "slides ") + parts.joined(separator: ", ")
    }
}
