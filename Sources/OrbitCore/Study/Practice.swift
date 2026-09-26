import Foundation

// Extra practice: questions pulled from ELE problem sets, past papers and reading-list
// textbooks, each re-issued with a twist (new numbers / context), never repeating a
// question already done, rendered as Markdown (the Mac turns it into PDFs).

public enum PracticeDifficulty: Int, Codable, CaseIterable, Comparable, Sendable {
    case foundation = 1, standard = 2, challenge = 3
    public var label: String {
        switch self { case .foundation: "Foundation"; case .standard: "Standard"; case .challenge: "Challenge" }
    }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Rough guess from length, parts and wording.
    public static func estimate(_ text: String) -> PracticeDifficulty {
        let t = text.lowercased()
        let parts = (try? NSRegularExpression(pattern: "(?m)^\\s*\\(?[a-h]\\)|\\([ivx]+\\)"))?
            .numberOfMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length)) ?? 0
        var score = text.count > 900 ? 2 : text.count > 350 ? 1 : 0
        score += parts >= 4 ? 2 : parts >= 2 ? 1 : 0
        if ["prove", "show that", "derive", "critically", "evaluate", "discuss", "lagrang", "hessian"].contains(where: t.contains) { score += 1 }
        return score >= 3 ? .challenge : score >= 1 ? .standard : .foundation
    }
}

public enum PracticeSetKind: String, Codable, CaseIterable, Sendable {
    case homework, getAhead, examStyle
    public var label: String {
        switch self { case .homework: "Extra homework"; case .getAhead: "Get ahead"; case .examStyle: "Past-paper style" }
    }
}

public struct PracticeSource: Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case problemSet, pastPaper, textbook, lecture }
    public var title: String
    public var moduleCode: String
    public var week: Int?
    public var kind: Kind
    public var text: String
    public init(title: String, moduleCode: String, week: Int? = nil, kind: Kind, text: String) {
        self.title = title; self.moduleCode = moduleCode; self.week = week; self.kind = kind; self.text = text
    }

    /// Problem sheets, past papers, readings and slides for a module from the knowledge base.
    public static func from(_ kb: CourseKnowledgeBase, moduleCode: String, weeks: Set<Int>? = nil) -> [PracticeSource] {
        kb.documents(moduleCode: moduleCode).compactMap { d in
            let kind: Kind
            switch d.kind {
            case .homework: kind = .problemSet
            case .pastPaper, .exemplar: kind = .pastPaper
            case .reading, .readingGuide: kind = .textbook
            case .slides, .handout, .lectureNotes: kind = .lecture
            default: return nil
            }
            if let weeks, kind != .pastPaper, let w = d.week, !weeks.contains(w) { return nil }
            return PracticeSource(title: d.title, moduleCode: moduleCode, week: d.week, kind: kind, text: d.text)
        }
    }
}

public struct PracticeQuestion: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var moduleCode: String
    public var topic: String?
    public var text: String
    public var difficulty: PracticeDifficulty
    public var sourceTitle: String
    /// What the twist changed ("numbers changed", "apples → coffee").
    public var twist: [String]
    public var marks: Int?
    public var solution: String?
    public var originalHash: String
}

