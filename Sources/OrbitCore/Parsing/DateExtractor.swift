import Foundation

/// A date or time found in free text.
public struct DateMatch: Hashable, Sendable {
    /// Where the phrase is in the original string.
    public var range: Range<String.Index>
    /// The resolved instant. Day-only matches are local midnight at the start of that day.
    public var date: Date
    /// False for day-only phrases ("Friday", "12 Nov").
    public var hasTime: Bool
    /// The matched text, e.g. "Friday 5pm".
    public var text: String
    /// For spans like "next week" or "this weekend": the last minute of the span (23:59).
    public var periodEnd: Date?

    public init(range: Range<String.Index>, date: Date, hasTime: Bool, text: String, periodEnd: Date? = nil) {
        self.range = range; self.date = date; self.hasTime = hasTime; self.text = text; self.periodEnd = periodEnd
    }
}

/// Finds dates and times in English text, relative to `now`, with UK
/// conventions (dd/mm, weeks start Monday). Deterministic, no AI.
///
/// Understands: today, tonight, tomorrow, day after tomorrow, weekday names
/// ("Friday", "this Fri", "next Monday" = Monday of next week), next/this week,
/// month or weekend, end of day/week/month, "in 3 days", "in 2 hours",
/// 12/11, 12/11/26, 2026-11-12, 12.11.2026, "12 Nov", "12th of November 2026",
/// "Nov 12", "the 12th", and times such as 5pm, 5:30 pm, 17:00, noon, "at 5",
/// "this evening", joined to a date when adjacent ("Friday at 5pm", "3pm tomorrow").
/// Dates without a year pick the next occurrence (up to a week in the past is kept).
public struct DateExtractor: Sendable {
    public var now: Date
    public var timeZone: TimeZone
    /// When set, teaching-week phrases ("end of week 2", "week 1 of term 2",
    /// "W/c 21 September", "by week 3 Monday") are understood too.
    public var academic: AcademicCalendar?

    public init(now: Date = Date(), timeZone: TimeZone = TimeZone(identifier: "Europe/London")!,
                academic: AcademicCalendar? = nil) {
        self.now = now; self.timeZone = timeZone; self.academic = academic
    }

    /// The first date in the text, if any.
    public func first(in text: String) -> DateMatch? { extract(from: text).first }

    public func extract(from text: String) -> [DateMatch] {
        let cal = DayCalendar(timeZone: timeZone)
        let full = NSRange(text.startIndex..., in: text)

        // 1. Candidates from every pattern.
        var atoms: [Atom] = []
        for (kind, regex) in Self.patterns {
            for m in regex.matches(in: text, range: full) {
                if var atom = resolve(kind, m, text, cal) {
                    atom.range = m.range
                    atoms.append(atom)
                }
            }
        }

        if let academic {
            for m in academic.matches(in: text, reference: now) {
                var atom = Atom()
                atom.range = m.range
                atom.day = cal.startOfDay(m.date)
                if m.hasTime { atom.minute = cal.minuteOfDay(m.date) }
                atom.periodEnd = m.periodEnd
                atoms.append(atom)
            }
        }

        // 2. Longest match wins where candidates overlap.
        atoms.sort { $0.range.length != $1.range.length ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }
        var chosen: [Atom] = []
        for a in atoms where !chosen.contains(where: { NSIntersectionRange($0.range, a.range).length > 0 }) {
            chosen.append(a)
        }
        chosen.sort { $0.range.location < $1.range.location }

        // 3. Join adjacent date + time phrases.
        var groups: [Atom] = []
        var i = 0
        while i < chosen.count {
            var cur = chosen[i]
            while i + 1 < chosen.count, let merged = merge(cur, chosen[i + 1], text) {
                cur = merged
                i += 1
            }
            groups.append(cur)
            i += 1
        }

        // 4. Turn groups into matches.
        return groups.compactMap { g -> DateMatch? in
            if g.needsContext || g.weak { return nil }
            guard let range = Range(g.range, in: text) else { return nil }
            let str = String(text[range])
            if let abs = g.absolute {
                return DateMatch(range: range, date: abs, hasTime: true, text: str)
            }
            switch (g.day, g.minute) {
            case let (day?, minute?):
                return DateMatch(range: range, date: cal.date(minute: minute, of: day), hasTime: true, text: str)
            case let (day?, nil):
                return DateMatch(range: range, date: day, hasTime: false, text: str, periodEnd: g.periodEnd)
            case let (nil, minute?):
                var d = cal.date(minute: minute, of: now)
                if d < now && !g.explicitToday { d = cal.date(minute: minute, of: cal.addingDays(1, to: now)) }
                return DateMatch(range: range, date: d, hasTime: true, text: str)
            default:
                return nil
            }
        }
    }

