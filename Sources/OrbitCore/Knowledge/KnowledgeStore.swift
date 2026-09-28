import Foundation

// Orbit's long-term memory on disk (~/Library/Application Support/Orbit/Knowledge):
//
//   course-knowledge.json  every ELE page/file, Ed post, note, slide deck and piece of
//                          feedback as text chunks (the `CourseKnowledgeBase`, which
//                          already skips unchanged text by content hash)
//   summaries.json         one short summary per document, keyed by its content hash
//   profile.json           the student profile (strengths, weak topics, grades…)
//   concepts.json          concept-web links learned from content / the AI
//   practice-ledger.json   every question done or generated (for de-duplication)
//   reading-library.json   reading lists + "reading around", read/unread
//
// Everything is plain JSON written atomically, so a crash never leaves half a file.

public struct KnowledgeStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public enum File: String, CaseIterable, Sendable {
        case courseKnowledge = "course-knowledge.json"
        case summaries = "summaries.json"
        case profile = "profile.json"
        case concepts = "concepts.json"
        case practiceLedger = "practice-ledger.json"
        case readingLibrary = "reading-library.json"
    }

    public func url(_ file: File) -> URL { directory.appendingPathComponent(file.rawValue) }

    public func load<T: Decodable>(_ type: T.Type, _ file: File) -> T? {
        guard let data = try? Data(contentsOf: url(file)) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(T.self, from: data)
    }

    public func save<T: Encodable>(_ value: T, _ file: File) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        try e.encode(value).write(to: url(file), options: .atomic)
    }

    /// Moves a file saved by an older version (e.g. Orbit/course-knowledge.json) into the store once.
    @discardableResult
    public func migrateLegacy(_ legacy: URL, to file: File) -> Bool {
        let fm = FileManager.default
        let target = url(file)
        guard !fm.fileExists(atPath: target.path), fm.fileExists(atPath: legacy.path) else { return false }
        do { try fm.moveItem(at: legacy, to: target); return true } catch {
            return (try? fm.copyItem(at: legacy, to: target)) != nil
        }
    }
}

// MARK: - Summaries

/// One short summary per document, redone only when the document's text changes.
public struct KnowledgeSummaries: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var contentHash: String
        public var summary: String
        public var date: Date
    }
    public var entries: [String: Entry] = [:]
    public init() {}

    public func summary(for documentID: String) -> String? { entries[documentID]?.summary }

    /// Documents whose summary is missing or stale, most useful kinds first.
    public func pending(in kb: CourseKnowledgeBase, limit: Int = 10, minCharacters: Int = 400) -> [CourseDocument] {
        let priority: [CourseDocKind: Int] = [.slides: 0, .lectureNotes: 1, .homework: 2, .handout: 3, .assessmentBrief: 4,
                                              .feedback: 5, .pastPaper: 6, .reading: 7, .readingGuide: 8]
        return kb.documents(moduleCode: nil).filter { d in
            d.text.count >= minCharacters && entries[d.id]?.contentHash != d.contentHash && d.kind != .elePage
        }.sorted { (priority[$0.kind] ?? 9, $1.modified) < (priority[$1.kind] ?? 9, $0.modified) }
            .prefix(limit).map { $0 }
    }

    public mutating func set(_ summary: String, for doc: CourseDocument, date: Date = Date()) {
        entries[doc.id] = Entry(contentHash: doc.contentHash, summary: summary.trimmingCharacters(in: .whitespacesAndNewlines), date: date)
    }

    /// Drops summaries of documents that no longer exist.
    public mutating func prune(keeping ids: Set<String>) { entries = entries.filter { ids.contains($0.key) } }

    /// The request that summarises one document (local model; text stays on the Mac).
    public static func request(for doc: CourseDocument) -> LLMRequest {
        LLMRequest(messages: [
            .system("You summarise university economics course material for a first-year student's revision memory. Write 3-6 bullet points: the key ideas, definitions, formulas and any tasks set. No preamble."),
            .user("\(doc.moduleCode ?? "") \(doc.kind.label): \(doc.title)\n\n\(doc.text.prefix(12_000))"),
        ], purpose: .bulk, temperature: 0.1, maxTokens: 400)
    }
}

// MARK: - Student profile

/// Long-term memory about the student, fed into every AI prompt.
public struct StudentProfile: Codable, Hashable, Sendable {
    public struct TopicMastery: Codable, Hashable, Sendable {
        public var topic: String
        public var moduleCode: String?
        public var attempts: Int
        public var correct: Int
        public var lastSeen: Date
        /// Laplace-smoothed success rate (0…1).
        public var score: Double { Double(correct + 1) / Double(attempts + 2) }
    }

    public struct GradeRecord: Codable, Hashable, Sendable {
        public var moduleCode: String
        public var title: String
        public var mark: Double
        public var date: Date
    }

