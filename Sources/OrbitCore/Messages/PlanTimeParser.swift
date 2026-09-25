import Foundation

/// When a plan in a message is happening, as understood from casual UK phrasing.
public struct PlanTime: Hashable, Sendable {
    public var start: Date
    /// A day was named ("sat", "tomorrow", "14/10"). If false, the message's own day was assumed.
    public var hasDate: Bool
    /// A clock time was named ("7pm", "half 7", "noon"). If false, the time is a default for the part of day.
    public var hasTime: Bool
    /// Fuzzy phrases like "after lectures" or "this weekend".
    public var isVague: Bool
    /// 0–1: how sure the parser is about `start`.
    public var confidence: Double
    /// The words that were understood, e.g. "sat 7pm".
    public var matchedText: String

    public init(start: Date, hasDate: Bool, hasTime: Bool, isVague: Bool, confidence: Double, matchedText: String) {
        self.start = start; self.hasDate = hasDate; self.hasTime = hasTime; self.isVague = isVague
        self.confidence = confidence; self.matchedText = matchedText
    }
}

/// Finds the date and time of a plan in a chat message ("tomorrow at 7",
/// "sat 7pm", "half 7", "brunch sunday", "on the 14th"), resolved relative to
/// when the message was *sent*, not to now. Days are UK order (14/10 = 14 Oct).
///
/// Bare hours are read the way people text about plans: "at 7" is 7pm,
/// "at 10" is 10am, unless the message says "morning", "tonight", "dinner" etc.
public struct PlanTimeParser: Sendable {
    public var timeZone: TimeZone
    var calendar: Calendar

    public init(timeZone: TimeZone = TimeZone(identifier: "Europe/London")!) {
        self.timeZone = timeZone
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 2
        cal.locale = Locale(identifier: "en_GB")
        self.calendar = cal
    }

    /// The best date/time found in `text`, or nil if it mentions none.
    public func parse(_ text: String, relativeTo reference: Date) -> PlanTime? {
        let s = Self.normalize(text)
        let refDay = calendar.dateComponents([.year, .month, .day, .weekday], from: reference)
        let day = dayHits(in: s, refDay: refDay).max { ($0.rank, -$0.position) < ($1.rank, -$1.position) }
        let part = partOfDayHits(in: s).max { ($0.rank, -$0.position) < ($1.rank, -$1.position) }
        let time = timeHits(in: s, context: part).max { ($0.rank, -$0.position) < ($1.rank, -$1.position) }
        guard day != nil || time != nil || part?.vague == true else { return nil }

        var minutes = 12 * 60
        var timeConf = 0.4
        if let time { minutes = time.minutes; timeConf = time.confidence }
        else if let part { minutes = part.minutes; timeConf = part.confidence }

        var ymd = day?.ymd ?? DateComponents(year: refDay.year, month: refDay.month, day: refDay.day)
        guard var start = makeDate(ymd, minutes: minutes) else { return nil }
        if day == nil, start < reference.addingTimeInterval(-3600) {
            start = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            ymd = calendar.dateComponents([.year, .month, .day], from: start)
        }

        let pieces = [day.map { ($0.position, $0.text) }, time.map { ($0.position, $0.text) },
                      time == nil ? part.map { ($0.position, $0.text) } : nil]
            .compactMap { $0 }.sorted { $0.0 < $1.0 }.map(\.1)
        let vague = (day?.vague ?? false) || (time == nil && (part?.vague ?? false))
        return PlanTime(start: start, hasDate: day != nil, hasTime: time != nil, isVague: vague,
                        confidence: ((day?.confidence ?? 0.75) * timeConf * 100).rounded() / 100,
                        matchedText: pieces.joined(separator: " "))
    }

    // MARK: - Normalising

    static let numberWords = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                              "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]