    // MARK: - Atoms

    struct Atom {
        var range = NSRange(location: 0, length: 0)
        var day: Date?
        var minute: Int?
        var absolute: Date?
        var periodEnd: Date?
        var isWeekday = false
        /// Abbreviated weekday with no trigger word ("sat", "sun"): only kept if joined to a time.
        var needsContext = false
        /// Bare "morning"/"evening": only kept if joined to a date.
        var weak = false
        /// "this morning": don't roll over to tomorrow.
        var explicitToday = false
    }

    enum Kind: CaseIterable {
        case relative, weekday, period, endOf, inDuration, numeric, dotted, iso, dayMonth, monthDay, ordinal
        case ampm, clock24, namedTime, atHour, partOfDay
    }

    static let monthPattern = "(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
    static let weekdayPattern = "(mon(?:day)?|tue(?:s(?:day)?)?|wed(?:s|nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)"

    static let patterns: [(Kind, NSRegularExpression)] = {
        let src: [(Kind, String)] = [
            (.relative, #"\b(day after tomorrow|today|tonight|tomorrow|tmrw|tmr|yesterday)\b"#),
            (.weekday, #"\b(?:(next|this|coming)\s+)?"# + weekdayPattern + #"\b"#),
            (.period, #"\b(?:(next|this)\s+)?(week|month|weekend)\b"#),
            (.endOf, #"\b(?:end\s+of\s+(?:the\s+)?(day|week|month)|(eod|eow))\b"#),
            (.inDuration, #"\bin\s+(\d+|an?|one|two|three|four|five|six|seven|eight|nine|ten|a\s+couple\s+of|a\s+few)\s+(minutes?|mins?|hours?|hrs?|days?|weeks?|fortnight|months?)\b"#),
            (.numeric, #"\b(\d{1,2})/(\d{1,2})(?:/(\d{4}|\d{2}))?\b"#),
            (.dotted, #"\b(\d{1,2})[.\-](\d{1,2})[.\-](\d{4}|\d{2})\b"#),
            (.iso, #"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#),
            (.dayMonth, #"\b(\d{1,2})(?:st|nd|rd|th)?(?:\s+of)?\s+"# + monthPattern + #"\b(?:,?\s+(\d{4}))?"#),
            (.monthDay, #"\b"# + monthPattern + #"\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:,?\s+(\d{4}))?"#),
            (.ordinal, #"\bthe\s+(\d{1,2})(?:st|nd|rd|th)\b"#),
            (.ampm, #"(?:\bat\s+)?\b(\d{1,2})(?:[:.](\d{2}))?\s*([ap])\.?m\.?(?![a-z])"#),
            (.clock24, #"(?:\bat\s+)?\b([01]?\d|2[0-3]):([0-5]\d)\b"#),
            (.namedTime, #"(?:\bat\s+)?\b(noon|midday|midnight)\b"#),
            (.atHour, #"\bat\s+(\d{1,2})\b(?!\s*(?:[:.]\d|[ap]\.?m|%|/|st\b|nd\b|rd\b|th\b))"#),
            (.partOfDay, #"\b(?:(this|in\s+the)\s+)?(morning|afternoon|evening|night)\b"#),
        ]
        return src.map { ($0.0, try! NSRegularExpression(pattern: $0.1, options: [.caseInsensitive])) }
    }()

    static let dateTimeGap = try! NSRegularExpression(pattern: #"^[\s,]*(?:at|@|by|from|around|about)?[\s,]*$"#, options: [.caseInsensitive])
    static let timeDateGap = try! NSRegularExpression(pattern: #"^[\s,]*(?:on)?[\s,]*$"#, options: [.caseInsensitive])
    static let weekdayDateGap = try! NSRegularExpression(pattern: #"^[\s,]*$"#)
    static let contextWords: Set<String> = ["on", "by", "before", "until", "till", "til", "due", "from", "after",
                                            "every", "for", "next", "this", "coming", "starting"]

    static let weekdayNumbers: [String: Int] = [
        "sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7,
    ]
    static let monthNumbers: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]
    static let smallNumbers: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "a couple of": 2, "a few": 3,
    ]

    static func group(_ m: NSTextCheckingResult, _ i: Int, _ text: String) -> String? {
        guard i < m.numberOfRanges else { return nil }
        let r = m.range(at: i)
        guard r.location != NSNotFound, let rr = Range(r, in: text) else { return nil }
        return String(text[rr])
    }

    private func gapMatches(_ a: Atom, _ b: Atom, _ text: String, _ regex: NSRegularExpression) -> Bool {
        let start = a.range.location + a.range.length
        guard b.range.location >= start else { return false }
        let gapRange = NSRange(location: start, length: b.range.location - start)
        guard let r = Range(gapRange, in: text) else { return false }
        let gap = String(text[r])
        return regex.firstMatch(in: gap, range: NSRange(gap.startIndex..., in: gap)) != nil
    }

    private func merge(_ a: Atom, _ b: Atom, _ text: String) -> Atom? {
        var out = a
        out.range = NSUnionRange(a.range, b.range)
        out.needsContext = false
        out.weak = false
        if a.day != nil, a.minute == nil, a.absolute == nil, b.minute != nil, b.day == nil, b.absolute == nil,
           gapMatches(a, b, text, Self.dateTimeGap) {
            out.minute = b.minute; out.periodEnd = nil
            return out
        }
        if a.minute != nil, a.day == nil, a.absolute == nil, b.day != nil, b.minute == nil, b.absolute == nil,
           gapMatches(a, b, text, Self.timeDateGap) {
            out.day = b.day; out.periodEnd = nil; out.explicitToday = false
            return out
        }
        if a.isWeekday, a.minute == nil, b.day != nil, !b.isWeekday, b.minute == nil, b.periodEnd == nil,
           gapMatches(a, b, text, Self.weekdayDateGap) {
            out.day = b.day; out.isWeekday = false
            return out
        }
        return nil
    }

    private func precedingWord(_ location: Int, _ text: String) -> String? {
        guard let r = Range(NSRange(location: 0, length: location), in: text) else { return nil }
        let before = text[r].trimmingCharacters(in: .whitespaces)
        return before.split(whereSeparator: { !$0.isLetter }).last.map { $0.lowercased() }
    }

    // MARK: - Resolution

    private func yearFix(_ y: Int) -> Int { y < 100 ? 2000 + y : y }

    /// A calendar date, rolling a year-less date forward if it's more than a week ago.
    private func absoluteDay(day: Int, month: Int, year: Int?, _ cal: DayCalendar) -> Date? {
        if let year { return cal.date(year: yearFix(year), month: month, day: day) }
        let thisYear = cal.calendar.component(.year, from: now)
        guard let d = cal.date(year: thisYear, month: month, day: day) else {
            return cal.date(year: thisYear + 1, month: month, day: day) // 29 Feb
        }
        if d < cal.addingDays(-7, to: cal.startOfDay(now)) {
            return cal.date(year: thisYear + 1, month: month, day: day)
        }
        return d
    }

    private func endOfDayMinute(_ day: Date, _ cal: DayCalendar) -> Date { cal.date(minute: 23 * 60 + 59, of: day) }

    private func resolve(_ kind: Kind, _ m: NSTextCheckingResult, _ text: String, _ cal: DayCalendar) -> Atom? {
        let today = cal.startOfDay(now)
        func g(_ i: Int) -> String? { Self.group(m, i, text) }
        func int(_ i: Int) -> Int? { g(i).flatMap { Int($0) } }
        var atom = Atom()

        switch kind {
        case .relative:
            switch g(1)?.lowercased() ?? "" {
            case "today": atom.day = today
            case "tonight": atom.day = today; atom.minute = 20 * 60
            case "tomorrow", "tmrw", "tmr": atom.day = cal.addingDays(1, to: today)
            case "yesterday": atom.day = cal.addingDays(-1, to: today)
            default: atom.day = cal.addingDays(2, to: today) // day after tomorrow
            }

        case .weekday:
            guard let name = g(2)?.lowercased(), let w = Self.weekdayNumbers[String(name.prefix(3))] else { return nil }
            let modifier = g(1)?.lowercased()
            let todayW = cal.weekday(now)
            switch modifier {
            case "next":
                let offset = (w + 5) % 7 // Monday = 0
                atom.day = cal.addingDays(7 + offset, to: cal.startOfWeek(now))
            case "this":
                atom.day = cal.addingDays((w - todayW + 7) % 7, to: today)
            default:
                let delta = (w - todayW + 7) % 7
                atom.day = cal.addingDays(delta == 0 ? 7 : delta, to: today)
            }
            atom.isWeekday = true
            let isFullName = name.count >= 6
            if !isFullName && modifier == nil {
                let original = g(2) ?? ""
                let capitalised = original.first?.isUppercase ?? false
                let trigger = precedingWord(m.range.location, text).map { Self.contextWords.contains($0) } ?? false
                atom.needsContext = !(capitalised || trigger)
            }

        case .period:
            let modifier = g(1)?.lowercased()
            let unit = g(2)?.lowercased() ?? ""
            let weekStart = cal.startOfWeek(now)
            switch (modifier, unit) {
            case ("next", "week"):
                atom.day = cal.addingDays(7, to: weekStart)
                atom.periodEnd = endOfDayMinute(cal.addingDays(13, to: weekStart), cal)
            case ("this", "week"):
                atom.day = today
                atom.periodEnd = endOfDayMinute(cal.addingDays(6, to: weekStart), cal)
            case (_, "weekend"):
                let sat = cal.addingDays(5 + (modifier == "next" ? 7 : 0), to: weekStart)
                atom.day = max(sat, today)
                atom.periodEnd = endOfDayMinute(cal.addingDays(1, to: sat), cal)
            case ("next", "month"), ("this", "month"):
                let comps = cal.calendar.dateComponents([.year, .month], from: now)
                guard let first = cal.date(year: comps.year!, month: comps.month!, day: 1) else { return nil }
                let start = modifier == "next" ? cal.calendar.date(byAdding: .month, value: 1, to: first)! : first
                let nextStart = cal.calendar.date(byAdding: .month, value: 1, to: start)!
                atom.day = modifier == "next" ? start : today
                atom.periodEnd = endOfDayMinute(cal.addingDays(-1, to: nextStart), cal)
            default:
                return nil // bare "week"/"month"
            }

        case .endOf:
            let unit = (g(1) ?? g(2) ?? "").lowercased()
            switch unit {
            case "day", "eod":
                atom.day = today; atom.minute = 17 * 60
            case "week", "eow":
                let weekStart = cal.startOfWeek(now)
                var friday = cal.addingDays(4, to: weekStart)
                if friday < today { friday = cal.addingDays(7, to: friday) }
                atom.day = friday; atom.minute = 17 * 60
            default: // month
                let comps = cal.calendar.dateComponents([.year, .month], from: now)
                guard let first = cal.date(year: comps.year!, month: comps.month!, day: 1),
                      let next = cal.calendar.date(byAdding: .month, value: 1, to: first) else { return nil }
                atom.day = cal.addingDays(-1, to: next); atom.minute = 17 * 60
            }

        case .inDuration:
            let rawCount = (g(1) ?? "").lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard let n = Int(rawCount) ?? Self.smallNumbers[rawCount] else { return nil }
            let unit = (g(2) ?? "").lowercased()
            if unit.hasPrefix("min") {
                atom.absolute = Date(timeIntervalSince1970: ((now.timeIntervalSince1970 + Double(n) * 60) / 60).rounded(.down) * 60)
            } else if unit.hasPrefix("h") {
                atom.absolute = Date(timeIntervalSince1970: ((now.timeIntervalSince1970 + Double(n) * 3600) / 60).rounded(.down) * 60)
            } else if unit.hasPrefix("day") {
                atom.day = cal.addingDays(n, to: today)
            } else if unit.hasPrefix("week") {
                atom.day = cal.addingDays(7 * n, to: today)
            } else if unit == "fortnight" {
                atom.day = cal.addingDays(14 * n, to: today)
            } else {
                guard let d = cal.calendar.date(byAdding: .month, value: n, to: today) else { return nil }
                atom.day = cal.startOfDay(d)
            }

        case .numeric, .dotted:
            guard let d = int(1), let mo = int(2), (1...31).contains(d), (1...12).contains(mo),
                  let day = absoluteDay(day: d, month: mo, year: int(3), cal) else { return nil }
            atom.day = day

        case .iso:
            guard let y = int(1), let mo = int(2), let d = int(3), let day = cal.date(year: y, month: mo, day: d) else { return nil }
            atom.day = day

        case .dayMonth:
            guard let d = int(1), let name = g(2)?.lowercased(), let mo = Self.monthNumbers[String(name.prefix(3))],
                  let day = absoluteDay(day: d, month: mo, year: int(3), cal) else { return nil }
            atom.day = day

        case .monthDay:
            guard let name = g(1)?.lowercased(), let mo = Self.monthNumbers[String(name.prefix(3))], let d = int(2),
                  let day = absoluteDay(day: d, month: mo, year: int(3), cal) else { return nil }
            // "may 5" is only a date when written as a date, not "you may 2…".
            if name == "may", g(1)?.first?.isLowercase == true, int(3) == nil,
               precedingWord(m.range.location, text).map({ !Self.contextWords.contains($0) }) ?? false {
                return nil
            }
            atom.day = day

        case .ordinal:
            guard let d = int(1), (1...31).contains(d) else { return nil }
            let comps = cal.calendar.dateComponents([.year, .month], from: now)
            var candidate = cal.date(year: comps.year!, month: comps.month!, day: d)
            if candidate == nil || candidate! < today {
                let nextMonth = cal.calendar.date(byAdding: .month, value: 1, to: today)!
                let nc = cal.calendar.dateComponents([.year, .month], from: nextMonth)
                candidate = cal.date(year: nc.year!, month: nc.month!, day: d)
            }
            guard let day = candidate else { return nil }
            atom.day = day

        case .ampm:
            guard var h = int(1), (1...12).contains(h) else { return nil }
            let minute = int(2) ?? 0
            guard minute < 60 else { return nil }
            let pm = g(3)?.lowercased() == "p"
            if h == 12 { h = 0 }
            atom.minute = (h + (pm ? 12 : 0)) * 60 + minute

        case .clock24:
            guard let h = int(1), let mi = int(2) else { return nil }
            atom.minute = h * 60 + mi

        case .namedTime:
            atom.minute = g(1)?.lowercased() == "midnight" ? 23 * 60 + 59 : 12 * 60

        case .atHour:
            guard let h = int(1), (0...23).contains(h) else { return nil }
            atom.minute = ((1...7).contains(h) ? h + 12 : h) * 60 // "at 5" → 17:00

        case .partOfDay:
            let part = g(2)?.lowercased() ?? ""
            atom.minute = ["morning": 9 * 60, "afternoon": 14 * 60, "evening": 19 * 60, "night": 21 * 60][part]
            if g(1) != nil { atom.explicitToday = true } else { atom.weak = true }
        }
        return atom
    }
}