    public var degree = "BSc Economics, year 1"
    public var goal = "Top first-class marks"
    public var topics: [String: TopicMastery] = [:]
    public var grades: [GradeRecord] = []
    /// Free-form facts to remember ("prefers worked examples", "struggles with Lagrangians").
    public var notes: [String] = []
    public var questionsCompleted = 0
    public var updatedAt: Date = .distantPast

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        degree = (try? c.decode(String.self, forKey: .degree)) ?? degree
        goal = (try? c.decode(String.self, forKey: .goal)) ?? goal
        topics = (try? c.decode([String: TopicMastery].self, forKey: .topics)) ?? [:]
        grades = (try? c.decode([GradeRecord].self, forKey: .grades)) ?? []
        notes = (try? c.decode([String].self, forKey: .notes)) ?? []
        questionsCompleted = (try? c.decode(Int.self, forKey: .questionsCompleted)) ?? 0
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? .distantPast
    }

    static func key(_ topic: String) -> String {
        topic.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    public mutating func recordAttempt(topic: String, moduleCode: String? = nil, correct: Bool, date: Date = Date()) {
        let k = Self.key(topic)
        guard !k.isEmpty else { return }
        var m = topics[k] ?? TopicMastery(topic: topic, moduleCode: moduleCode, attempts: 0, correct: 0, lastSeen: date)
        m.attempts += 1
        if correct { m.correct += 1 }
        m.lastSeen = date
        if m.moduleCode == nil { m.moduleCode = moduleCode }
        topics[k] = m
        questionsCompleted += 1
        updatedAt = date
    }

    /// Adds or updates a grade (same module + title replaces).
    public mutating func recordGrade(moduleCode: String, title: String, mark: Double, date: Date = Date()) {
        grades.removeAll { $0.moduleCode == moduleCode && $0.title == title }
        grades.append(GradeRecord(moduleCode: moduleCode, title: title, mark: mark, date: date))
        grades.sort { $0.date < $1.date }
        updatedAt = date
    }

    public mutating func remember(_ fact: String, limit: Int = 60) {
        let f = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty, !notes.contains(where: { $0.caseInsensitiveCompare(f) == .orderedSame }) else { return }
        notes.append(f)
        if notes.count > limit { notes.removeFirst(notes.count - limit) }
        updatedAt = Date()
    }

    public var strengths: [TopicMastery] {
        topics.values.filter { $0.attempts >= 3 && $0.score >= 0.75 }.sorted { $0.score > $1.score }
    }

    public var weakTopics: [TopicMastery] {
        topics.values.filter { $0.attempts >= 2 && $0.score < 0.5 }.sorted { $0.score < $1.score }
    }

    public func average(moduleCode: String? = nil) -> Double? {
        let g = grades.filter { moduleCode == nil || $0.moduleCode == moduleCode }
        guard !g.isEmpty else { return nil }
        return g.map(\.mark).reduce(0, +) / Double(g.count)
    }

    /// A few lines for the system prompt.
    public func promptSummary() -> String {
        var lines = ["Student: \(degree). Goal: \(goal)."]
        if !strengths.isEmpty { lines.append("Strong at: " + strengths.prefix(6).map(\.topic).joined(separator: ", ") + ".") }
        if !weakTopics.isEmpty {
            lines.append("Needs work on: " + weakTopics.prefix(6).map { "\($0.topic) (\(Int($0.score * 100))%)" }.joined(separator: ", ") + ".")
        }
        if !grades.isEmpty {
            lines.append("Marks so far: " + grades.suffix(6).map { "\($0.moduleCode) \($0.title) \(Int($0.mark.rounded()))%" }.joined(separator: "; ") + ".")
        }
        if questionsCompleted > 0 { lines.append("Practice questions completed: \(questionsCompleted).") }
        if !notes.isEmpty { lines.append("Remember: " + notes.suffix(8).joined(separator: " · ")) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Context for every AI call

/// Builds the "what Orbit knows that's relevant" block added to chat/reasoning prompts.
public enum KnowledgeContext {
    public static let marker = "[Orbit knowledge]"

    /// The text the retrieval should match: the latest user message (plus a little of the one before).
    public static func query(for request: LLMRequest) -> String {
        let users = request.messages.filter { $0.role == .user }.map(\.text)
        return users.suffix(2).joined(separator: "\n").suffix(800).description
    }

    public static func build(query: String, knowledge: CourseKnowledgeBase, profile: StudentProfile?,
                             summaries: KnowledgeSummaries? = nil, graph: ConceptGraph? = nil,
                             limit: Int = 6, budget: Int = 4000, queryEmbedding: [Double]? = nil) -> String {
        var parts: [String] = []
        if let profile { parts.append(profile.promptSummary()) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let hits = knowledge.search(q, limit: limit, queryEmbedding: queryEmbedding)
            if !hits.isEmpty {
                var lines = ["Relevant course material (cite as [source]):"]
                var seen = Set<String>()
                for h in hits {
                    let summary = seen.insert(h.document.id).inserted ? summaries?.summary(for: h.document.id) : nil
                    let body = String(h.text.prefix(700)).replacingOccurrences(of: "\n", with: " ")
                    lines.append("- [\(h.citation)] " + (summary.map { "Summary: \($0.prefix(300)) | " } ?? "") + body)
                }
                parts.append(lines.joined(separator: "\n"))
            }
            if let graph {
                let web = graph.web(forText: q, limit: 6)
                if !web.edges.isEmpty {
                    parts.append("Cross-module links: " + web.edges.prefix(6).map { e in
                        "\(graph.name(e.from)) ↔ \(graph.name(e.to)) (\(e.relation))"
                    }.joined(separator: "; "))
                }
            }
        }
        var text = parts.joined(separator: "\n\n")
        if text.count > budget { text = String(text.prefix(budget)) + "…" }
        return text
    }
}