public struct PracticeSet: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: PracticeSetKind
    public var moduleCode: String
    public var moduleName: String
    public var title: String
    public var topics: [String]
    public var created: Date
    public var questions: [PracticeQuestion]
    /// "Also appears in: Maths wk3 — Lagrange" hints from the concept web.
    public var crossLinks: [String] = []

    public var fileStem: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        return "\(f.string(from: created)) \(safe)"
    }

    public func markdown() -> String {
        var out = "# \(title)\n\n\(moduleCode) \(moduleName) · \(kind.label)"
        if !topics.isEmpty { out += " · " + topics.prefix(4).joined(separator: ", ") }
        out += "\n\n"
        if kind == .examStyle {
            let total = questions.compactMap(\.marks).reduce(0, +)
            out += "Time allowed: \(max(30, questions.count * 25)) minutes. Answer all questions. Total \(total) marks.\n\n"
        }
        for (i, q) in questions.enumerated() {
            out += "## Question \(i + 1)" + (q.marks.map { " (\($0) marks)" } ?? "") + " · \(q.difficulty.label)\n\n"
            out += q.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            out += "_Based on: \(q.sourceTitle)\(q.twist.isEmpty ? "" : " — " + q.twist.joined(separator: "; "))_\n\n"
        }
        if !crossLinks.isEmpty { out += "## Connections\n\n" + crossLinks.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return out
    }

    public func solutionsMarkdown() -> String {
        var out = "# Worked solutions — \(title)\n\n"
        for (i, q) in questions.enumerated() {
            out += "## Question \(i + 1)\n\n"
            out += (q.solution?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Solution not generated yet (open Orbit with the AI running and regenerate)."
            out += "\n\n"
        }
        return out
    }
}

// MARK: - Extraction

public enum QuestionExtractor {
    /// Splits a problem sheet / past paper into its questions.
    public static func extract(_ text: String, minLength: Int = 40, maxLength: Int = 2500) -> [String] {
        let pattern = "(?im)^\\s*(?:#+\\s*)?(?:question|q|exercise|problem)\\s*\\.?\\s*\\d+[a-z]?\\b[.:)]?|^\\s*\\d{1,2}[.)]\\s+(?=[A-Z(])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let starts = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range.location)
        guard !starts.isEmpty else { return [] }
        var out: [String] = []
        for (i, s) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] : ns.length
            let chunk = ns.substring(with: NSRange(location: s, length: end - s)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard chunk.count >= minLength else { continue }
            out.append(String(chunk.prefix(maxLength)))
        }
        return out
    }

    /// Drops the leading "Question 3." label.
    public static func stripLabel(_ q: String) -> String {
        q.replacingOccurrences(of: "^\\s*(?:#+\\s*)?(?:question|q|exercise|problem)?\\s*\\.?\\s*\\d+[a-z]?[.:)]?\\s*",
                               with: "", options: [.regularExpression, .caseInsensitive])
    }
}

// MARK: - Fingerprints and the ledger

public enum QuestionFingerprint {
    /// Lower-case words with every number as "#", so a twisted copy still matches its original.
    public static func normalise(_ text: String) -> String {
        let lower = QuestionExtractor.stripLabel(text).lowercased()
            .replacingOccurrences(of: "[0-9]+(?:[.,][0-9]+)?", with: "#", options: .regularExpression)
        return lower.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "#")).inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    public static func hash(_ text: String) -> String { MD5.hex(normalise(text)) }

    static func shingles(_ norm: String, n: Int = 3) -> Set<String> {
        let w = norm.split(separator: " ").map(String.init)
        guard w.count >= n else { return Set([w.joined(separator: " ")]) }
        return Set((0...(w.count - n)).map { w[$0..<($0 + n)].joined(separator: " ") })
    }

    public static func similarity(_ a: String, _ b: String) -> Double {
        let sa = shingles(normalise(a)), sb = shingles(normalise(b))
        let union = sa.union(sb).count
        return union == 0 ? 0 : Double(sa.intersection(sb).count) / Double(union)
    }
}

/// Questions already done or issued, for de-duplication.
public struct PracticeLedger: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var hash: String
        public var moduleCode: String?
        public var normalised: String
        public var date: Date
        public var done: Bool
    }
    public var entries: [String: Entry] = [:]
    public init() {}

    public var doneCount: Int { entries.values.filter(\.done).count }

    public func isDuplicate(_ text: String, threshold: Double = 0.6, includeIssued: Bool = true) -> Bool {
        let h = QuestionFingerprint.hash(text)
        if let e = entries[h], e.done || includeIssued { return true }
        let sh = QuestionFingerprint.shingles(QuestionFingerprint.normalise(text))
        for e in entries.values where e.done || includeIssued {
            let other = QuestionFingerprint.shingles(e.normalised)
            let union = sh.union(other).count
            if union > 0, Double(sh.intersection(other).count) / Double(union) >= threshold { return true }
        }
        return false
    }

    public mutating func record(_ text: String, moduleCode: String?, done: Bool, date: Date = Date()) {
        let h = QuestionFingerprint.hash(text)
        let old = entries[h]
        entries[h] = Entry(hash: h, moduleCode: moduleCode, normalised: String(QuestionFingerprint.normalise(text).prefix(1200)),
                           date: old?.date ?? date, done: done || (old?.done ?? false))
    }
}

