import Foundation

/// What sort of plan a message is about. Drives titles and default lengths.
public enum PlanKind: String, Codable, CaseIterable, Sendable {
    case dinner, lunch, brunch, breakfast, drinks, coffee, gym, call, lecture, study, party, cinema, sport, birthday, other

    /// How long a plan of this kind usually lasts when the message doesn't say.
    public var defaultDuration: TimeInterval {
        let hour: TimeInterval = 3600
        switch self {
        case .dinner: return 2 * hour
        case .drinks: return 3 * hour
        case .coffee, .lecture, .lunch, .breakfast: return hour
        case .brunch, .gym: return 1.5 * hour
        case .call: return 0.5 * hour
        case .party, .birthday: return 4 * hour
        case .cinema: return 2.5 * hour
        case .study, .sport, .other: return 2 * hour
        }
    }

    /// Short label used in plan titles ("Dinner with Sam").
    public var label: String {
        switch self {
        case .dinner: "Dinner"; case .lunch: "Lunch"; case .brunch: "Brunch"; case .breakfast: "Breakfast"
        case .drinks: "Drinks"; case .coffee: "Coffee"; case .gym: "Gym"; case .call: "Call"
        case .lecture: "Lecture"; case .study: "Study session"; case .party: "Party"; case .cinema: "Cinema"
        case .sport: "Match"; case .birthday: "Birthday"; case .other: "Meet up"
        }
    }

    /// Keywords per kind, most specific first (a "birthday dinner" is a dinner).
    static let keywords: [(PlanKind, PlanRegex)] = [
        (.birthday, PlanRegex(#"\b(?:birthday|bday|b-day)\s+(?:party|drinks|do)\b"#)),
        (.dinner, PlanRegex(#"\b(?:dinner|tea time|nandos|curry|pizza|takeaway)\b"#)),
        (.lunch, PlanRegex(#"\blunch\b"#)),
        (.brunch, PlanRegex(#"\bbrunch\b"#)),
        (.breakfast, PlanRegex(#"\b(?:breakfast|brekkie)\b"#)),
        (.party, PlanRegex(#"\b(?:party|pres|predrinks|pre-drinks|clubbing|club|night out|timepiece|cellar door)\b"#)),
        (.drinks, PlanRegex(#"\b(?:drinks?|pub|pint|pints|bar|cocktails?)\b"#)),
        (.coffee, PlanRegex(#"\b(?:coffee|cafe|café|costa|starbucks)\b"#)),
        (.gym, PlanRegex(#"\b(?:gym|workout|training|climbing|swim)\b"#)),
        (.cinema, PlanRegex(#"\b(?:cinema|film|movie|picturehouse|odeon)\b"#)),
        (.sport, PlanRegex(#"\b(?:match|footie|football|netball|rugby|hockey)\b"#)),
        (.lecture, PlanRegex(#"\b(?:lecture|seminar|tutorial|workshop|lab)\b"#)),
        (.study, PlanRegex(#"\b(?:study session|study|revision|revise|library|group project|groupwork)\b"#)),
        (.call, PlanRegex(#"\b(?:call|facetime|ring|zoom|teams meeting)\b"#)),
        (.birthday, PlanRegex(#"\b(?:birthday|bday|b-day)\b"#)),
    ]

    /// The kind of plan `text` talks about, or `.other`.
    public static func detect(in text: String) -> PlanKind {
        let s = PlanTimeParser.normalize(text)
        return keywords.first { $0.1.contains(s) }?.0 ?? .other
    }
}

/// Fuzzy matching of plan and event titles ("Dinner w/ Sam" ≈ "sam dinner 🍝").
public enum PlanTitleMatch {
    static let stopWords: Set<String> = ["with", "w", "the", "a", "an", "at", "and", "for", "to", "of", "on", "in", "me", "my", "our", "meet", "up", "plan", "plans"]

    /// Lowercased, de-accented word set with small words and plural "s" removed.
    public static func tokens(_ s: String) -> Set<String> {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(words.compactMap { w -> String? in
            var w = w
            if w.hasSuffix("s"), w.count > 3 { w.removeLast() }
            return stopWords.contains(w) ? nil : w
        })
    }

    /// True if the titles share most of their words, or one's words are a subset of the other's.
    public static func similar(_ a: String, _ b: String) -> Bool {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        if ta.isSubset(of: tb) || tb.isSubset(of: ta) { return true }
        let jaccard = Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
        if jaccard >= 0.5 { return true }
        // "Drinks with Sam" ≈ "Pub with Sam": same kind and a shared word beyond the kind itself.
        let ka = PlanKind.detect(in: a), kb = PlanKind.detect(in: b)
        guard ka != .other, ka == kb else { return false }
        return !ta.intersection(tb).subtracting(tokens(ka.label)).isEmpty
    }
}
