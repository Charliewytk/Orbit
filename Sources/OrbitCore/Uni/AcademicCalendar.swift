import Foundation

// Exeter's teaching calendar: which teaching week a date falls in, and what
// "end of week 2", "week 1 of term 2" or "W/c 21 September" mean as dates.

/// One term of teaching weeks, numbered from 1.
public struct AcademicTerm: Codable, Hashable, Sendable {
    public var number: Int
    public var name: String
    /// Monday of week 1 as "yyyy-MM-dd" (kept as text so the config reads well and has no time-zone surprises).
    public var startDate: String
    public var weeks: Int
    /// Consolidation / reading weeks. They still count as numbered weeks.
    public var readingWeeks: [Int]

    public init(number: Int, name: String, startDate: String, weeks: Int, readingWeeks: [Int] = []) {
        self.number = number; self.name = name; self.startDate = startDate; self.weeks = weeks
        self.readingWeeks = readingWeeks
    }
}

/// Term dates. Codable and Hashable so it can live in `UserPrefs.academicCalendar`
/// (or a local JSON file) and be edited.
public struct AcademicCalendarConfig: Codable, Hashable, Sendable {
    /// First calendar year of the academic year (2026 for 2026/27).
    public var academicYear: Int
    public var terms: [AcademicTerm]
    public var timeZoneID: String

    public init(academicYear: Int, terms: [AcademicTerm], timeZoneID: String = "Europe/London") {
        self.academicYear = academicYear; self.terms = terms; self.timeZoneID = timeZoneID
    }

    /// University of Exeter 2026/27: week 1 = Mon 21 Sep 2026, term 1 weeks 1–12
    /// (week 6, w/c 26 Oct, is a reading/consolidation week), Christmas break after
    /// week 12 (w/c 7 Dec), term 2 from Mon 11 Jan 2027, term 3 from Mon 26 Apr 2027.
    public static let exeter2026 = AcademicCalendarConfig(academicYear: 2026, terms: [
        AcademicTerm(number: 1, name: "Term 1", startDate: "2026-09-21", weeks: 12, readingWeeks: [6]),
        AcademicTerm(number: 2, name: "Term 2", startDate: "2027-01-11", weeks: 11, readingWeeks: [6]),
        AcademicTerm(number: 3, name: "Term 3", startDate: "2027-04-26", weeks: 7),
    ])
}

/// A teaching week.
public struct AcademicWeek: Codable, Hashable, Sendable {
    public var term: Int
    public var week: Int
    /// Monday 00:00 local time.
    public var start: Date
    public var isReadingWeek: Bool

    public init(term: Int, week: Int, start: Date, isReadingWeek: Bool = false) {
        self.term = term; self.week = week; self.start = start; self.isReadingWeek = isReadingWeek
    }

    /// "Week 2" in term 1, "T2 week 1" later on (+ " (reading week)").
    public var label: String {
        (term == 1 ? "Week \(week)" : "T\(term) week \(week)") + (isReadingWeek ? " (reading week)" : "")
    }

    /// Sunday 23:59:59 (start + 7 days − 1 s; DST-safe enough for display and filtering).
    public func end(in cal: Calendar) -> Date {
        (cal.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86400)).addingTimeInterval(-1)
    }
}

/// A week phrase found in text ("end of week 2", "week 1 of term 2", "W/c 21 September").
public struct AcademicDateMatch: Hashable, Sendable {
    public var text: String
    public var range: NSRange
    public var term: Int
    public var week: Int
    /// The resolved instant: 23:59 on Friday for "end of week N", Monday 00:00 for a
    /// bare week, the named day (00:00) for "week 3 Monday".
    public var date: Date
    public var hasTime: Bool
    /// True when the phrase names a whole week rather than a day.
    public var isPeriod: Bool
    /// For whole weeks: Sunday 23:59.
    public var periodEnd: Date?

    /// When something "due" at this phrase should be finished: the date itself when it
    /// has a time, 23:59 on a named day, or Friday 23:59 for a whole week.
    public func dueDate(in calendar: AcademicCalendar) -> Date {
        if hasTime { return date }
        if isPeriod { return calendar.date(term: term, week: week, weekday: 5, hour: 23, minute: 59) ?? date }
        return calendar.dayCalendar.date(minute: 23 * 60 + 59, of: date)
    }
}