// MARK: - Twists

/// A deterministic random generator so the same seed gives the same set.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    var state: UInt64
    public init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

public enum QuestionTwister {
    static let contexts: [(String, [String])] = [
        ("apples", ["oranges", "coffee", "bread", "cinema tickets"]),
        ("widgets", ["gadgets", "phone cases", "bicycles"]),
        ("wheat", ["rice", "barley", "maize"]),
        ("cloth", ["steel", "software", "cars"]),
        ("wine", ["cheese", "tea", "microchips"]),
        ("pizza", ["burgers", "sushi", "tacos"]),
        ("alice", ["priya", "tom", "zara"]),
        ("bob", ["sam", "leo", "maya"]),
        ("england", ["france", "japan", "brazil"]),
        ("portugal", ["spain", "india", "canada"]),
    ]

    public struct Result: Hashable, Sendable { public var text: String; public var changes: [String] }

    /// New numbers (kept plausible: same sign, similar size, same decimals; years and
    /// small labels left alone) and a swapped context word.
    public static func twist(_ text: String, seed: UInt64) -> Result {
        var rng = SeededRandom(seed: seed)
        var changes: [String] = []
        let ns = text as NSString
        let re = try! NSRegularExpression(pattern: "(?<![A-Za-z_^])(\\d+(?:\\.\\d+)?)(?![A-Za-z(])")
        var out = ""
        var last = 0
        var changedNumbers = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range)
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = m.range.location + m.range.length
            let before = m.range.location > 0 ? ns.substring(with: NSRange(location: max(0, m.range.location - 8), length: min(8, m.range.location))).lowercased() : ""
            guard let v = Double(s), !(v >= 1700 && v <= 2100 && !s.contains(".")),
                  !before.hasSuffix("week "), !before.hasSuffix("question "), !before.hasSuffix("^"), v != 0, v != 1 || s.contains(".") else {
                out += s; continue
            }
            let decimals = s.split(separator: ".").dropFirst().first?.count ?? 0
            var nv: Double
            if decimals == 0 && v < 10 {
                nv = v + Double(Int.random(in: 1...3, using: &rng))
            } else {
                let f = [0.8, 0.9, 1.1, 1.2, 1.25, 1.5][Int.random(in: 0..<6, using: &rng)]
                nv = v * f
            }
            if decimals == 0 { nv = nv.rounded() } else { let p = pow(10, Double(decimals)); nv = (nv * p).rounded() / p }
            if nv == v { nv += decimals == 0 ? 1 : 1 / pow(10, Double(decimals)) }
            // Probabilities stay probabilities.
            if v < 1, s.contains("."), nv >= 1 { nv = (v * 0.8 * 100).rounded() / 100 }
            out += decimals == 0 ? String(Int(nv)) : String(format: "%.\(decimals)f", nv)
            changedNumbers += 1
        }
        out += ns.substring(from: last)
        if changedNumbers > 0 { changes.append("\(changedNumbers) number\(changedNumbers == 1 ? "" : "s") changed") }

        let lower = out.lowercased()
        for (word, options) in contexts where ConceptGraph.contains(lower, word) {
            let replacement = options[Int.random(in: 0..<options.count, using: &rng)]
            out = replaceWord(word, with: replacement, in: out)
            changes.append("\(word) → \(replacement)")
            break
        }
        return Result(text: out, changes: changes)
    }

    static func replaceWord(_ word: String, with new: String, in text: String) -> String {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        let ns = text as NSString
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let orig = ns.substring(with: m.range)
            let rep = orig.first?.isUppercase == true ? new.prefix(1).uppercased() + new.dropFirst() : new
            out = (out as NSString).replacingCharacters(in: m.range, with: rep)
        }
        return out
    }
}

// MARK: - Building sets

