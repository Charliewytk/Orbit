import Foundation

/// The result of parsing a quick-add line.
public struct QuickAddResult: Hashable, Sendable {
    public var task: OrbitTask
    /// 0–1: how sure the parser is that it understood the line.
    public var confidence: Double
    /// The phrase the deadline came from (e.g. "before Friday").
    public var deadlineText: String?
    /// The phrase the estimate came from (e.g. "2h").
    public var estimateText: String?
    /// Recurrence isn't supported yet; if the line had one ("every Monday"), it's reported here.
    public var ignoredRecurrence: String?
    /// True when the estimate was given rather than guessed.
    public var hasExplicitEstimate: Bool
}

/// Parses natural-language to-dos such as
/// "essay plan for BEM2031, 2h, before Friday" or "call landlord 10m".
///
/// Extracts: module code (ABC1234), estimate (2h, 1.5h, 90m, 45 mins, half an hour),
/// deadline (via `DateExtractor`; "before Friday" means before Friday starts,
/// "by Friday" means by the end of Friday), start date ("from Monday"),
/// priority (!!, urgent, high/low priority) and energy (deep/focus/essay/revise → high,
/// easy/quick/call/email → low). What's left becomes the title.
public struct QuickAddParser: Sendable {
    public var now: Date
    public var timeZone: TimeZone
    public var defaultEstimateMinutes: Int
    public var quickEstimateMinutes: Int

    public init(now: Date = Date(), timeZone: TimeZone = TimeZone(identifier: "Europe/London")!,
                defaultEstimateMinutes: Int = 60, quickEstimateMinutes: Int = 20) {
        self.now = now; self.timeZone = timeZone
        self.defaultEstimateMinutes = defaultEstimateMinutes; self.quickEstimateMinutes = quickEstimateMinutes
    }