public struct AcademicCalendar: Sendable {
    public var config: AcademicCalendarConfig
    public let dayCalendar: DayCalendar

    public init(config: AcademicCalendarConfig = .exeter2026) {
        self.config = config
        dayCalendar = DayCalendar(timeZone: TimeZone(identifier: config.timeZoneID) ?? ELEWebParser.london)
    }

    public static let exeter = AcademicCalendar()

    public var timeZone: TimeZone { dayCalendar.timeZone }
    var cal: Calendar { dayCalendar.calendar }

    // MARK: Weeks

    public func termStart(_ term: Int) -> Date? {
        guard let t = config.terms.first(where: { $0.number == term }) else { return nil }
        return Self.parseDay(t.startDate, cal)
    }

    static func parseDay(_ s: String, _ cal: Calendar) -> Date? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Monday 00:00 of `week` in `term` (weeks past the term's end are allowed, e.g. week 13).
    public func weekStart(term: Int, week: Int) -> Date? {
        guard let start = termStart(term) else { return nil }
        return cal.date(byAdding: .day, value: 7 * (week - 1), to: start)
    }

    /// A day in a teaching week. `weekday` is 1 = Monday … 7 = Sunday.
    public func date(term: Int = 1, week: Int, weekday: Int = 1, hour: Int = 0, minute: Int = 0) -> Date? {
        guard let monday = weekStart(term: term, week: week) else { return nil }
        let day = cal.date(byAdding: .day, value: max(1, min(7, weekday)) - 1, to: monday) ?? monday
        return dayCalendar.date(minute: hour * 60 + minute, of: day)
    }

    public func academicWeek(term: Int, week: Int) -> AcademicWeek? {
        guard let start = weekStart(term: term, week: week) else { return nil }
        let reading = config.terms.first { $0.number == term }?.readingWeeks.contains(week) ?? false
        return AcademicWeek(term: term, week: week, start: start, isReadingWeek: reading)
    }

    /// The teaching week containing `date`, or nil in the holidays.
    public func week(for date: Date) -> AcademicWeek? {
        for t in config.terms {
            guard let start = Self.parseDay(t.startDate, cal), date >= start else { continue }
            let days = cal.dateComponents([.day], from: start, to: dayCalendar.startOfDay(date)).day ?? 0
            let w = days / 7 + 1
            if w <= t.weeks { return academicWeek(term: t.number, week: w) }
        }
        return nil
    }

    /// The current week, or in the holidays the first week of the next term.
    public func currentOrNextWeek(_ date: Date) -> AcademicWeek? {
        if let w = week(for: date) { return w }
        for t in config.terms.sorted(by: { $0.number < $1.number }) {
            if let s = termStart(t.number), s > date { return academicWeek(term: t.number, week: 1) }
        }
        return nil
    }

    /// The week after `w` (crossing into the next term when needed).
    public func next(after w: AcademicWeek) -> AcademicWeek? {
        let weeks = config.terms.first { $0.number == w.term }?.weeks ?? 0
        if w.week < weeks { return academicWeek(term: w.term, week: w.week + 1) }
        return config.terms.first { $0.number == w.term + 1 }.flatMap { _ in academicWeek(term: w.term + 1, week: 1) }
    }

    /// The term to use for "week N" with no term given: the one `reference` falls in,
    /// else the next one to start, else the last.
    public func defaultTerm(for reference: Date) -> Int {
        if let w = week(for: reference) { return w.term }
        let sorted = config.terms.sorted { $0.number < $1.number }
        for t in sorted {
            if let s = termStart(t.number), s > reference { return t.number }
        }
        return sorted.last?.number ?? 1
    }

    /// Term of a teaching week that starts on `monday` ("W/c 11 January" → 2).
    public func term(forWeekCommencing monday: Date) -> AcademicWeek? { week(for: monday.addingTimeInterval(3600 * 12)) }

    // MARK: Phrases

    static let weekdayNames: [(String, Int)] = [
        ("mon", 1), ("tue", 2), ("wed", 3), ("thu", 4), ("fri", 5), ("sat", 6), ("sun", 7),
    ]
    static let weekdayPattern = "(mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)"
    static let termPattern = "(?:(?:of\\s+|in\\s+)?(?:term|t)\\s*([1-3]))"

    static func weekday(_ s: String?) -> Int? {
        guard let s = s?.lowercased(), s.count >= 3 else { return nil }
        return weekdayNames.first { s.hasPrefix($0.0) }?.1
    }

    enum PhraseKind: CaseIterable { case endOfWeek, startOfWeek, dayOfWeek, weekDay, termWeek, weekOfTerm, weekCommencing, readingWeek, plainWeek }

    static let patterns: [(PhraseKind, NSRegularExpression)] = {
        let wk = "(?:teaching\\s+)?(?:week|wk)\\s*(\\d{1,2})"
        let term = "(?:\\s*(?:,|of|in)?\\s*(?:term|t)\\s*([1-3]))?"
        let src: [(PhraseKind, String)] = [
            (.endOfWeek, "\\b(?:(?:the\\s+)?end\\s+of|by\\s+the\\s+end\\s+of)\\s+(?:the\\s+)?" + wk + term + "\\b"),
            (.startOfWeek, "\\b(?:(?:the\\s+)?(?:start|beginning)\\s+of)\\s+(?:the\\s+)?" + wk + term + "\\b"),
            (.dayOfWeek, "\\b" + weekdayPattern + "\\.?\\s+(?:of\\s+|in\\s+)?(?:the\\s+)?" + wk + term + "\\b"),
            (.weekDay, "\\b" + wk + term + "[\\s,]+(?:on\\s+(?:the\\s+)?)?" + weekdayPattern + "\\b"),
            (.termWeek, "\\b(?:term|t)\\s*([1-3])[\\s,]*(?:week|wk|w)\\s*(\\d{1,2})\\b"),
            (.weekOfTerm, "\\b" + wk + "\\s*(?:of|in|,)\\s*(?:term|t)\\s*([1-3])\\b"),
            (.weekCommencing, "\\b(?:w\\s*/\\s*c|week\\s+commencing|w\\.c\\.)\\.?\\s*(?:mon(?:day)?\\s+)?(\\d{1,2})(?:st|nd|rd|th)?\\s+([a-z]{3,9})"),
            (.readingWeek, "\\b(reading|consolidation)\\s+week\\b"),
            (.plainWeek, "\\b" + wk + "\\b"),
        ]
        return src.map { ($0.0, UniRegex.regex($0.1)) }
    }()

    /// Week phrases in `text`. `reference` picks the term when none is given (e.g. now, or the
    /// Monday of the ELE section the text came from); `term` forces one.
    public func matches(in text: String, reference: Date = Date(), term forcedTerm: Int? = nil) -> [AcademicDateMatch] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [AcademicDateMatch] = []
        for (kind, regex) in Self.patterns {
            for m in regex.matches(in: text, range: full) {
                if let match = resolve(kind, m, ns, reference: reference, forcedTerm: forcedTerm) { found.append(match) }
            }
        }
        // Longest match wins where they overlap.
        found.sort { $0.range.length != $1.range.length ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }
        var chosen: [AcademicDateMatch] = []
        for f in found where !chosen.contains(where: { NSIntersectionRange($0.range, f.range).length > 0 }) { chosen.append(f) }
        return chosen.sorted { $0.range.location < $1.range.location }
    }

