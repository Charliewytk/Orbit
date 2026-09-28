import Foundation

/// Text to make flashcards from: lecture slides from ELE, the student's own
/// notes, handouts. The academic side supplies slide text; notes come from
/// `LectureNote`s.
public struct StudyMaterial: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case slides, notes, handout, reading }

    public var id: String
    public var moduleCode: String?
    public var week: Int?
    public var title: String
    public var text: String
    public var kind: Kind

    public init(id: String, moduleCode: String? = nil, week: Int? = nil, title: String, text: String, kind: Kind) {
        self.id = id; self.moduleCode = moduleCode; self.week = week; self.title = title; self.text = text; self.kind = kind
    }

    /// Changes whenever the text changes, so edited notes get fresh cards.
    public var fingerprint: String { MD5.hex(kind.rawValue + "|" + title + "|" + text) }

    /// Notes → material. Typed key points first; handwriting as detail.
    public init(note: LectureNote) {
        let key = note.keyPoints.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = note.segments.filter { $0.kind != .typed }.map(\.text).joined(separator: "\n")
        var text = key.isEmpty ? "" : "KEY POINTS (typed by the student):\n" + key
        if !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += (text.isEmpty ? "" : "\n\n") + "LECTURE DETAIL (handwriting, may contain OCR errors):\n" + detail
        }
        self.init(id: "note:" + note.id, moduleCode: note.moduleCode, week: note.week, title: note.title, text: text, kind: .notes)
    }
}

/// Extra facts about a card that the synced `Flashcard` record doesn't carry.
public struct FlashcardMeta: Codable, Hashable, Sendable {
    public var cardID: UUID
    public var week: Int?
    public var sourceID: String
    public var sourceKind: StudyMaterial.Kind
    public var createdAt: Date
    /// How many times it has been reviewed, and how often "Again" was pressed.
    public var reviews: Int
    public var lapses: Int

    public init(cardID: UUID, week: Int?, sourceID: String, sourceKind: StudyMaterial.Kind, createdAt: Date,
                reviews: Int = 0, lapses: Int = 0) {
        self.cardID = cardID; self.week = week; self.sourceID = sourceID; self.sourceKind = sourceKind
        self.createdAt = createdAt; self.reviews = reviews; self.lapses = lapses
    }
}

/// The four review buttons (keyboard 1–4) mapped onto SM-2 grades.
public enum ReviewAnswer: Int, CaseIterable, Codable, Sendable, Identifiable {
    case again = 1, hard = 2, good = 3, easy = 4

    public var id: Int { rawValue }

    /// SM-2 quality 0–5.
    public var grade: Int {
        switch self { case .again: 1; case .hard: 3; case .good: 4; case .easy: 5 }
    }

    public var label: String {
        switch self { case .again: "Again"; case .hard: "Hard"; case .good: "Good"; case .easy: "Easy" }
    }

    public var key: Character { Character(String(rawValue)) }
}

/// Today's review: how many cards are due and which ones fit in a short session.
public struct DailyReviewPlan: Codable, Hashable, Sendable {
    public var dueCount: Int
    public var sessionCards: [UUID]
    public var estimatedMinutes: Int
    public var byModule: [String: Int]

    /// "10-minute review: 18 cards (3 more after that)".
    public var briefLine: String? {
        guard dueCount > 0 else { return nil }
        let extra = dueCount - sessionCards.count
        return "\(estimatedMinutes)-minute review: \(sessionCards.count) flashcard\(sessionCards.count == 1 ? "" : "s")"
            + (extra > 0 ? " (\(extra) more due after that)" : "")
    }
}

public enum FlashcardDeck {
    /// Average time a card takes in review.
    public static let secondsPerCard = 30

    // MARK: De-duplication

    static let fillerWords: Set<String> = ["what", "is", "are", "the", "a", "an", "of", "does", "do", "define", "explain",
                                           "describe", "which", "how", "why", "in", "to", "and", "for", "by", "meant",
                                           "mean", "term", "s"]