public struct PracticeRequest: Hashable, Sendable {
    public var kind: PracticeSetKind
    public var moduleCode: String
    public var moduleName: String
    public var topics: [String]
    public var difficulty: PracticeDifficulty?
    public var count: Int
    public var seed: UInt64
    public init(kind: PracticeSetKind, moduleCode: String, moduleName: String, topics: [String] = [],
                difficulty: PracticeDifficulty? = nil, count: Int = 6, seed: UInt64 = UInt64(Date().timeIntervalSince1970)) {
        self.kind = kind; self.moduleCode = moduleCode; self.moduleName = moduleName; self.topics = topics
        self.difficulty = difficulty; self.count = count; self.seed = seed
    }
}

public enum PracticeGenerator {
    /// Picks and twists questions. Past-paper sets prefer past papers; others problem sets,
    /// then textbooks, then questions spotted in lecture material. Skips anything in the ledger.
    public static func build(_ req: PracticeRequest, sources: [PracticeSource], ledger: PracticeLedger,
                             graph: ConceptGraph? = nil, now: Date = Date()) -> PracticeSet {
        let order: [PracticeSource.Kind] = req.kind == .examStyle
            ? [.pastPaper, .problemSet, .textbook, .lecture] : [.problemSet, .textbook, .pastPaper, .lecture]
        let topicTerms = Set(req.topics.flatMap { NoteIndex.terms($0) })
        var candidates: [(q: String, src: PracticeSource, rank: Double)] = []
        for src in sources {
            let base = Double(order.firstIndex(of: src.kind) ?? 4)
            for q in QuestionExtractor.extract(src.text) {
                let terms = Set(NoteIndex.terms(q))
                let overlap = topicTerms.isEmpty ? 0 : Double(terms.intersection(topicTerms).count) / Double(topicTerms.count)
                candidates.append((q, src, base - overlap * 2))
            }
        }
        var rng = SeededRandom(seed: req.seed)
        candidates.shuffle(using: &rng)
        candidates.sort { $0.rank < $1.rank }

        var picked: [PracticeQuestion] = []
        var issued = ledger
        for c in candidates where picked.count < req.count {
            guard !issued.isDuplicate(c.q, includeIssued: false) else { continue }
            let difficulty = PracticeDifficulty.estimate(c.q)
            if let want = req.difficulty, want != difficulty { continue }
            let t = QuestionTwister.twist(QuestionExtractor.stripLabel(c.q), seed: req.seed &+ UInt64(picked.count + 1))
            guard !picked.contains(where: { QuestionFingerprint.similarity($0.text, t.text) > 0.6 }) else { continue }
            let marks = req.kind == .examStyle ? [10, 15, 20, 25][difficulty.rawValue] : nil
            let topic = graph?.match(c.q, limit: 1).first?.name
            picked.append(PracticeQuestion(id: QuestionFingerprint.hash(t.text), moduleCode: req.moduleCode, topic: topic, text: t.text,
                                           difficulty: difficulty, sourceTitle: c.src.title, twist: t.changes, marks: marks,
                                           solution: nil, originalHash: QuestionFingerprint.hash(c.q)))
            issued.record(t.text, moduleCode: req.moduleCode, done: false)
        }
        // Harder questions last.
        picked.sort { $0.difficulty < $1.difficulty }
        let when = DateFormatter(); when.locale = Locale(identifier: "en_GB_POSIX"); when.dateFormat = "d MMM"
        let topicLabel = req.topics.first.map { " — \($0)" } ?? ""
        var set = PracticeSet(id: "\(req.moduleCode)-\(req.kind.rawValue)-\(req.seed)", kind: req.kind, moduleCode: req.moduleCode,
                              moduleName: req.moduleName, title: "\(req.moduleCode) \(req.kind.label)\(topicLabel) (\(when.string(from: now)))",
                              topics: req.topics, created: now, questions: picked)
        if let graph { set.crossLinks = crossLinks(for: set, graph: graph) }
        return set
    }

    /// "Lagrange (Maths) ↔ Consumer choice (Economics): maximise utility…"
    public static func crossLinks(for set: PracticeSet, graph: ConceptGraph, limit: Int = 5) -> [String] {
        let web = graph.web(forText: set.topics.joined(separator: "\n") + "\n" + set.questions.map(\.text).joined(separator: "\n"))
        return web.crossModule.prefix(limit).compactMap { e in
            guard let a = graph.concepts[e.from], let b = graph.concepts[e.to] else { return nil }
            return "\(a.name) (\(a.strand.label)) ↔ \(b.name) (\(b.strand.label)): \(e.relation)"
        }
    }