    /// The first week phrase in `text`.
    public func resolve(_ text: String, reference: Date = Date(), term: Int? = nil) -> AcademicDateMatch? {
        matches(in: text, reference: reference, term: term).first
    }

    private func resolve(_ kind: PhraseKind, _ m: NSTextCheckingResult, _ ns: NSString, reference: Date,
                         forcedTerm: Int?) -> AcademicDateMatch? {
        func g(_ i: Int) -> String? {
            guard i < m.numberOfRanges, m.range(at: i).location != NSNotFound else { return nil }
            return ns.substring(with: m.range(at: i))
        }
        func int(_ i: Int) -> Int? { g(i).flatMap { Int($0) } }
        let text = ns.substring(with: m.range)
        func make(term: Int?, week: Int?, weekday: Int?, endOfWeek: Bool = false) -> AcademicDateMatch? {
            guard let week, (1...20).contains(week) else { return nil }
            let t = term ?? forcedTerm ?? defaultTerm(for: reference)
            if endOfWeek {
                guard let d = date(term: t, week: week, weekday: 5, hour: 23, minute: 59) else { return nil }
                return AcademicDateMatch(text: text, range: m.range, term: t, week: week, date: d, hasTime: true, isPeriod: false)
            }
            if let weekday {
                guard let d = date(term: t, week: week, weekday: weekday) else { return nil }
                return AcademicDateMatch(text: text, range: m.range, term: t, week: week, date: d, hasTime: false, isPeriod: false)
            }
            guard let start = weekStart(term: t, week: week) else { return nil }
            let end = date(term: t, week: week, weekday: 7, hour: 23, minute: 59)
            return AcademicDateMatch(text: text, range: m.range, term: t, week: week, date: start, hasTime: false,
                                     isPeriod: true, periodEnd: end)
        }
        switch kind {
        case .endOfWeek: return make(term: int(2), week: int(1), weekday: nil, endOfWeek: true)
        case .startOfWeek: return make(term: int(2), week: int(1), weekday: 1)
        case .dayOfWeek: return make(term: int(3), week: int(2), weekday: Self.weekday(g(1)))
        case .weekDay: return make(term: int(2), week: int(1), weekday: Self.weekday(g(3)))
        case .termWeek: return make(term: int(1), week: int(2), weekday: nil)
        case .weekOfTerm: return make(term: int(2), week: int(1), weekday: nil)
        case .plainWeek:
            // "week 10 of the course" is fine; "2 weeks" / "week-long" are not matched by the pattern.
            return make(term: nil, week: int(1), weekday: nil)
        case .readingWeek:
            let t = forcedTerm ?? defaultTerm(for: reference)
            guard let w = config.terms.first(where: { $0.number == t })?.readingWeeks.first else { return nil }
            return make(term: t, week: w, weekday: nil)
        case .weekCommencing:
            guard let day = int(1), let month = g(2).flatMap(ELEWebParser.month),
                  let d = ELEWebParser.date(day: day, month: month, academicYear: config.academicYear, timeZone: timeZone),
                  let w = term(forWeekCommencing: d) else { return nil }
            return AcademicDateMatch(text: text, range: m.range, term: w.term, week: w.week, date: w.start, hasTime: false,
                                     isPeriod: true, periodEnd: date(term: w.term, week: w.week, weekday: 7, hour: 23, minute: 59))
        }
    }

