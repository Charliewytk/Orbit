import Foundation

/// Builds an exam revision timetable as tasks: learn each topic once, review
/// it on a spaced schedule counting down to the exam (14, 7, 3, 1 days before
/// by default), and sit timed past papers in the final week.
public struct RevisionPlanner: Sendable {
    public struct Exam: Sendable {
        /// The exam, with `due` set to when it starts.
        public var assessment: Assessment
        public var topics: [String]
        public init(assessment: Assessment, topics: [String]) { self.assessment = assessment; self.topics = topics }
    }

    public var prefs: UserPrefs
    /// Days before the exam to review each topic again.
    public var reviewDaysBefore: [Int]
    /// Days before the exam for timed past papers.
    public var pastPaperDaysBefore: [Int]

    public init(prefs: UserPrefs = UserPrefs(), reviewDaysBefore: [Int] = [14, 7, 3, 1], pastPaperDaysBefore: [Int] = [5, 2]) {
        self.prefs = prefs; self.reviewDaysBefore = reviewDaysBefore.sorted(by: >); self.pastPaperDaysBefore = pastPaperDaysBefore.sorted(by: >)
    }

    public func plan(exams: [Exam], now: Date = Date()) -> [OrbitTask] {
        exams.flatMap { plan($0, now: now) }.sorted { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }
    }

    func plan(_ exam: Exam, now: Date) -> [OrbitTask] {
        let a = exam.assessment
        guard let examStart = a.due, examStart > now, !a.submitted, a.mark == nil else { return [] }
        let coach = StudyCoach(prefs: prefs)
        let topics = exam.topics.isEmpty ? ["All topics"] : Array(NSOrderedSet(array: exam.topics).compactMap { $0 as? String })
        let budget = coach.estimateMinutes(a)
        let learnEach = max(30, budget / 2 / topics.count / 5 * 5)
        let reviewEach = max(20, budget / 4 / max(1, topics.count * reviewDaysBefore.count) / 5 * 5)
        let paperMinutes = max(60, budget / 4 / max(1, pastPaperDaysBefore.count) / 5 * 5)
        let priority: Priority = examStart.timeIntervalSince(now) < 7 * 86400 ? .high : (a.weightPercent >= 40 ? .high : .normal)

        // First passes are spread evenly up to just before the first review.
        let firstReview = reviewDaysBefore.first ?? 7
        var learnEnd = coach.at(prefs.workCutoff, on: examStart.addingTimeInterval(-Double(firstReview + 1) * 86400))
        if learnEnd <= now { learnEnd = now.addingTimeInterval(examStart.timeIntervalSince(now) * 0.4) }
        let learnSpan = learnEnd.timeIntervalSince(now)

        var out: [OrbitTask] = []
        func add(_ name: String, notes: String, minutes: Int, earliest: Date, deadline: Date, energy: Energy, maxBlock: Int = 90) {
            guard deadline > now, deadline < examStart else { return }
            out.append(OrbitTask(title: "\(a.title) · \(name)", notes: notes, estimateMinutes: minutes, deadline: deadline,
                                 earliestStart: max(now, min(earliest, deadline.addingTimeInterval(-Double(minutes) * 60))),
                                 priority: priority, energy: energy, moduleCode: a.moduleCode, assessmentID: a.id,
                                 source: .ele, sourceRef: a.eleURL, minBlockMinutes: min(25, minutes), maxBlockMinutes: maxBlock))
        }

        for (i, topic) in topics.enumerated() {
            let from = now.addingTimeInterval(learnSpan * Double(i) / Double(topics.count))
            let to = now.addingTimeInterval(learnSpan * Double(i + 1) / Double(topics.count))
            add("Learn: \(topic)", notes: "First full pass: condense notes into key points and make flashcards.",
                minutes: learnEach, earliest: from, deadline: to, energy: .high)

            // Stagger alternate topics by a day so reviews don't pile up (the last one stays the day before).
            for d in reviewDaysBefore {
                let offset = d >= 3 && i % 2 == 1 ? d + 1 : d
                let day = examStart.addingTimeInterval(-Double(offset) * 86400)
                add("Review: \(topic) (\(offset)d before)", notes: "Active recall: test yourself before re-reading.",
                    minutes: d == 1 ? max(15, reviewEach / 2) : reviewEach,
                    earliest: coach.at(prefs.dayStart, on: day), deadline: coach.at(prefs.workCutoff, on: day), energy: .medium, maxBlock: 60)
            }
        }
        for (n, d) in pastPaperDaysBefore.enumerated() {
            let day = examStart.addingTimeInterval(-Double(d) * 86400)
            add("Past paper (timed) \(n + 1)", notes: "Exam conditions, then mark it and note weak topics.",
                minutes: paperMinutes, earliest: coach.at(prefs.dayStart, on: day), deadline: coach.at(prefs.workCutoff, on: day),
                energy: .high, maxBlock: 180)
        }
        return out
    }

    /// Topic names from course sections, dropping admin sections.
    public static func topics(fromSections names: [String]) -> [String] {
        let skip = ["general", "announcement", "assessment", "welcome", "introduction to the module", "module information",
                    "resources", "reading list", "exam", "revision", "coursework", "handbook"]
        var seen = Set<String>()
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { name in
            let l = name.lowercased()
            guard !name.isEmpty, !skip.contains(where: { l.hasPrefix($0) || l == $0 }) else { return false }
            return seen.insert(l).inserted
        }
    }

    /// Topic names from lecture notes for a module (typed titles, in date order).
    public static func topics(fromNotes notes: [LectureNote], moduleCode: String) -> [String] {
        var seen = Set<String>()
        return notes.filter { $0.moduleCode == moduleCode }.sorted { $0.created < $1.created }.compactMap { n in
            let t = n.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && seen.insert(t.lowercased()).inserted ? t : nil
        }
    }
}
