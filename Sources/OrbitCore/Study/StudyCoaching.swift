import Foundation

// One shared knowledge layer across the four modules: cross-module hints, weekly
// "teach it back" grading, and a Socratic "Explore" partner that never writes prose.

// MARK: - Cross-module hints

public struct CrossModuleHint: Hashable, Sendable {
    public var conceptName: String
    public var moduleCode: String
    public var week: Int?
    public var documentTitle: String
    public var relation: String
    /// "This also appears in BEE1026 wk3 — Constrained optimisation (Lecture 5 slides)".
    public var line: String {
        "Also in \(moduleCode)\(week.map { " wk\($0)" } ?? "") — \(conceptName) (\(documentTitle))" + (relation.isEmpty ? "" : ": \(relation)")
    }
}

public enum CrossModule {
    /// Which strand each module is (from its ELE name).
    public static func strands(_ kb: CourseKnowledgeBase) -> [String: EconStrand] {
        kb.modules.compactMapValues { EconStrand.classify(name: $0.name) }
    }

    /// For text from one module, where the linked concepts show up in the other modules' material.
    public static func hints(for text: String, moduleCode: String?, kb: CourseKnowledgeBase, graph: ConceptGraph,
                             limit: Int = 5) -> [CrossModuleHint] {
        let strands = strands(kb)
        let web = graph.web(forText: text, limit: 6)
        var out: [CrossModuleHint] = []
        var seen = Set<String>()
        let candidates = web.focus.map { ($0, "") } + web.edges.flatMap { e -> [(Concept, String)] in
            [e.from, e.to].compactMap { graph.concepts[$0] }.map { ($0, e.relation) }
        }
        for (concept, relation) in candidates where out.count < limit {
            let targetModules = strands.filter { $0.value == concept.strand && $0.key != moduleCode }.map(\.key)
            for code in targetModules.sorted() {
                let q = ([concept.name] + concept.keywords.prefix(3)).joined(separator: " ")
                guard let hit = kb.search(q, moduleCode: code, limit: 1).first else { continue }
                let key = "\(concept.id)|\(code)"
                guard seen.insert(key).inserted else { continue }
                out.append(CrossModuleHint(conceptName: concept.name, moduleCode: code, week: hit.document.week,
                                           documentTitle: hit.document.title, relation: relation))
            }
        }
        return out
    }
}

// MARK: - Teach it back

public struct TeachBackTopic: Hashable, Sendable, Identifiable {
    public var id: String { moduleCode + ":" + topic }
    public var topic: String
    public var moduleCode: String
    public var reason: String
}

public struct TeachBackResult: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var topic: String
    public var moduleCode: String
    public var date: Date
    public var explanation: String
    /// 0–100.
    public var score: Int
    public var gaps: [String]
    public var misconceptions: [String]
    public var missingLinks: [String]
    public var nextSteps: [String]
    /// Short Q/A pairs the flashcard deck can pick up.
    public var flashcards: [Flash]

    public struct Flash: Codable, Hashable, Sendable { public var front: String; public var back: String }
}

public struct TeachBackLog: Codable, Hashable, Sendable {
    public var results: [TeachBackResult] = []
    public init() {}
    public mutating func add(_ r: TeachBackResult) { results.removeAll { $0.id == r.id }; results.insert(r, at: 0) }
}

public enum TeachBack {
    /// Up to `count` topics for the week: weakest profile topics first, then this week's lecture topics.
    public static func pickTopics(profile: StudentProfile, thisWeek: [(moduleCode: String, topic: String)],
                                  done: TeachBackLog, now: Date = Date(), count: Int = 3) -> [TeachBackTopic] {
        let recent = Set(done.results.filter { now.timeIntervalSince($0.date) < 6 * 86400 }.map { StudentProfile.key($0.topic) })
        var out: [TeachBackTopic] = []
        for w in profile.weakTopics where out.count < count && !recent.contains(StudentProfile.key(w.topic)) {
            out.append(TeachBackTopic(topic: w.topic, moduleCode: w.moduleCode ?? "", reason: "weak spot (\(Int(w.score * 100))%)"))
        }
        for t in thisWeek where out.count < count && !recent.contains(StudentProfile.key(t.topic))
            && !out.contains(where: { $0.topic == t.topic }) {
            out.append(TeachBackTopic(topic: t.topic, moduleCode: t.moduleCode, reason: "this week's lectures"))
        }
        return out
    }

    struct Grade: Codable {
        var score: Int
        var gaps: [String]?
        var misconceptions: [String]?
        var missingLinks: [String]?
        var nextSteps: [String]?
        var flashcards: [TeachBackResult.Flash]?
    }