    public func parse(_ input: String) -> QuickAddResult {
        let cal = DayCalendar(timeZone: timeZone)
        var s = input.replacingOccurrences(of: "\n", with: " ")
        var confidence = 0.55

        // Recurrence (ignored for now, but removed so it isn't read as a deadline).
        let recurrence = Self.take(Self.recurrence, from: &s).first?.first ?? nil

        // Priority.
        var priority = Priority.normal
        var explicitPriority = false
        for (level, regex) in Self.priorityPatterns {
            let found = !Self.take(regex, from: &s, all: true).isEmpty
            if found && !explicitPriority { priority = level; explicitPriority = true }
        }
        _ = Self.take(Self.trailingBang, from: &s, all: true)

        // Explicit energy markers.
        var energy: Energy?
        if !Self.take(Self.explicitHigh, from: &s, all: true).isEmpty { energy = .high }
        if !Self.take(Self.explicitLow, from: &s, all: true).isEmpty, energy == nil { energy = .low }

        // Module code.
        let moduleCode = Self.take(Self.module, from: &s).first.flatMap { $0.count > 1 ? $0[1] : nil }?.uppercased()

        // Dates.
        var deadline: Date?
        var earliestStart: Date?
        var deadlineText: String?
        let matches = DateExtractor(now: now, timeZone: timeZone).extract(from: s)
        var removals: [Range<String.Index>] = []
        var deadlineChosen = false
        let triggered = matches.map { m -> (DateMatch, String?, Range<String.Index>) in
            let (word, range) = Self.triggerWord(before: m.range, in: s)
            return (m, word, range.map { $0.lowerBound..<m.range.upperBound } ?? m.range)
        }
        for (m, word, range) in triggered where ["from", "after", "starting", "start", "starts"].contains(word ?? "") {
            if earliestStart == nil {
                earliestStart = m.hasTime ? m.date : (word == "after" ? cal.endOfDay(m.date) : m.date)
                removals.append(range)
            }
        }
        let deadlineWords: Set<String> = ["by", "before", "due", "until", "till", "til", "deadline"]
        let pick = triggered.first { deadlineWords.contains($0.1 ?? "") }
            ?? triggered.first { !["from", "after", "starting", "start", "starts"].contains($0.1 ?? "") }
        if let (m, word, range) = pick {
            deadlineChosen = true
            deadlineText = String(s[range])
            if m.text.lowercased().contains("tonight") {
                deadline = cal.date(minute: 23 * 60 + 59, of: m.date)
            } else if m.hasTime {
                deadline = m.date
            } else if let end = m.periodEnd {
                deadline = end
            } else if word == "before" {
                deadline = cal.startOfDay(m.date)
            } else {
                deadline = cal.date(minute: 23 * 60 + 59, of: m.date)
            }
            removals.append(range)
        }
        for r in removals.sorted(by: { $0.lowerBound > $1.lowerBound }) { s.replaceSubrange(r, with: " ") }

        // Estimate.
        var estimate: Int?
        var estimateText: String?
        for (regex, value) in Self.estimatePatterns {
            let found = Self.take(regex, from: &s)
            if let groups = found.first, let minutes = value(groups) {
                estimate = minutes
                estimateText = groups.first ?? nil
                break
            }
        }

        // Title.
        var title = Self.cleanTitle(s)
        if title.isEmpty {
            title = Self.cleanTitle(input)
            confidence = 0.2
        }

        // Implicit energy from the words left in the title.
        if energy == nil {
            let lower = " " + title.lowercased() + " "
            let high = Self.highEnergyWords.contains { lower.range(of: #"\b\#($0)"#, options: .regularExpression) != nil }
            let low = Self.lowEnergyWords.contains { lower.range(of: #"\b\#($0)\b"#, options: .regularExpression) != nil }
            if high { energy = .high } else if low { energy = .low }
        }

        let minutes = estimate ?? (energy == .low ? quickEstimateMinutes : defaultEstimateMinutes)
        if estimate != nil { confidence += 0.15 }
        if deadlineChosen { confidence += 0.15 }
        if moduleCode != nil { confidence += 0.05 }
        if explicitPriority { confidence += 0.05 }
        if title.count < 3 { confidence -= 0.2 }
        if title.range(of: #"\b(at|by|before|next|in)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            confidence -= 0.1
        }

        let task = OrbitTask(title: title, estimateMinutes: max(5, minutes), deadline: deadline,
                             earliestStart: earliestStart, priority: priority, energy: energy ?? .medium,
                             moduleCode: moduleCode, source: .manual,
                             minBlockMinutes: min(25, max(5, minutes)), maxBlockMinutes: 120, createdAt: now)
        return QuickAddResult(task: task, confidence: min(0.99, max(0.05, confidence)),
                              deadlineText: deadlineText?.trimmingCharacters(in: .whitespaces),
                              estimateText: estimateText?.trimmingCharacters(in: .whitespaces),
                              ignoredRecurrence: recurrence?.trimmingCharacters(in: .whitespaces),
                              hasExplicitEstimate: estimate != nil)
    }

    // MARK: - Patterns

    static func re(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    static let recurrence = re(#"\b(?:every\s+(?:other\s+)?\w+|each\s+(?:day|week|month|morning|evening|night|weekday|mon|tue|wed|thu|fri|sat|sun)\w*)(?:\s+and\s+\w+)?(?:\s+at\s+\d{1,2}(?:[:.]\d{2})?\s*(?:[ap]m)?)?|\b(?:daily|weekly|fortnightly|monthly)\b"#)

    static let priorityPatterns: [(Priority, NSRegularExpression)] = [
        (.critical, re(#"!{3,}|\burgent(?:ly)?\b|\basap\b|\bcritical\b|\bp0\b"#)),
        (.high, re(#"!!|\bhigh[\s-]+pri(?:ority)?\b|\bimportant\b|\bp1\b"#)),
        (.low, re(#"\blow[\s-]+pri(?:ority)?\b|\bwhenever\b|\bsomeday\b|\bno\s+rush\b|\bp3\b"#)),
        (.normal, re(#"\b(?:normal|medium)[\s-]+pri(?:ority)?\b"#)),
    ]
    static let trailingBang = re(#"!+"#)

    static let explicitHigh = re(#"\bhigh[\s-]+energy\b|\bdeep[\s-]+work\b|\bdeep\b|\bfocus(?:ed)?\b"#)
    static let explicitLow = re(#"\blow[\s-]+energy\b|\beasy\b|\bquick\b|\bbrainless\b"#)

    static let module = re(#"(?:\b(?:for|in|on|re)\s+)?[(\[]?\b([a-z]{3}\d{4})\b[)\]]?"#)

    static let highEnergyWords = ["essay", "revis", "write", "writing", "dissertation", "exam", "study", "studying",
                                  "coursework", "problem sheet", "research", "report", "draft", "code", "coding"]
    static let lowEnergyWords = ["call", "phone", "email", "e-mail", "reply", "text", "admin", "tidy", "clean",
                                 "buy", "pay", "book", "print", "post", "laundry", "shop", "shopping"]

    static let estPrefix = #"(?:(?:\bfor|\btakes|\babout|\baround|\bapprox\.?)\s+|~\s*)?"#

    static let estimatePatterns: [(NSRegularExpression, ([String?]) -> Int?)] = [
        (re(estPrefix + #"\b(?:an?|one)\s+hour\s+and\s+a\s+half\b"#), { _ in 90 }),
        (re(estPrefix + #"\b(\d+(?:\.\d+)?)\s*(?:h|hr|hrs|hour|hours)\s*(?:and\s+)?(\d+)\s*(?:m|min|mins|minutes?)\b"#), { g in
            guard let h = g[1].flatMap(Double.init), let m = g[2].flatMap(Int.init) else { return nil }
            return Int((h * 60).rounded()) + m
        }),
        (re(estPrefix + #"\b(\d+)h(\d{2})\b"#), { g in
            guard let h = g[1].flatMap(Int.init), let m = g[2].flatMap(Int.init) else { return nil }
            return h * 60 + m
        }),
        (re(estPrefix + #"\b(?:half\s+an?\s+hour|half\s+hour|½\s*(?:h|hr|hour))\b"#), { _ in 30 }),
        (re(estPrefix + #"\b(?:a\s+)?quarter\s+(?:of\s+an\s+)?hour\b"#), { _ in 15 }),
        (re(estPrefix + #"\b(\d+(?:\.\d+)?)\s*(?:h|hr|hrs|hour|hours)\b"#), { g in
            guard let h = g[1].flatMap(Double.init), h > 0 else { return nil }
            return Int((h * 60).rounded())
        }),
        (re(estPrefix + #"\b(?:an?|one)\s+hour\b"#), { _ in 60 }),
        (re(estPrefix + #"\b(\d+)\s*(?:m|min|mins|minutes?)\b"#), { g in
            guard let m = g[1].flatMap(Int.init), m > 0 else { return nil }
            return m
        }),
    ]

    static let triggerWords: Set<String> = ["by", "before", "due", "until", "till", "til", "on", "for", "deadline",
                                            "from", "after", "starting", "start", "starts", "at"]

    /// The deadline/start keyword just before a date ("due by", "before", "from"), and
    /// the range covering it (up to two words, e.g. "due on").
    static func triggerWord(before range: Range<String.Index>, in s: String) -> (String?, Range<String.Index>?) {
        var start = range.lowerBound
        var key: String?
        var lower: String.Index?
        for _ in 0..<2 {
            var i = start
            while i > s.startIndex, s[s.index(before: i)].isWhitespace { i = s.index(before: i) }
            var j = i
            while j > s.startIndex, s[s.index(before: j)].isLetter { j = s.index(before: j) }
            guard j < i else { break }
            let word = s[j..<i].lowercased()
            guard triggerWords.contains(word) else { break }
            // The word nearest the date decides ("due on" → "on" is ignored in favour of "due").
            if key == nil || ["on", "at", "for"].contains(key!) { key = word }
            lower = j
            start = j
        }
        return (key, lower.map { $0..<range.lowerBound })
    }

    /// Removes the first match (or all), returning each match's groups (group 0 = whole match).
    @discardableResult
    static func take(_ regex: NSRegularExpression, from s: inout String, all: Bool = false) -> [[String?]] {
        let found = regex.matches(in: s, range: NSRange(s.startIndex..., in: s))
        let used = all ? found : Array(found.prefix(1))
        let groups = used.map { m in
            (0..<m.numberOfRanges).map { i -> String? in
                let r = m.range(at: i)
                guard r.location != NSNotFound, let rr = Range(r, in: s) else { return nil }
                return String(s[rr])
            }
        }
        for m in used.reversed() {
            if let r = Range(m.range, in: s) { s.replaceSubrange(r, with: " ") }
        }
        return groups
    }

    static let danglingWords: Set<String> = ["for", "by", "before", "on", "at", "due", "and", "in", "to", "from",
                                             "until", "till", "the", "of", "with", "&", "-", "–", "—"]

    static func cleanTitle(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+([,;:.])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"([,;:])[,;:.\s]*(?=[,;:]|$)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\(\s*\)|\[\s*\]"#, with: "", options: .regularExpression)
        let edge = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:-–—.!"))
        var changed = true
        while changed {
            changed = false
            t = t.trimmingCharacters(in: edge)
            var words = t.split(separator: " ").map(String.init)
            while let last = words.last, danglingWords.contains(last.lowercased()) {
                words.removeLast(); changed = true
            }
            while let first = words.first, ["-", "–", "—", "to:", "todo:"].contains(first.lowercased()) {
                words.removeFirst(); changed = true
            }
            t = words.joined(separator: " ")
        }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard let first = t.first else { return "" }
        return first.uppercased() + t.dropFirst()
    }
}
