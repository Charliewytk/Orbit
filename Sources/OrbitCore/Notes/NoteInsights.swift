import Foundation

/// Summaries and flashcards made from lecture notes. Uses `.privateData` by
/// default so notes stay on the Mac; pass another purpose to allow cloud models.
public enum NoteInsights {
    /// Longest note text sent to the model (small local models have short contexts).
    public static let maxInputCharacters = 12_000

    /// Five bullet points in UK English, key points first.
    public static func summarise(_ note: LectureNote, router: LLMRouter,
                                 purpose: LLMPurpose = .privateData) async throws -> String {
        let system = """
        You summarise a university student's lecture notes into exactly 5 short bullet points.
        The typed "key points" are what the student decided mattered most; build the summary around them,
        using the handwritten "lecture detail" to fill in. The handwriting was transcribed automatically,
        so ignore obvious transcription errors. Write in UK English. Output only the 5 bullets, each starting with "- ".
        """
        let reply = try await router.complete(LLMRequest(messages: [.system(system), .user(material(note))],
                                                         purpose: purpose, temperature: 0.2))
        return bullets(reply, max: 5)
    }

    /// Normalises a bullet list reply to "• " lines.
    static func bullets(_ reply: String, max: Int) -> String {
        let lines = reply.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let items = lines.compactMap { line -> String? in
            if let r = line.range(of: #"^([-*•–]|\d+[.)])\s*"#, options: .regularExpression) {
                return String(line[r.upperBound...])
            }
            return nil
        }
        let chosen = items.isEmpty ? lines : items
        return chosen.prefix(max).map { "• " + $0 }.joined(separator: "\n")
    }

    struct CardsReply: Decodable {
        struct Card: Decodable { let front: String; let back: String }
        let cards: [Card]
    }

    /// Flashcards (question → answer) made from the typed key points first, with
    /// handwriting as supporting detail.
    public static func flashcards(from note: LectureNote, router: LLMRouter, count: Int = 8,
                                  purpose: LLMPurpose = .privateData, now: Date = Date()) async throws -> [Flashcard] {
        let system = """
        You write revision flashcards for a university student from their lecture notes.
        Make up to \(count) cards. Base them on the typed "key points" first; only use the handwritten
        "lecture detail" for cards the key points don't cover. Each card tests one fact, definition, formula or idea.
        Fronts are short questions; backs are short, correct answers (1–2 sentences, LaTeX between $ signs for maths).
        Write in UK English. Reply with JSON only: {"cards": [{"front": "…", "back": "…"}]}
        """
        let reply = try await router.completeJSON(CardsReply.self, LLMRequest(
            messages: [.system(system), .user(material(note))], purpose: purpose, temperature: 0.3))
        var seen = Set<String>()
        return reply.cards.compactMap { c in
            let front = c.front.trimmingCharacters(in: .whitespacesAndNewlines)
            let back = c.back.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !front.isEmpty, !back.isEmpty, seen.insert(front.lowercased()).inserted else { return nil }
            return Flashcard(noteID: note.id, moduleCode: note.moduleCode, front: front, back: back, due: now)
        }
        .prefix(count).map { $0 }
    }

    /// The note laid out for a prompt: title, key points, then detail, trimmed to fit.
    static func material(_ note: LectureNote) -> String {
        var header = "Lecture: \(note.title)"
        if let m = note.moduleCode { header += "\nModule: \(m)" }
        if let w = note.week { header += "\nWeek: \(w)" }
        let key = note.keyPoints.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = note.segments.filter { $0.kind != .typed }.map(\.text).joined(separator: "\n")
        var body = "\n\nKEY POINTS (typed):\n" + (key.isEmpty ? "(none)" : key)
        let room = max(0, maxInputCharacters - header.count - body.count - 40)
        if !detail.isEmpty && room > 0 { body += "\n\nLECTURE DETAIL (handwriting):\n" + String(detail.prefix(room)) }
        return header + body
    }
}

// MARK: - Gaps

public struct NoteGap: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Handwriting with no typed key points yet.
        case missingTypedSummary
        /// A timetabled lecture with no notes.
        case missingNotes
        /// Pages whose handwriting OCR was unsure.
        case lowConfidence
    }

    public var kind: Kind
    public var moduleCode: String?
    public var week: Int?
    public var date: Date?
    public var message: String
    public var noteIDs: [String]
    public var eventID: String?
}

/// Finds what's missing: lectures without notes, handwriting not typed up, and pages to check.
public enum GapDetector {
    /// - Parameters:
    ///   - lectures: timetable lecture events; the module code is read from the title.
    ///   - lookback: how far back to check lectures.
    ///   - lowConfidence: handwriting segments below this count as unsure.
    public static func detect(notes: [LectureNote], lectures: [CalendarEvent], now: Date = Date(),
                              lookback: TimeInterval = 28 * 86400, lowConfidence: Double = 0.6,
                              timeZone: TimeZone = TimeZone(identifier: "Europe/London")!) -> [NoteGap] {
        var gaps: [NoteGap] = []

        // 1. Handwriting that hasn't been typed up.
        for n in notes.sorted(by: { $0.created > $1.created }) where n.hasHandwriting && !n.hasTyped {
            let name: String
            if let m = n.moduleCode, let w = n.week { name = "\(m) Week \(w)" }
            else if let m = n.moduleCode { name = "\(m) “\(n.title)”" }
            else { name = "“\(n.title)”" }
            gaps.append(NoteGap(kind: .missingTypedSummary, moduleCode: n.moduleCode, week: n.week, date: n.created,
                                message: "\(name) has handwriting but no typed summary", noteIDs: [n.id]))
        }

        // 2. Past lectures with no note for that module on the day (or up to two days after).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_GB")
        df.timeZone = timeZone
        df.dateFormat = "EEE d MMM"
        var reported = Set<String>()
        for e in lectures.sorted(by: { $0.start > $1.start })
        where !e.isAllDay && e.end <= now && e.start >= now.addingTimeInterval(-lookback) {
            guard let code = NoteMetadataDetector.moduleCode(in: [e.title, e.notes]) else { continue }
            let day = cal.startOfDay(for: e.start)
            guard let windowEnd = cal.date(byAdding: .day, value: 3, to: day) else { continue }
            let covered = notes.contains { n in
                n.moduleCode?.caseInsensitiveCompare(code) == .orderedSame && n.created >= day && n.created < windowEnd
            }
            let key = "\(code)|\(day.timeIntervalSince1970)"
            guard !covered, reported.insert(key).inserted else { continue }
            gaps.append(NoteGap(kind: .missingNotes, moduleCode: code, week: nil, date: e.start,
                                message: "No notes for \(code) lecture on \(df.string(from: e.start))",
                                noteIDs: [], eventID: e.id))
        }

        // 3. Pages with unsure handwriting, as one reminder.
        let unsure = notes.filter { n in
            n.segments.contains { $0.kind != .typed && ($0.confidence < lowConfidence || $0.uncertainWords.count >= 5) }
        }
        if !unsure.isEmpty {
            let pages = unsure.count == 1 ? "1 low-confidence page" : "\(unsure.count) low-confidence pages"
            gaps.append(NoteGap(kind: .lowConfidence, moduleCode: nil, week: nil, date: nil,
                                message: "\(pages) to check", noteIDs: unsure.map(\.id)))
        }
        return gaps
    }
}
