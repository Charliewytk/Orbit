import Foundation

/// Anything that turns text into embedding vectors. `OllamaProvider` conforms (runs locally).
public protocol NoteEmbedder: Sendable {
    func embed(_ texts: [String]) async throws -> [[Double]]
}

extension OllamaProvider: NoteEmbedder {}

/// A searchable slice of a note (~800 characters).
public struct IndexedNoteChunk: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var noteID: String
    public var noteTitle: String
    public var moduleCode: String?
    public var week: Int?
    public var kind: NoteSegmentKind
    /// "Title › Key points › Nearest heading", repeated on every chunk so context isn't lost.
    public var heading: String
    public var text: String
    public var modified: Date
    public var embedding: [Double]?
}

public struct NoteSearchHit: Hashable, Sendable {
    public var chunk: IndexedNoteChunk
    /// Combined 0–1 score used for ranking.
    public var score: Double
    public var keywordScore: Double
    public var semanticScore: Double?
    public var snippet: String
}

public struct NoteCitation: Codable, Hashable, Sendable {
    /// The [n] number used in the answer.
    public var index: Int
    public var noteID: String
    public var title: String
    public var moduleCode: String?
    public var week: Int?
}

public struct NoteAnswer: Sendable {
    public var text: String
    public var citations: [NoteCitation]
    public var hits: [NoteSearchHit]
}

/// Search over all notes, handwritten or typed: BM25 keyword ranking in pure Swift,
/// optionally blended with embedding similarity. Codable, so it can be saved to disk
/// on the Mac (note text stays local).
public struct NoteIndex: Codable, Sendable {
    public private(set) var chunks: [IndexedNoteChunk] = []
    var termFreqs: [[String: Int]] = []
    var lengths: [Int] = []
    var docFreq: [String: Int] = [:]

    public var chunkSize: Int
    public var overlap: Int
    public var k1: Double
    public var b: Double
    /// Weight of embedding similarity when both scores are available (0–1).
    public var semanticWeight: Double
    /// Typed key points rank a little higher than handwriting of equal relevance.
    public var typedBoost: Double

    public init(chunkSize: Int = 800, overlap: Int = 150, k1: Double = 1.2, b: Double = 0.75,
                semanticWeight: Double = 0.5, typedBoost: Double = 1.15) {
        self.chunkSize = chunkSize; self.overlap = overlap; self.k1 = k1; self.b = b
        self.semanticWeight = semanticWeight; self.typedBoost = typedBoost
    }

    public var noteIDs: Set<String> { Set(chunks.map(\.noteID)) }
    public var isEmpty: Bool { chunks.isEmpty }

    // MARK: Adding and removing

    /// Adds a note, replacing any earlier version of it.
    public mutating func add(_ note: LectureNote) {
        remove(noteID: note.id)
        for chunk in Self.chunk(note, size: chunkSize, overlap: overlap) {
            let tf = Self.termCounts(chunk.heading + " " + chunk.text)
            chunks.append(chunk)
            termFreqs.append(tf)
            lengths.append(tf.values.reduce(0, +))
            for term in tf.keys { docFreq[term, default: 0] += 1 }
        }
    }

    public mutating func add(_ notes: [LectureNote]) { for n in notes { add(n) } }

    public mutating func remove(noteID: String) {
        let drop = Set(chunks.indices.filter { chunks[$0].noteID == noteID })
        guard !drop.isEmpty else { return }
        for i in drop {
            for term in termFreqs[i].keys {
                docFreq[term, default: 1] -= 1
                if docFreq[term] == 0 { docFreq[term] = nil }
            }
        }
        let keep = chunks.indices.filter { !drop.contains($0) }
        chunks = keep.map { chunks[$0] }
        termFreqs = keep.map { termFreqs[$0] }
        lengths = keep.map { lengths[$0] }
    }