    // MARK: ELE sections

    /// Term of a module's week sections, from any section that states its w/c date.
    public func inferTerm(for sections: [ELEWebSection]) -> Int? {
        for s in sections where s.kind == .week {
            if let d = s.weekCommencing, let w = term(forWeekCommencing: d) { return w.term }
        }
        return nil
    }

    /// Fills in `weekCommencing` for "Week N" sections that don't state it.
    public func fillWeekCommencing(_ sections: inout [ELEWebSection], defaultTerm: Int = 1) {
        let term = inferTerm(for: sections) ?? defaultTerm
        for i in sections.indices where sections[i].kind == .week && sections[i].weekCommencing == nil {
            if let w = sections[i].week { sections[i].weekCommencing = weekStart(term: term, week: w) }
        }
    }

    /// The teaching week of an ELE week section ("Week 3 W/c 5 October" → term 1 week 3).
    public func academicWeek(of section: ELEWebSection, defaultTerm: Int = 1) -> AcademicWeek? {
        guard let w = section.week else { return nil }
        if let d = section.weekCommencing, let found = term(forWeekCommencing: d) { return found }
        return academicWeek(term: defaultTerm, week: w)
    }

    /// Reading weeks shown on ELE as a bare "Text and media area" (or titled "Reading week").
    public func isReadingWeek(term: Int, week: Int) -> Bool {
        config.terms.first { $0.number == term }?.readingWeeks.contains(week) ?? false
    }

    // MARK: Display

    public func describe(_ w: AcademicWeek) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB"); f.timeZone = timeZone; f.dateFormat = "EEE d MMM"
        return "\(w.label), w/c \(f.string(from: w.start))"
    }
}