    static func normalize(_ text: String) -> String {
        var s = MessageText.clean(text).lowercased()
        s = s.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        s = slang.regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "tomorrow")
        return s
    }

    static let slang = PlanRegex(#"\b(?:tmrw|tmrow|tmr|tomoz|tomorow|tommorow|tommorrow|2moro|2morrow|tmoz)\b"#)

    // MARK: - Days

    struct DayHit {
        var ymd: DateComponents
        var confidence: Double
        var rank: Int
        var position: Int
        var text: String
        var vague = false
    }

    static let monthPattern = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"
    static let weekdayPattern = "mon(?:day)?|tue(?:s|sday)?|wed(?:s|nesday)?|thu(?:r|rs|rsday)?|fri(?:day)?|sat(?:urday|s)?|sun(?:day)?"
    static let numericDate = PlanRegex(#"(?<![\d/:.£$€])(\d{1,2})/(\d{1,2})(?:/(\d{4}|\d{2}))?(?![\d/])"#)
    static let dayMonth = PlanRegex(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?("# + monthPattern + #")\b"#)
    static let monthDay = PlanRegex(#"\b("# + monthPattern + #")\s+(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)?\b"#)
    static let ordinal = PlanRegex(#"\b(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)\b"#)
    static let relative = PlanRegex(#"\b(day after tomorrow|today|tonight|tomorrow|this (?:morning|afternoon|evening|arvo))\b"#)
    static let weekday = PlanRegex(#"\b(?:(this|next|on|coming)\s+)?("# + weekdayPattern + #")\b"#)
    static let weekend = PlanRegex(#"\b(?:(this|next|the)\s+)?weekend\b"#)
    static let nextWeek = PlanRegex(#"\bnext week\b"#)
    /// Words before "sat"/"sun"/"wed" that mean it isn't a day name ("I sat", "the sun").
    static let notADay: Set<String> = ["i", "we", "he", "she", "they", "you", "just", "was", "the", "got", "c'", "it"]

    func dayHits(in s: String, refDay: DateComponents) -> [DayHit] {
        var hits: [DayHit] = []
        let refDate = makeDate(refDay, minutes: 0) ?? Date()
        func pos(_ m: PlanRegex.Match) -> Int { s.distance(from: s.startIndex, to: m.range.lowerBound) }
        func text(_ m: PlanRegex.Match) -> String { String(s[m.range]) }

        for m in Self.numericDate.matches(in: s) {
            guard let d = Int(m.group(1) ?? ""), let mo = Int(m.group(2) ?? ""), (1...31).contains(d), (1...12).contains(mo)
            else { continue }
            var year = m.group(3).flatMap { Int($0) }
            if let y = year, y < 100 { year = 2000 + y }
            if let ymd = resolve(day: d, month: mo, year: year, refDate: refDate) {
                hits.append(DayHit(ymd: ymd, confidence: 0.95, rank: 5, position: pos(m), text: text(m)))
            }
        }
        for m in Self.dayMonth.matches(in: s) {
            if let d = Int(m.group(1) ?? ""), let mo = Self.month(m.group(2)), let ymd = resolve(day: d, month: mo, year: nil, refDate: refDate) {
                hits.append(DayHit(ymd: ymd, confidence: 0.95, rank: 5, position: pos(m), text: text(m)))
            }
        }
        for m in Self.monthDay.matches(in: s) {
            if let d = Int(m.group(2) ?? ""), let mo = Self.month(m.group(1)), let ymd = resolve(day: d, month: mo, year: nil, refDate: refDate) {
                hits.append(DayHit(ymd: ymd, confidence: 0.95, rank: 5, position: pos(m), text: text(m)))
            }
        }
        for m in Self.ordinal.matches(in: s) {
            guard let d = Int(m.group(1) ?? ""), (1...31).contains(d) else { continue }
            if let ymd = nextDayOfMonth(d, refDay: refDay) {
                hits.append(DayHit(ymd: ymd, confidence: 0.85, rank: 4, position: pos(m), text: text(m)))
            }
        }
        for m in Self.relative.matches(in: s) {
            let word = m.group(1) ?? ""
            let offset = word == "tomorrow" ? 1 : word == "day after tomorrow" ? 2 : 0
            if let ymd = shift(refDate, days: offset) {
                hits.append(DayHit(ymd: ymd, confidence: 0.95, rank: 5, position: pos(m), text: text(m)))
            }
        }
        for m in Self.weekday.matches(in: s) {
            let before = s[..<m.range.lowerBound].split(whereSeparator: { $0 == " " }).last.map(String.init) ?? ""
            if m.group(1) == nil, Self.notADay.contains(before) || before.hasSuffix("c'") { continue }
            guard let target = Self.weekdayNumber(m.group(2)), let w0 = refDay.weekday else { continue }
            var delta = (target - w0 + 7) % 7
            let isNext = m.group(1) == "next"
            if isNext {
                // "next fri" on a Wednesday means Friday of next week, not in two days.
                let refIdx = (w0 + 5) % 7, targetIdx = (target + 5) % 7
                if delta == 0 || targetIdx > refIdx { delta += 7 }
            }
            if let ymd = shift(refDate, days: delta) {
                hits.append(DayHit(ymd: ymd, confidence: isNext ? 0.75 : 0.9, rank: 4, position: pos(m), text: text(m)))
            }
        }
        for m in Self.weekend.matches(in: s) {
            let w0 = refDay.weekday ?? 2
            // Saturday of this weekend (today if it's already the weekend).
            var delta = w0 == 7 || w0 == 1 ? 0 : 7 - w0
            if m.group(1) == "next" { delta = w0 == 1 ? 6 : delta + 7 }
            if let ymd = shift(refDate, days: delta) {
                hits.append(DayHit(ymd: ymd, confidence: 0.5, rank: 2, position: pos(m), text: text(m), vague: true))
            }
        }
        for m in Self.nextWeek.matches(in: s) {
            let w0 = refDay.weekday ?? 2
            if let ymd = shift(refDate, days: (2 - w0 + 7) % 7 == 0 ? 7 : (2 - w0 + 7) % 7) {
                hits.append(DayHit(ymd: ymd, confidence: 0.3, rank: 1, position: pos(m), text: text(m), vague: true))
            }
        }
        return hits
    }

    static func month(_ s: String?) -> Int? {
        guard let s else { return nil }
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return names.firstIndex(of: String(s.prefix(3))).map { $0 + 1 }
    }

    /// Calendar weekday number (1 = Sunday … 7 = Saturday).
    static func weekdayNumber(_ s: String?) -> Int? {
        guard let s else { return nil }
        let map = ["su": 1, "mo": 2, "tu": 3, "we": 4, "th": 5, "fr": 6, "sa": 7]
        return map[String(s.prefix(2))]
    }

    /// A day/month with no year is the next such date, unless it was only recently
    /// (people talk about last week's plans too).
    func resolve(day: Int, month: Int, year: Int?, refDate: Date) -> DateComponents? {
        let ref = calendar.dateComponents([.year], from: refDate)
        var comps = DateComponents(year: year ?? ref.year, month: month, day: day)
        guard var date = makeDate(comps, minutes: 0),
              calendar.component(.day, from: date) == day else { return nil }
        if year == nil, date < refDate.addingTimeInterval(-180 * 86400) {
            comps.year = (comps.year ?? 0) + 1
            guard let next = makeDate(comps, minutes: 0) else { return nil }
            date = next
        }
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    /// "the 14th": this month if it hasn't passed, otherwise next month.
    func nextDayOfMonth(_ day: Int, refDay: DateComponents) -> DateComponents? {
        guard var y = refDay.year, var m = refDay.month else { return nil }
        if day < (refDay.day ?? 1) { m += 1; if m > 12 { m = 1; y += 1 } }
        for _ in 0..<3 {
            let comps = DateComponents(year: y, month: m, day: day)
            if let d = makeDate(comps, minutes: 0), calendar.component(.day, from: d) == day { return comps }
            m += 1; if m > 12 { m = 1; y += 1 }
        }
        return nil
    }

    func shift(_ date: Date, days: Int) -> DateComponents? {
        calendar.date(byAdding: .day, value: days, to: date).map { calendar.dateComponents([.year, .month, .day], from: $0) }
    }

    func makeDate(_ ymd: DateComponents, minutes: Int) -> Date? {
        var c = DateComponents(year: ymd.year, month: ymd.month, day: ymd.day, hour: 0, minute: 0)
        c.timeZone = timeZone
        guard let midnight = calendar.date(from: c) else { return nil }
        return calendar.date(byAdding: .minute, value: minutes, to: midnight)
    }

    // MARK: - Parts of the day

    struct PartHit {
        var minutes: Int
        var confidence: Double
        var rank: Int
        var position: Int
        var text: String
        var morning: Bool
        var vague: Bool
    }

    /// Word → (default minutes, confidence, rank, is morning, is vague). Meals beat general parts of the day.
    static let parts: [(pattern: PlanRegex, minutes: Int, confidence: Double, rank: Int, morning: Bool, vague: Bool)] = [
        (PlanRegex(#"\bbreakfast\b"#), 9 * 60, 0.6, 2, true, false),
        (PlanRegex(#"\bbrunch\b"#), 11 * 60, 0.65, 2, true, false),
        (PlanRegex(#"\blunch(?:time)?\b"#), 12 * 60 + 30, 0.6, 2, false, false),
        (PlanRegex(#"\bdinner\b"#), 19 * 60, 0.6, 2, false, false),
        (PlanRegex(#"\bafter (?:my |the |our )?(?:lectures?|class(?:es)?|uni|seminars?|work|labs?|training)\b"#), 17 * 60, 0.3, 2, false, true),
        (PlanRegex(#"\bmorning\b"#), 9 * 60, 0.55, 1, true, false),
        (PlanRegex(#"\b(?:afternoon|arvo)\b"#), 14 * 60, 0.55, 1, false, false),
        (PlanRegex(#"\bevening\b"#), 18 * 60, 0.55, 1, false, false),
        (PlanRegex(#"\b(?:tonight|night)\b"#), 20 * 60, 0.6, 1, false, false),
        (PlanRegex(#"\b(?:pres|predrinks|pre-drinks|party|clubbing|club)\b"#), 21 * 60, 0.45, 0, false, false),
        (PlanRegex(#"\b(?:drinks|pub|bar)\b"#), 20 * 60, 0.45, 0, false, false),
    ]

    func partOfDayHits(in s: String) -> [PartHit] {
        Self.parts.flatMap { p in
            p.pattern.matches(in: s).map { m in
                PartHit(minutes: p.minutes, confidence: p.confidence, rank: p.rank,
                        position: s.distance(from: s.startIndex, to: m.range.lowerBound),
                        text: String(s[m.range]), morning: p.morning, vague: p.vague)
            }
        }
    }

    // MARK: - Clock times

    struct TimeHit {
        var minutes: Int
        var confidence: Double
        var rank: Int
        var position: Int
        var text: String
    }

    static let hourPattern = #"(\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"#
    static let clock = PlanRegex(#"(?<![\d/:.£$€])(\d{1,2})[:.](\d{2})(?![\d/:.])(?:\s*([ap])\.?m\.?(?![a-z]))?"#)
    static let hourAmPm = PlanRegex(#"(?<![\d/:.£$€])(\d{1,2})\s*([ap])\.?m\.?(?![a-z])"#)
    static let half = PlanRegex(#"\bhalf\s+(?:past\s+)?"# + hourPattern + #"(?![\d:.])"#)
    static let quarter = PlanRegex(#"\bquarter\s+(past|to)\s+"# + hourPattern + #"(?![\d:.])"#)
    static let oclock = PlanRegex(#"\b"# + hourPattern + #"\s*o'?\s?clock\b"#)
    static let bareHour = PlanRegex(#"(?:\b(?:at|around|about|abt|from|by|for like|like)\s+|@\s*)"# + hourPattern + #"(?:\s*ish)?(?![\d:./])(?!\s*(?:mins?|minutes|hours?|hrs?|people|of|days?|weeks?|quid|pounds|%))"#)
    static let ish = PlanRegex(#"\b(\d{1,2})\s*ish\b"#)
    static let named = PlanRegex(#"\b(noon|midday|midnight)\b"#)

    func timeHits(in s: String, context: PartHit?) -> [TimeHit] {
        var hits: [TimeHit] = []
        func pos(_ m: PlanRegex.Match) -> Int { s.distance(from: s.startIndex, to: m.range.lowerBound) }
        func hour(_ g: String?) -> Int? { g.flatMap { Int($0) ?? Self.numberWords[$0] } }
        func add(_ m: PlanRegex.Match, _ minutes: Int, _ conf: Double, _ rank: Int) {
            hits.append(TimeHit(minutes: minutes, confidence: conf, rank: rank, position: pos(m), text: String(s[m.range])))
        }

        for m in Self.clock.matches(in: s) {
            guard let h = Int(m.group(1) ?? ""), let min = Int(m.group(2) ?? ""), h <= 23, min <= 59 else { continue }
            if let ap = m.group(3), h >= 1, h <= 12 {
                add(m, Self.apply(ap, to: h) * 60 + min, 0.95, 4)
            } else if h >= 13 || h == 0 || (m.group(1)?.hasPrefix("0") ?? false) {
                add(m, h * 60 + min, 0.95, 4)
            } else {
                add(m, guessHour(h, context: context) * 60 + min, 0.85, 3)
            }
        }
        for m in Self.hourAmPm.matches(in: s) {
            guard let h = Int(m.group(1) ?? ""), (1...12).contains(h), let ap = m.group(2) else { continue }
            add(m, Self.apply(ap, to: h) * 60, 0.95, 4)
        }
        for m in Self.half.matches(in: s) {
            guard let h = hour(m.group(1)), (1...12).contains(h) else { continue }
            add(m, guessHour(h, context: context) * 60 + 30, 0.8, 3)
        }
        for m in Self.quarter.matches(in: s) {
            guard let h = hour(m.group(2)), (1...12).contains(h) else { continue }
            let base = guessHour(h, context: context) * 60
            add(m, m.group(1) == "past" ? base + 15 : base - 15, 0.8, 3)
        }
        for m in Self.oclock.matches(in: s) {
            guard let h = hour(m.group(1)), (1...12).contains(h) else { continue }
            add(m, guessHour(h, context: context) * 60, 0.8, 3)
        }
        for m in Self.bareHour.matches(in: s) + Self.ish.matches(in: s) {
            guard let h = hour(m.group(1)) else { continue }
            if (13...23).contains(h) { add(m, h * 60, 0.85, 3) }
            else if (1...12).contains(h) { add(m, guessHour(h, context: context) * 60, 0.75, 2) }
        }
        for m in Self.named.matches(in: s) {
            add(m, m.group(1) == "midnight" ? 24 * 60 : 12 * 60, 0.95, 4)
        }
        return hits
    }

    static func apply(_ ampm: String, to h: Int) -> Int {
        ampm == "p" ? (h == 12 ? 12 : h + 12) : (h == 12 ? 0 : h)
    }

    /// Turns a 12-hour clock hour into 24-hour using the message's context.
    func guessHour(_ h: Int, context: PartHit?) -> Int {
        if let context {
            if context.morning { return h == 12 ? 12 : h }
            return h == 12 ? 12 : h + 12
        }
        switch h {
        case 12, 9, 10, 11: return h
        default: return h + 12
        }
    }
}