    /// Embeds chunks that don't have a vector yet. Returns how many were embedded.
    @discardableResult
    public mutating func embedMissing(using embedder: NoteEmbedder, batchSize: Int = 32) async throws -> Int {
        let todo = chunks.indices.filter { chunks[$0].embedding == nil }
        var done = 0
        for start in stride(from: 0, to: todo.count, by: max(1, batchSize)) {
            let batch = Array(todo[start..<min(start + batchSize, todo.count)])
            let vectors = try await embedder.embed(batch.map { chunks[$0].heading + "\n" + chunks[$0].text })
            for (i, v) in zip(batch, vectors) { chunks[i].embedding = v; done += 1 }
        }
        return done
    }

    // MARK: Chunking

    static func label(_ kind: NoteSegmentKind) -> String {
        switch kind {
        case .typed: "Key points"
        case .handwriting: "Lecture detail"
        case .math: "Maths"
        case .diagram: "Diagram"
        }
    }

    /// Splits a note into chunks of about `size` characters with `overlap`, one run of
    /// same-kind segments at a time, carrying the nearest "#" heading along.
    static func chunk(_ note: LectureNote, size: Int, overlap: Int) -> [IndexedNoteChunk] {
        var runs: [(kind: NoteSegmentKind, text: String)] = []
        for s in note.segments where !s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if runs.last?.kind == s.kind { runs[runs.count - 1].text += "\n" + s.text } else { runs.append((s.kind, s.text)) }
        }
        var out: [IndexedNoteChunk] = []
        for run in runs {
            var heading: String?
            var chunkHeading: String?
            var current: [String] = []
            var length = 0
            /// False while `current` holds only the overlap carried from the previous chunk.
            var fresh = false
            func emit() {
                let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                let head = ([note.title, label(run.kind)] + [chunkHeading].compactMap { $0 }).joined(separator: " › ")
                out.append(IndexedNoteChunk(id: "\(note.id)#\(out.count)", noteID: note.id, noteTitle: note.title,
                                            moduleCode: note.moduleCode, week: note.week, kind: run.kind,
                                            heading: head, text: text, modified: note.modified))
                // Start the next chunk with the tail of this one.
                var tail: [String] = [], tailLength = 0
                for piece in current.reversed() where tailLength + piece.count <= overlap {
                    tail.insert(piece, at: 0); tailLength += piece.count + 1
                }
                current = tail; length = tailLength; fresh = false
                chunkHeading = heading
            }
            for line in pieces(run.text, maxLength: max(80, size / 2)) {
                if line.hasPrefix("#") {
                    heading = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).trimmingCharacters(in: .whitespaces)
                    if current.isEmpty || current.allSatisfy({ $0.hasPrefix("#") }) { chunkHeading = heading }
                }
                if length + line.count > size {
                    if fresh { emit() }
                    if length + line.count > size { current = []; length = 0 }
                }
                current.append(line); length += line.count + 1; fresh = true
            }
            if fresh { emit() }
        }
        return out
    }

    /// Lines, with over-long lines broken at sentence ends or spaces.
    static func pieces(_ text: String, maxLength: Int) -> [String] {
        var out: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.count > maxLength {
                let limit = line.index(line.startIndex, offsetBy: maxLength)
                let head = line[..<limit]
                let cut = head.lastIndex(where: { ".!?;".contains($0) }).map { line.index(after: $0) }
                    ?? head.lastIndex(of: " ") ?? limit
                out.append(String(line[..<cut]).trimmingCharacters(in: .whitespaces))
                line = String(line[cut...]).trimmingCharacters(in: .whitespaces)
            }
            if !line.isEmpty { out.append(line) }
        }
        return out
    }

    // MARK: Tokens

    static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "did", "do", "does", "for", "from", "had",
        "has", "have", "how", "i", "if", "in", "into", "is", "it", "its", "me", "my", "of", "on", "or", "our",
        "so", "that", "the", "their", "them", "then", "there", "these", "they", "this", "to", "was", "we",
        "were", "what", "when", "where", "which", "who", "why", "will", "with", "you", "your", "about",
        "lecture", "notes", "note", "say", "said", "tell",
    ]

    public static func terms(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
            .filter { $0.count > 1 && !stopwords.contains($0) }
            .map(stem)
    }

    static func termCounts(_ text: String) -> [String: Int] {
        terms(text).reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    /// A light suffix stripper so "elasticities"/"elasticity" and "rates"/"rate" match.
    static func stem(_ w: String) -> String {
        guard w.count > 3, w.allSatisfy(\.isLetter) else { return w }
        if w.hasSuffix("ies") && w.count > 4 { return String(w.dropLast(3)) + "y" }
        if w.hasSuffix("sses") { return String(w.dropLast(2)) }
        if w.hasSuffix("ing") && w.count > 5 { return String(w.dropLast(3)) }
        if w.hasSuffix("ed") && w.count > 4 { return String(w.dropLast(2)) }
        if w.hasSuffix("s") && !w.hasSuffix("ss") && !w.hasSuffix("us") && !w.hasSuffix("is") { return String(w.dropLast()) }
        return w
    }

    // MARK: Search

    /// BM25 score of each chunk for the query terms.
    func bm25(_ queryTerms: [String]) -> [Double] {
        let n = Double(chunks.count)
        let avg = lengths.isEmpty ? 1 : Double(lengths.reduce(0, +)) / Double(lengths.count)
        var scores = [Double](repeating: 0, count: chunks.count)
        for term in Set(queryTerms) {
            guard let df = docFreq[term] else { continue }
            let idf = log(1 + (n - Double(df) + 0.5) / (Double(df) + 0.5))
            for i in chunks.indices {
                guard let tf = termFreqs[i][term] else { continue }
                let t = Double(tf)
                scores[i] += idf * t * (k1 + 1) / (t + k1 * (1 - b + b * Double(lengths[i]) / max(avg, 1)))
            }
        }
        return scores
    }

    /// Keyword (and, with `queryEmbedding`, semantic) search. `moduleCode` narrows to one module.
    public func search(_ query: String, moduleCode: String? = nil, limit: Int = 8,
                       queryEmbedding: [Double]? = nil) -> [NoteSearchHit] {
        let qTerms = Self.terms(query)
        let keyword = bm25(qTerms)
        let maxKeyword = keyword.max() ?? 0
        var hits: [NoteSearchHit] = []
        for (i, chunk) in chunks.enumerated() {
            if let moduleCode, chunk.moduleCode?.caseInsensitiveCompare(moduleCode) != .orderedSame { continue }
            let k = maxKeyword > 0 ? keyword[i] / maxKeyword : 0
            var semantic: Double?
            if let q = queryEmbedding, let e = chunk.embedding { semantic = Self.cosine(q, e) }
            var score: Double
            if let s = semantic {
                score = (1 - semanticWeight) * k + semanticWeight * max(0, s)
                if k == 0 && s < 0.35 { continue }
            } else {
                score = k
                if k == 0 { continue }
            }
            if chunk.kind == .typed { score *= typedBoost }
            hits.append(NoteSearchHit(chunk: chunk, score: score, keywordScore: keyword[i], semanticScore: semantic,
                                      snippet: Self.snippet(chunk.text, query: query)))
        }
        return Array(hits.sorted { ($0.score, $1.chunk.id) > ($1.score, $0.chunk.id) }.prefix(limit))
    }

    /// Hybrid search, embedding the query with `embedder`. Falls back to keywords if embedding fails.
    public func search(_ query: String, moduleCode: String? = nil, limit: Int = 8,
                       embedder: NoteEmbedder) async -> [NoteSearchHit] {
        let q = try? await embedder.embed([query]).first
        return search(query, moduleCode: moduleCode, limit: limit, queryEmbedding: q ?? nil)
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na == 0 || nb == 0 ? 0 : dot / (na.squareRoot() * nb.squareRoot())
    }

    /// About `width` characters around the first query word found.
    static func snippet(_ text: String, query: String, width: Int = 220) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let lower = flat.lowercased()
        let words = query.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init).filter { $0.count > 2 && !stopwords.contains($0) }
        var hit: String.Index?
        for w in words {
            if let r = lower.range(of: w) ?? lower.range(of: stem(w)) { hit = hit.map { min($0, r.lowerBound) } ?? r.lowerBound }
        }
        guard flat.count > width else { return flat }
        let centre = hit.map { lower.distance(from: lower.startIndex, to: $0) } ?? 0
        let startOffset = max(0, min(centre - width / 3, flat.count - width))
        var start = flat.index(flat.startIndex, offsetBy: startOffset)
        var end = flat.index(start, offsetBy: width, limitedBy: flat.endIndex) ?? flat.endIndex
        if start != flat.startIndex, let space = flat[start...].firstIndex(of: " ") { start = flat.index(after: space) }
        if end != flat.endIndex, let space = flat[start..<end].lastIndex(of: " ") { end = space }
        return (start == flat.startIndex ? "" : "…") + flat[start..<end] + (end == flat.endIndex ? "" : "…")
    }

    // MARK: Persistence

    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> NoteIndex {
        try JSONDecoder().decode(NoteIndex.self, from: Data(contentsOf: url))
    }

    // MARK: Answering

    /// Answers a question from the notes, citing them as [1], [2]…
    /// Uses `.privateData` by default so notes stay on the Mac; pass another purpose to allow cloud models.
    public func answer(_ question: String, using router: LLMRouter, moduleCode: String? = nil, limit: Int = 6,
                       purpose: LLMPurpose = .privateData, embedder: NoteEmbedder? = nil) async throws -> NoteAnswer {
        let hits: [NoteSearchHit]
        if let embedder { hits = await search(question, moduleCode: moduleCode, limit: limit, embedder: embedder) }
        else { hits = search(question, moduleCode: moduleCode, limit: limit) }
        guard !hits.isEmpty else {
            return NoteAnswer(text: "I couldn't find anything about that in your notes.", citations: [], hits: [])
        }
        var sources = ""
        for (n, h) in hits.enumerated() {
            let c = h.chunk
            let meta = [c.moduleCode, c.week.map { "Week \($0)" }].compactMap { $0 }.joined(separator: ", ")
            sources += "[\(n + 1)] \(c.noteTitle)\(meta.isEmpty ? "" : " (\(meta))") — \(Self.label(c.kind))\n\(c.text)\n\n"
        }
        let system = """
        You answer a university student's questions using only their own lecture notes, given below as numbered sources.
        "Key points" are the student's typed summary and matter most. "Lecture detail" is transcribed handwriting and may contain transcription mistakes.
        Cite the sources you use inline, like [1] or [2][3], right after the sentence they support.
        If the notes don't answer the question, say so plainly instead of guessing.
        Write in UK English. Be concise and clear.
        """
        let user = "Notes:\n\n\(sources)Question: \(question)"
        let text = try await router.complete(LLMRequest(messages: [.system(system), .user(user)], purpose: purpose,
                                                        temperature: 0.2))
        return NoteAnswer(text: text, citations: Self.citations(in: text, hits: hits), hits: hits)
    }

    static func citations(in text: String, hits: [NoteSearchHit]) -> [NoteCitation] {
        let regex = try! NSRegularExpression(pattern: #"\[(\d{1,2})\]"#)
        var seen = Set<Int>(), out: [NoteCitation] = []
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range(at: 1), in: text), let n = Int(text[r]), (1...hits.count).contains(n),
                  seen.insert(n).inserted else { continue }
            let c = hits[n - 1].chunk
            out.append(NoteCitation(index: n, noteID: c.noteID, title: c.noteTitle, moduleCode: c.moduleCode, week: c.week))
        }
        return out
    }
}