    /// Lower-case, punctuation-free, filler-free words of a card front.
    public static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !fillerWords.contains($0) }
    }

    public static func normalise(_ s: String) -> String { tokens(s).joined(separator: " ") }

    /// Two fronts ask the same thing: equal once normalised, or ≥ 80% word overlap (Jaccard).
    public static func isSameQuestion(_ a: String, _ b: String) -> Bool {
        let ta = Set(tokens(a)), tb = Set(tokens(b))
        if ta.isEmpty || tb.isEmpty { return a.lowercased() == b.lowercased() }
        if ta == tb { return true }
        let overlap = Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
        return overlap >= 0.8
    }

    /// New cards that don't repeat an existing card (or each other) within the same module.
    public static func dedupe(_ new: [Flashcard], against existing: [Flashcard]) -> [Flashcard] {
        var kept: [Flashcard] = []
        for card in new {
            let pool = (existing + kept).filter { $0.moduleCode == card.moduleCode || $0.moduleCode == nil || card.moduleCode == nil }
            if card.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if pool.contains(where: { isSameQuestion($0.front, card.front) }) { continue }
            kept.append(card)
        }
        return kept
    }

    // MARK: Review

    public static func review(_ card: Flashcard, answer: ReviewAnswer, now: Date = Date()) -> Flashcard {
        SpacedRepetition.reviewWithLearningSteps(card, grade: answer.grade, now: now)
    }

    /// Short label for when a card would come back, e.g. "10m", "1d", "6d", "2mo".
    public static func intervalLabel(_ card: Flashcard, answer: ReviewAnswer, now: Date = Date()) -> String {
        let next = review(card, answer: answer, now: now)
        let seconds = next.due.timeIntervalSince(now)
        if seconds < 3600 { return "\(max(1, Int((seconds / 60).rounded())))m" }
        if seconds < 86400 { return "\(Int((seconds / 3600).rounded()))h" }
        let days = Int((seconds / 86400).rounded())
        if days < 45 { return "\(days)d" }
        return "\(Int((Double(days) / 30).rounded()))mo"
    }

    /// Cards due by the end of `day` (overdue included).
    public static func dueCount(_ cards: [Flashcard], by endOfDay: Date) -> Int {
        cards.filter { $0.due < endOfDay }.count
    }

    /// The morning "10-minute review": the most overdue cards that fit in `minutes`,
    /// interleaved across modules so one module doesn't hog the session.
    public static func dailyReview(_ cards: [Flashcard], now: Date, endOfDay: Date, minutes: Int = 10) -> DailyReviewPlan {
        let due = cards.filter { $0.due < endOfDay }.sorted { $0.due != $1.due ? $0.due < $1.due : $0.id.uuidString < $1.id.uuidString }
        let capacity = max(1, minutes * 60 / secondsPerCard)
        var queues: [String: [Flashcard]] = [:]
        var order: [String] = []
        for c in due {
            let key = c.moduleCode ?? "—"
            if queues[key] == nil { order.append(key) }
            queues[key, default: []].append(c)
        }
        var picked: [UUID] = []
        var round = 0
        while picked.count < capacity {
            var any = false
            for key in order {
                guard let q = queues[key], round < q.count else { continue }
                any = true
                picked.append(q[round].id)
                if picked.count == capacity { break }
            }
            if !any { break }
            round += 1
        }
        let byModule = Dictionary(grouping: due, by: { $0.moduleCode ?? "—" }).mapValues(\.count)
        let est = picked.isEmpty ? 0 : max(1, Int((Double(picked.count * secondsPerCard) / 60).rounded(.up)))
        return DailyReviewPlan(dueCount: due.count, sessionCards: picked, estimatedMinutes: min(minutes, est), byModule: byModule)
    }
}

/// Makes flashcards from slides and notes with the local AI (`.privateData` by
/// default, so course material and notes stay on the Mac).
public enum FlashcardGenerator {
    public static let maxInputCharacters = 12_000

    struct CardsReply: Decodable {
        struct Card: Decodable { let front: String; let back: String }
        let cards: [Card]
    }

    public static func systemPrompt(kind: StudyMaterial.Kind, count: Int) -> String {
        let source: String
        switch kind {
        case .slides: source = "lecture slides (text extracted from the slide deck; ignore slide numbers, headers and footers)"
        case .notes: source = "their own lecture notes. Base cards on the typed key points first and only use the handwritten detail for anything the key points don't cover"
        case .handout: source = "a lecture handout"
        case .reading: source = "a set reading"
        }
        return """
        You write revision flashcards for a first-year economics student at the University of Exeter from \(source).
        Make up to \(count) cards. Each card tests exactly one definition, mechanism, formula, graph relationship or key result.
        Prefer "why"/"what happens if" questions over trivia. Fronts are short questions; backs are short, correct answers
        (1–2 sentences; LaTeX between $ signs for maths). Don't invent content that isn't in the material.
        Write in UK English. Reply with JSON only: {"cards": [{"front": "…", "back": "…"}]}
        """
    }

    public static func prompt(for material: StudyMaterial) -> String {
        var header = "Title: \(material.title)"
        if let m = material.moduleCode { header += "\nModule: \(m)" }
        if let w = material.week { header += "\nWeek: \(w)" }
        return header + "\n\n" + String(material.text.prefix(maxInputCharacters))
    }

    /// Cards for one piece of material, cleaned and de-duplicated against `existing`.
    public static func cards(from material: StudyMaterial, existing: [Flashcard] = [], router: LLMRouter, count: Int = 8,
                             purpose: LLMPurpose = .privateData, now: Date = Date()) async throws -> [Flashcard] {
        guard material.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 80 else { return [] }
        let reply = try await router.completeJSON(CardsReply.self, LLMRequest(
            messages: [.system(systemPrompt(kind: material.kind, count: count)), .user(prompt(for: material))],
            purpose: purpose, temperature: 0.3))
        let made = reply.cards.compactMap { c -> Flashcard? in
            let front = c.front.trimmingCharacters(in: .whitespacesAndNewlines)
            let back = c.back.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !front.isEmpty, !back.isEmpty else { return nil }
            return Flashcard(id: StableUUID.make("card|\(material.id)|\(FlashcardDeck.normalise(front))"),
                             noteID: material.id, moduleCode: material.moduleCode, front: front, back: back, due: now)
        }
        return Array(FlashcardDeck.dedupe(made, against: existing).prefix(count))
    }

    /// Material that hasn't been turned into cards yet (or changed since).
    public static func pending(_ materials: [StudyMaterial], processed: [String: String]) -> [StudyMaterial] {
        materials.filter { processed[$0.id] != $0.fingerprint && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 80 }
    }
}
