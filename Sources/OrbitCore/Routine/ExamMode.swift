import Foundation

/// Exam season: when an exam is close (or the student switches it on), Home becomes an
/// exam dashboard. This decides when, and gathers what it shows.
public struct ExamMode: Sendable {
    public enum Manual: String, Codable, Sendable, CaseIterable { case auto, on, off }

    public struct Countdown: Hashable, Sendable, Identifiable {
        public var id: String
        public var moduleCode: String
        public var title: String
        public var start: Date
        public var days: Int
        public var hours: Int
        public var weightPercent: Double
    }

    public var withinDays: Int
    public var manual: Manual
    public var calendar: DayCalendar

    public init(withinDays: Int = 28, manual: Manual = .auto, calendar: DayCalendar = DayCalendar()) {
        self.withinDays = withinDays; self.manual = manual; self.calendar = calendar
    }

    /// Upcoming, unsat exams, soonest first.
    public func upcomingExams(_ assessments: [Assessment], now: Date) -> [Assessment] {
        assessments.filter { $0.kind == .exam && !$0.submitted && $0.mark == nil && ($0.due.map { $0 > now } ?? false) }
            .sorted { $0.due! < $1.due! }
    }

    public func isActive(assessments: [Assessment], now: Date) -> Bool {
        switch manual {
        case .on: return true
        case .off: return false
        case .auto:
            guard let first = upcomingExams(assessments, now: now).first?.due else { return false }
            return first.timeIntervalSince(now) <= Double(withinDays) * 86400
        }
    }

    public func countdowns(_ assessments: [Assessment], now: Date) -> [Countdown] {
        upcomingExams(assessments, now: now).map { a in
            let secs = a.due!.timeIntervalSince(now)
            return Countdown(id: a.id, moduleCode: a.moduleCode, title: a.title, start: a.due!,
                             days: calendar.days(from: now, to: a.due!), hours: Int(secs / 3600),
                             weightPercent: a.weightPercent)
        }
    }

    // MARK: Past papers

    public struct PastPaper: Hashable, Sendable, Identifiable {
        public var id: String
        public var moduleCode: String?
        public var title: String
        public var url: String?
        public var minutes: Int
        public var year: Int?
    }

    /// Past papers from the course knowledge base, per module, newest first.
    public static func pastPapers(_ docs: [CourseDocumentInfo], defaultMinutes: Int = 90) -> [PastPaper] {
        docs.filter { $0.kind == .pastPaper || Self.looksLikePastPaper($0.title) }.map { d in
            PastPaper(id: d.id, moduleCode: d.moduleCode, title: d.title, url: d.url,
                      minutes: duration(in: d.title) ?? defaultMinutes, year: year(in: d.title))
        }
        .sorted { ($0.moduleCode ?? "", -($0.year ?? 0), $0.title) < ($1.moduleCode ?? "", -($1.year ?? 0), $1.title) }
    }

    static func looksLikePastPaper(_ title: String) -> Bool {
        let t = title.lowercased()
        return t.contains("past paper") || t.contains("past exam") || t.contains("exam paper") || t.contains("mock exam")
            || t.contains("specimen paper")
    }

    /// "1½ hours", "1.5 hrs", "90 minutes", "2 hour" → minutes.
    public static func duration(in text: String) -> Int? {
        let t = text.lowercased().replacingOccurrences(of: "½", with: ".5").replacingOccurrences(of: " and a half", with: ".5")
        if let g = UniRegex.first("(\\d{2,3})\\s*(?:minutes|mins?)\\b", in: t), let m = g[1], let n = Int(m) { return n }
        if let g = UniRegex.first("(\\d+(?:\\.\\d+)?)\\s*(?:hours?|hrs?|h)\\b", in: t), let h = g[1], let n = Double(h) { return Int(n * 60) }
        return nil
    }

    static func year(in text: String) -> Int? {
        UniRegex.first("\\b(20\\d{2})\\b", in: text).flatMap { $0[1] }.flatMap { Int($0) }
    }

    // MARK: Weak topics

    public struct TopicSignal: Hashable, Sendable {
        public var topic: String
        public var moduleCode: String?
        /// Why it's weak ("low flashcard ease", "missed in notes", "marked shaky", "low confidence").
        public var reasons: [String]
        public var score: Double
    }

    /// Ranks weak topics from flashcard ease (per topic), notes-vs-slides misses, low OCR
    /// confidence and topics the student marked "shaky". Higher score = weaker.
    public static func weakTopics(flashcardEase: [String: (module: String?, ease: Double, lapses: Int)],
                                  missed: [(topic: String, module: String?)],
                                  lowConfidence: [(topic: String, module: String?)],
                                  shaky: Set<String>, limit: Int = 12) -> [TopicSignal] {
        var map: [String: TopicSignal] = [:]
        func add(_ topic: String, _ module: String?, _ reason: String, _ score: Double) {
            let key = topic.lowercased()
            var s = map[key] ?? TopicSignal(topic: topic, moduleCode: module, reasons: [], score: 0)
            if !s.reasons.contains(reason) { s.reasons.append(reason) }
            s.score += score
            if s.moduleCode == nil { s.moduleCode = module }
            map[key] = s
        }
        for (topic, v) in flashcardEase where v.ease < 2.3 || v.lapses >= 2 {
            add(topic, v.module, "low flashcard ease", (2.5 - v.ease) * 4 + Double(v.lapses))
        }
        for m in missed { add(m.topic, m.module, "missed in notes", 2) }
        for c in lowConfidence { add(c.topic, c.module, "low confidence", 1) }
        for s in shaky { add(s, nil, "marked shaky", 5) }
        return map.values.sorted { ($0.score, $1.topic) > ($1.score, $0.topic) }.prefix(limit).map { $0 }
    }

    /// Daily revision target in minutes: remaining revision work spread over the days left, 60–300.
    public static func dailyTarget(remainingMinutes: Int, daysLeft: Int) -> Int {
        guard remainingMinutes > 0 else { return 60 }
        let per = remainingMinutes / max(1, daysLeft)
        return min(300, max(60, (per + 4) / 5 * 5))
    }
}