    /// Records every question in a set as issued (and optionally done).
    public static func record(_ set: PracticeSet, in ledger: inout PracticeLedger, done: Bool = false) {
        for q in set.questions { ledger.record(q.text, moduleCode: set.moduleCode, done: done) }
    }

    // MARK: AI

    struct AIQuestion: Codable { var text: String; var solution: String; var difficulty: Int?; var topic: String? }
    struct AIResponse: Codable { var questions: [AIQuestion] }

    /// Asks the AI to polish the twists and write worked solutions. When there were no source
    /// questions, it writes fresh ones on the topics instead.
    public static func aiRequest(for set: PracticeSet, context: String, count: Int) -> LLMRequest {
        let existing = set.questions.enumerated().map { "Q\($0.offset + 1) [\($0.element.difficulty.label)]: \($0.element.text)" }
            .joined(separator: "\n\n")
        let style = set.kind == .examStyle ? "Exeter first-year past-paper style, with mark allocations" : "problem-sheet style"
        return LLMRequest(messages: [
            .system("""
            You write practice questions and fully worked solutions for a first-year BSc Economics student (\(set.moduleCode) \(set.moduleName)). \
            Keep each question's skill but give it a slight twist (different numbers or context) so it is new. Solutions show every step and the final answer. \
            Style: \(style). Reply JSON: {"questions":[{"text":"…","solution":"…","difficulty":1-3,"topic":"…"}]}
            """),
            .user((existing.isEmpty
                   ? "Write \(count) new questions on: \(set.topics.joined(separator: "; ")).\n"
                   : "Twist and solve these \(set.questions.count) questions, in order:\n\n\(existing)\n")
                  + "\nCourse context:\n\(context.prefix(6000))"),
        ], purpose: .reasoning, json: true, temperature: 0.4)
    }

    /// Merges the AI's reply into the set (keeps the local question if the AI dropped one); skips duplicates.
    public static func apply(aiReply: String, to set: inout PracticeSet, ledger: PracticeLedger) {
        guard let json = JSONExtractor.extract(aiReply), let data = json.data(using: .utf8),
              let res = try? JSONDecoder().decode(AIResponse.self, from: data) else { return }
        if set.questions.isEmpty {
            for a in res.questions where !ledger.isDuplicate(a.text, includeIssued: false) {
                let d = PracticeDifficulty(rawValue: a.difficulty ?? 2) ?? .standard
                set.questions.append(PracticeQuestion(id: QuestionFingerprint.hash(a.text), moduleCode: set.moduleCode, topic: a.topic,
                                                      text: a.text, difficulty: d, sourceTitle: "Orbit (AI) on \(set.topics.first ?? set.moduleName)",
                                                      twist: [], marks: set.kind == .examStyle ? [10, 15, 20, 25][d.rawValue] : nil,
                                                      solution: a.solution, originalHash: QuestionFingerprint.hash(a.text)))
            }
            return
        }
        for (i, a) in res.questions.enumerated() where i < set.questions.count {
            if !a.text.isEmpty, !ledger.isDuplicate(a.text, includeIssued: false) { set.questions[i].text = a.text }
            set.questions[i].solution = a.solution
            if set.questions[i].topic == nil { set.questions[i].topic = a.topic }
        }
    }
}

/// Where practice PDFs live: ~/Documents/Orbit Notes/Practice/<Module>/
public enum PracticePaths {
    public static func directory(documents: URL, moduleCode: String, moduleName: String? = nil) -> URL {
        let name = [moduleCode, moduleName].compactMap { $0 }.joined(separator: " ")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        return documents.appendingPathComponent("Orbit Notes", isDirectory: true)
            .appendingPathComponent("Practice", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    public static func notabilityExport(documents: URL) -> URL {
        documents.appendingPathComponent("Orbit Notes", isDirectory: true).appendingPathComponent("For Notability", isDirectory: true)
    }
}