    public static func request(topic: TeachBackTopic, explanation: String, context: String, crossLinks: [String]) -> LLMRequest {
        LLMRequest(messages: [
            .system("""
            You are grading a first-year economics student's "teach it back" explanation of a topic, using the course material given. \
            Be exact and demanding (they aim for a top first) but kind. Identify: gaps (missing ideas), misconceptions (wrong statements), \
            missingLinks (connections to their other modules they should have made — use the cross-module links given), nextSteps (2-3 concrete actions) \
            and 3-5 flashcards on what they missed. Score 0-100. \
            Reply JSON: {"score":0,"gaps":[],"misconceptions":[],"missingLinks":[],"nextSteps":[],"flashcards":[{"front":"","back":""}]}
            """),
            .user("Topic: \(topic.topic) (\(topic.moduleCode))\n\nCross-module links:\n\(crossLinks.joined(separator: "\n"))\n\nCourse material:\n\(context.prefix(6000))\n\nStudent's explanation:\n\(explanation.prefix(6000))"),
        ], purpose: .reasoning, json: true, temperature: 0.2)
    }

    public static func parse(_ reply: String, topic: TeachBackTopic, explanation: String, date: Date = Date()) -> TeachBackResult? {
        guard let json = JSONExtractor.extract(reply), let data = json.data(using: .utf8),
              let g = try? JSONDecoder().decode(Grade.self, from: data) else { return nil }
        let day = Int(date.timeIntervalSince1970 / 86400)
        return TeachBackResult(id: "\(topic.id)-\(day)", topic: topic.topic, moduleCode: topic.moduleCode, date: date,
                               explanation: explanation, score: max(0, min(100, g.score)), gaps: g.gaps ?? [],
                               misconceptions: g.misconceptions ?? [], missingLinks: g.missingLinks ?? [],
                               nextSteps: g.nextSteps ?? [], flashcards: g.flashcards ?? [])
    }

    /// Feeds the result into long-term memory: mastery, and notes about misconceptions.
    public static func apply(_ r: TeachBackResult, to profile: inout StudentProfile) {
        profile.recordAttempt(topic: r.topic, moduleCode: r.moduleCode, correct: r.score >= 70, date: r.date)
        for m in r.misconceptions.prefix(2) { profile.remember("Misconception on \(r.topic): \(m)") }
    }
}

// MARK: - Explore (Socratic thinking partner)

public enum ExploreMode: String, CaseIterable, Sendable {
    case explore, draftCheck
    public var label: String { self == .explore ? "Explore" : "Check my draft" }
}

public enum ThinkingPartner {
    /// The system prompt. It never drafts prose, outlines or plans.
    public static func systemPrompt(mode: ExploreMode, topic: String, crossLinks: [String], sources: [String],
                                    criteria: String? = nil) -> String {
        let rules = """
        You are a Socratic thinking partner for a first-year BSc Economics student. You NEVER write essay prose, paragraphs \
        for them to use, introductions, conclusions, essay plans, outlines or thesis statements — even if asked; if asked, say you \
        can't and ask a question instead. Keep replies short. Each reply: 1-3 probing questions, at most one counter-argument or \
        provocative angle phrased as a question, and where useful a surprising connection to their other modules or a source \
        (from the lists below) to look at. Push for evidence, definitions, assumptions and historical context.
        """
        var s = rules + "\n\nTopic: \(topic)"
        if !crossLinks.isEmpty { s += "\n\nCross-module connections you can raise:\n" + crossLinks.map { "- \($0)" }.joined(separator: "\n") }
        if !sources.isEmpty { s += "\n\nSources from their course and reading lists:\n" + sources.map { "- \($0)" }.joined(separator: "\n") }
        if mode == .draftCheck {
            s += """
            \n\nMode: check their draft against the marking criteria. Give feedback only: what meets the criteria, what doesn't, \
            and questions that would lead them to improve it. Quote at most a few words of their draft. Do not rewrite any sentence.
            """
            if let criteria, !criteria.isEmpty { s += "\n\nMarking criteria:\n\(criteria.prefix(4000))" }
        }
        return s
    }

    /// Guards the rule in code too: a reply that looks like drafted prose is replaced with a question.
    public static func looksLikeDraftedProse(_ reply: String) -> Bool {
        let paragraphs = reply.components(separatedBy: "\n\n").filter { $0.count > 450 && !$0.contains("?") }
        let lower = reply.lowercased()
        let planish = lower.contains("introduction:") && lower.contains("conclusion:")
        return !paragraphs.isEmpty || planish
    }

    public static let fallbackQuestion = "I won't draft that for you — but let's get you there. What's the single claim you most want to defend, and what evidence would convince a sceptic?"
}
