import Foundation

/// Six-week exam countdown: a day-by-day revision plan mixing past papers and weak topics.
/// Built on `ExamMode` (upcoming exams, past papers, weak-topic ranking) rather than duplicating it.
public struct ExamRevisionPlan: Codable, Hashable, Sendable {
    public struct Session: Codable, Hashable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable { case pastPaper, weakTopic, review, mock }
        public var id: String
        public var day: Date
        public var moduleCode: String
        public var kind: Kind
        public var title: String
        public var minutes: Int
        public var url: String?
    }

    public struct ExamEntry: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var moduleCode: String
        public var title: String
        public var date: Date
        public var daysLeft: Int
        public var weight: Double
        public var inWindow: Bool
    }

    public var generatedAt: Date
    public var exams: [ExamEntry]
    public var sessions: [Session]

    public func sessions(on day: Date, calendar: DayCalendar) -> [Session] {
        sessions.filter { calendar.isSameDay($0.day, day) }
    }

    public var isActive: Bool { exams.contains(where: \.inWindow) }
}

public struct ExamCountdownPlanner: Sendable {
    public var windowDays: Int
    public var dailyMinutes: Int
    public var calendar: DayCalendar

    public init(windowDays: Int = 42, dailyMinutes: Int = 120, calendar: DayCalendar = DayCalendar()) {
        self.windowDays = windowDays; self.dailyMinutes = dailyMinutes; self.calendar = calendar
    }

    /// Plans from today to each exam that's within the window. Each day gets sessions for the
    /// exams in window, rotating past papers (newest first) with the weakest topics for that module;
    /// the last two days before an exam are a timed mock plus light review.
    public func plan(assessments: [Assessment], pastPapers: [ExamMode.PastPaper], weakTopics: [ExamMode.TopicSignal],
                     now: Date) -> ExamRevisionPlan {
        let exams = ExamMode(withinDays: windowDays, calendar: calendar).upcomingExams(assessments, now: now)
        let entries = exams.map { a in
            ExamRevisionPlan.ExamEntry(id: a.id, moduleCode: a.moduleCode, title: a.title, date: a.due!,
                                       daysLeft: calendar.days(from: now, to: a.due!), weight: a.weightPercent,
                                       inWindow: calendar.days(from: now, to: a.due!) <= windowDays)
        }
        let active = entries.filter(\.inWindow)
        var sessions: [ExamRevisionPlan.Session] = []
        guard !active.isEmpty else { return ExamRevisionPlan(generatedAt: now, exams: entries, sessions: []) }

        var paperIndex: [String: Int] = [:], topicIndex: [String: Int] = [:]
        let today = calendar.startOfDay(now)
        let lastDay = calendar.startOfDay(active.map(\.date).max()!)
        for (dayOffset, day) in calendar.dayStarts(from: today, to: lastDay).enumerated() {
            let live = active.filter { day < calendar.startOfDay($0.date) && calendar.days(from: day, to: $0.date) <= windowDays }
            guard !live.isEmpty else { continue }
            // Closer exams get more of the day.
            let weights = live.map { 1.0 / Double(max(1, calendar.days(from: day, to: $0.date))) }
            let total = weights.reduce(0, +)
            for (exam, w) in zip(live, weights) {
                let minutes = max(30, Int(Double(dailyMinutes) * w / total / 15) * 15)
                let left = calendar.days(from: day, to: exam.date)
                let code = exam.moduleCode
                func add(_ kind: ExamRevisionPlan.Session.Kind, _ title: String, _ mins: Int, _ url: String? = nil) {
                    sessions.append(.init(id: "\(exam.id)|\(dayOffset)|\(kind.rawValue)|\(sessions.count)", day: day,
                                          moduleCode: code, kind: kind, title: title, minutes: mins, url: url))
                }
                if left <= 2 {
                    if left == 2, let p = pastPapers.first(where: { $0.moduleCode == code }) {
                        add(.mock, "Timed mock: \(p.title)", p.minutes, p.url)
                    } else {
                        add(.review, "Light review: formula sheet and flashcards", min(minutes, 60))
                    }
                    continue
                }
                let papers = pastPapers.filter { $0.moduleCode == code }
                let topics = weakTopics.filter { $0.moduleCode == nil || $0.moduleCode == code }
                // Alternate: papers every other day, weak topics otherwise (or whichever exists).
                let wantPaper = !papers.isEmpty && (topics.isEmpty || dayOffset % 2 == 0)
                if wantPaper {
                    let i = paperIndex[code, default: 0]
                    let p = papers[i % papers.count]
                    paperIndex[code] = i + 1
                    add(.pastPaper, (i >= papers.count ? "Redo: " : "") + p.title, min(minutes, max(p.minutes, 45)), p.url)
                } else if !topics.isEmpty {
                    let i = topicIndex[code, default: 0]
                    let t = topics[i % topics.count]
                    topicIndex[code] = i + 1
                    add(.weakTopic, "Weak topic: \(t.topic)", minutes)
                } else {
                    add(.review, "Summarise a week of \(code) from memory, then check the slides", minutes)
                }
            }
        }
        return ExamRevisionPlan(generatedAt: now, exams: entries, sessions: sessions)
    }
}
