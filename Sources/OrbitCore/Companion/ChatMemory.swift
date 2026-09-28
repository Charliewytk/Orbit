import Foundation

/// One searchable thing from anywhere in Orbit (a task, event, email, ELE page, Ed post, note, transaction, grade…).
public struct SearchDocument: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case task, event, mail, ele, ed, note, money, grade, lecture, news, group, chat
        public var label: String {
            switch self {
            case .task: "Task"; case .event: "Calendar"; case .mail: "Mail"; case .ele: "ELE"; case .ed: "Ed"
            case .note: "Notes"; case .money: "Money"; case .grade: "Grades"; case .lecture: "Lecture"
            case .news: "News"; case .group: "Group"; case .chat: "Earlier chat"
            }
        }
    }
    public var id: String
    public var kind: Kind
    public var title: String
    public var text: String
    public var date: Date?
    /// URL or in-app reference for the citation.
    public var ref: String?

    public init(id: String, kind: Kind, title: String, text: String, date: Date? = nil, ref: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.text = text; self.date = date; self.ref = ref
    }
}

public struct SearchHit: Hashable, Sendable {
    public var document: SearchDocument
    public var score: Double
    public var snippet: String
}

/// Simple BM25-style ranking over everything, good enough for thousands of items in memory.
public struct UniversalSearch: Sendable {
    public var documents: [SearchDocument]
    public init(documents: [SearchDocument]) { self.documents = documents }

    static func terms(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 && !LectureDigester.stopwords.contains($0) }
    }

    public func search(_ query: String, kinds: Set<SearchDocument.Kind>? = nil, limit: Int = 8, now: Date = Date()) -> [SearchHit] {
        let q = Self.terms(query)
        guard !q.isEmpty else { return [] }
        let pool = documents.filter { kinds?.contains($0.kind) ?? true }
        let n = Double(max(1, pool.count))
        var df: [String: Int] = [:]
        let tokenised = pool.map { d -> [String: Int] in
            var tf: [String: Int] = [:]
            for t in Self.terms(d.title + " " + d.title + " " + d.text) { tf[t, default: 0] += 1 }
            for t in Set(q) where tf[t] != nil { df[t, default: 0] += 1 }
            return tf
        }
        var hits: [SearchHit] = []
        for (d, tf) in zip(pool, tokenised) {
            var s = 0.0
            for t in q {
                guard let f = tf[t] else { continue }
                let idf = log(1 + (n - Double(df[t] ?? 0) + 0.5) / (Double(df[t] ?? 0) + 0.5))
                s += idf * (Double(f) * 2.2) / (Double(f) + 1.2)
            }
            guard s > 0 else { continue }
            if d.title.lowercased().contains(query.lowercased()) { s += 2 }
            if let date = d.date { s += max(0, 1 - abs(now.timeIntervalSince(date)) / (60 * 86400)) * 0.5 }
            hits.append(SearchHit(document: d, score: s, snippet: Self.snippet(d.text, terms: q)))
        }
        return hits.sorted { ($0.score, $1.document.id) > ($1.score, $0.document.id) }.prefix(limit).map { $0 }
    }

    static func snippet(_ text: String, terms: [String], width: Int = 160) -> String {
        let lower = text.lowercased()
        guard let r = terms.compactMap({ lower.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return String(text.prefix(width))
        }
        let offset = lower.distance(from: lower.startIndex, to: r.lowerBound)
        let start = text.index(text.startIndex, offsetBy: max(0, offset - width / 3))
        let end = text.index(start, offsetBy: min(width, text.distance(from: start, to: text.endIndex)))
        return (start > text.startIndex ? "…" : "") + text[start..<end].replacingOccurrences(of: "\n", with: " ") + (end < text.endIndex ? "…" : "")
    }

    /// Numbered results for the model: "[1] Mail · Subject (12 Oct): snippet".
    public static func citedText(_ hits: [SearchHit], calendar: DayCalendar) -> String {
        guard !hits.isEmpty else { return "No matches anywhere in Orbit." }
        let rows = hits.enumerated().map { i, h in
            "[\(i + 1)] \(h.document.kind.label) · \(h.document.title)" + (h.document.date.map { " (\(calendar.shortDay($0)))" } ?? "")
                + ": \(h.snippet)" + (h.document.ref.map { " <\($0)>" } ?? "")
        }
        return rows.joined(separator: "\n") + "\nCite sources in your answer as [n]."
    }

    public static func tool(calendar: DayCalendar, documents: @escaping @Sendable () async -> [SearchDocument]) -> AssistantTool {
        AssistantTool(name: "search_everything",
                      description: "Search across tasks, calendar, mail, ELE, Ed, notes, money, grades, lectures, news and earlier chats. Returns numbered sources; cite them as [n].",
                      arguments: ["query": "what to look for", "kind": "optional: task, event, mail, ele, ed, note, money, grade, lecture, news, group, chat"]) { args in
            let query = args["query"]?.string ?? ""
            let kinds = args["kind"]?.string.flatMap { SearchDocument.Kind(rawValue: $0.lowercased()) }.map { Set([$0]) }
            let hits = UniversalSearch(documents: await documents()).search(query, kinds: kinds)
            return citedText(hits, calendar: calendar)
        }
    }
}

/// Conversation history kept on disk (JSON in Application Support), searchable and resumable.
public struct ChatArchive: Codable, Hashable, Sendable {
    public struct Message: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var role: AssistantTurn.Role
        public var text: String
        public var date: Date
        public var citations: [String]
        public init(id: String = UUID().uuidString, role: AssistantTurn.Role, text: String, date: Date = Date(), citations: [String] = []) {
            self.id = id; self.role = role; self.text = text; self.date = date; self.citations = citations
        }
    }

    public var messages: [Message] = []
    public init(messages: [Message] = []) { self.messages = messages }

    public mutating func append(_ m: Message, cap: Int = 5000) {
        messages.append(m)
        if messages.count > cap { messages.removeFirst(messages.count - cap) }
    }

    /// Recent turns for the assistant's history.
    public func recentTurns(_ n: Int = 12) -> [AssistantTurn] {
        messages.suffix(n).map { AssistantTurn(role: $0.role, text: $0.text, date: $0.date) }
    }

    /// Past Q&A pairs as searchable documents (so the chat "remembers").
    public var searchDocuments: [SearchDocument] {
        var out: [SearchDocument] = []
        var lastQuestion: Message?
        for m in messages {
            if m.role == .user { lastQuestion = m; continue }
            guard let q = lastQuestion else { continue }
            out.append(SearchDocument(id: "chat|\(m.id)", kind: .chat, title: String(q.text.prefix(80)), text: "Q: \(q.text)\nA: \(m.text)", date: m.date))
            lastQuestion = nil
        }
        return out
    }

    /// "[3]" markers used in an answer.
    public static func citationNumbers(in text: String) -> [Int] {
        guard let re = try? NSRegularExpression(pattern: "\\[(\\d{1,2})\\]") else { return [] }
        let ns = text as NSString
        var seen = Set<Int>(), out: [Int] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let n = Int(ns.substring(with: m.range(at: 1))), seen.insert(n).inserted { out.append(n) }
        }
        return out
    }
}
