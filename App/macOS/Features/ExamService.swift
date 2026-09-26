import Foundation
import Observation
import SwiftData
import OrbitCore

/// Exam mode on the Mac: whether it's on, countdowns, revision progress, past papers from
/// ELE, weak topics, today's revision target, and automatic revision planning
/// (RevisionPlanner tasks, which the scheduler fits around the routine).
@MainActor
@Observable
final class ExamService {
    @ObservationIgnored weak var hub: FeatureHub?
    @ObservationIgnored private var lastPlanRun: Date?

    private var routine: RoutineService? { hub?.routine }
    private var context: ModelContext? { hub?.context }

    func assessments() -> [Assessment] { context?.all(StoredAssessment.self).map(\.value) ?? [] }

    func isActive(now: Date = Date()) -> Bool {
        routine?.examMode().isActive(assessments: assessments(), now: now) ?? false
    }

    func countdowns(now: Date = Date()) -> [ExamMode.Countdown] {
        routine?.examMode().countdowns(assessments(), now: now) ?? []
    }

    // MARK: Revision

    struct Progress {
        var doneTasks: Int
        var totalTasks: Int
        var doneMinutes: Int
        var totalMinutes: Int
        var todayMinutes: Int
        var todayTarget: Int
        var fraction: Double { totalMinutes == 0 ? 0 : Double(doneMinutes) / Double(totalMinutes) }
        var todayFraction: Double { Double(todayMinutes) / Double(max(1, todayTarget)) }
    }

    /// Revision tasks for upcoming exams and how far through they are.
    func progress(now: Date = Date()) -> Progress {
        guard let context, let hub else { return Progress(doneTasks: 0, totalTasks: 0, doneMinutes: 0, totalMinutes: 0, todayMinutes: 0, todayTarget: 60) }
        let exams = countdowns(now: now)
        let ids = Set(exams.map(\.id))
        let tasks = context.all(StoredTask.self).filter { $0.assessmentID.map(ids.contains) ?? false }
        let total = tasks.reduce(0) { $0 + $1.estimateMinutes }
        let done = tasks.reduce(0) { $0 + ($1.completedAt != nil ? $1.estimateMinutes : min($1.minutesDone, $1.estimateMinutes)) }
        let taskIDs = Set(tasks.map(\.id))
        let cal = DayCalendar(timeZone: hub.prefs.timeZone)
        let focus = hub.state.focusLog.filter { cal.isSameDay($0.start, now) && ($0.taskID.map { taskIDs.contains($0.uuidString) } ?? false) }
            .reduce(0) { $0 + $1.minutes }
        let logged = Set(hub.state.focusLog.compactMap { $0.blockID?.uuidString })
        let ticked = context.all(StoredBlock.self).filter { $0.completed && taskIDs.contains($0.taskID) && cal.isSameDay($0.start, now) && !logged.contains($0.id) }
            .reduce(0) { $0 + $1.minutes }
        let daysLeft = exams.first.map { max(1, $0.days) } ?? 7
        return Progress(doneTasks: tasks.filter { $0.completedAt != nil }.count, totalTasks: tasks.count, doneMinutes: done,
                        totalMinutes: total, todayMinutes: focus + ticked,
                        todayTarget: ExamMode.dailyTarget(remainingMinutes: total - done, daysLeft: daysLeft))
    }

    /// Plans revision for exams that don't have a plan yet (only while exam mode is on).
    func tick(now: Date) {
        guard now.timeIntervalSince(lastPlanRun ?? .distantPast) > 3600, isActive(now: now) else { return }
        lastPlanRun = now
        planRevision(now: now, force: false)
    }

    @discardableResult
    func planRevision(now: Date = Date(), force: Bool) -> Int {
        guard let context, let hub, let brain = hub.brain, let routine else { return 0 }
        let prefs = hub.prefs.effectiveRoutine.adjusted(hub.prefs)
        let upcoming = Set(countdowns(now: now).map(\.id))
        var added = 0
        for stored in context.all(StoredAssessment.self) where upcoming.contains(stored.id) {
            guard force || (stored.plannedAt == nil && !routine.state.revisionPlannedExams.contains(stored.id)) else { continue }
            let value = stored.value
            var topics = brain.revisionTopics(moduleCode: value.moduleCode)
            if topics.isEmpty {
                topics = RevisionPlanner.topics(fromNotes: context.all(StoredNote.self).map(\.stub), moduleCode: value.moduleCode)
            }
            if force {
                for t in context.all(StoredTask.self) where t.assessmentID == value.id && t.completedAt == nil { context.delete(t) }
            }
            for var t in RevisionPlanner(prefs: prefs).plan(exams: [.init(assessment: value, topics: topics)], now: now) {
                t.assessmentID = value.id
                context.insert(StoredTask(task: t))
                added += 1
            }
            stored.plannedAt = now
            routine.update { $0.revisionPlannedExams.insert(stored.id) }
        }
        if added > 0 {
            context.saveQuietly()
            hub.tasksChanged()
            hub.toast("Planned \(added) revision sessions around your routine")
        }
        return added
    }

    // MARK: Past papers

    func pastPapers() -> [ExamMode.PastPaper] {
        guard let brain = hub?.brain else { return [] }
        let modules = Set(countdowns().map(\.moduleCode))
        let docs = brain.academic.knowledge.documents().map(\.info)
        return ExamMode.pastPapers(docs).filter { modules.isEmpty || ($0.moduleCode.map(modules.contains) ?? true) }
    }

    func isDone(_ paper: ExamMode.PastPaper) -> Bool { routine?.state.papersDone[paper.id] != nil }

    func toggleDone(_ paper: ExamMode.PastPaper) {
        routine?.update { s in
            if s.papersDone[paper.id] != nil { s.papersDone[paper.id] = nil } else { s.papersDone[paper.id] = Date() }
        }
    }

    /// A focus session timed like the real paper.
    func startTimedPaper(_ paper: ExamMode.PastPaper) {
        hub?.focus.start(task: nil, title: "Timed paper: \(paper.title)", minutes: paper.minutes)
        if let url = paper.url.flatMap(URL.init(string:)) { openExternal(url) }
        NotificationCenter.default.post(name: .orbitNavigate, object: Destination.focus)
    }

    // MARK: Weak topics

    func weakTopics() -> [ExamMode.TopicSignal] {
        guard let context, let hub, let routine else { return [] }
        let notes = Dictionary(context.all(StoredNote.self).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ease: [String: (module: String?, total: Double, count: Int, lapses: Int)] = [:]
        for card in context.all(StoredFlashcard.self) {
            let meta = hub.state.cardMeta[card.id]
            let topic: String
            if let id = card.noteID, let n = notes[id], !n.title.isEmpty { topic = n.title }
            else if let m = card.moduleCode, let w = meta?.week { topic = "\(m) week \(w)" }
            else { continue }
            var e = ease[topic] ?? (card.moduleCode, 0, 0, 0)
            e.total += card.easeFactor
            e.count += 1
            e.lapses += meta?.lapses ?? 0
            ease[topic] = e
        }
        let flash = ease.mapValues { (module: $0.module, ease: $0.total / Double(max(1, $0.count)), lapses: $0.lapses) }
        let missed = hub.brain?.academic.lectureReviews.flatMap { r in r.missed.map { (topic: $0.topic, module: Optional(r.moduleCode)) } } ?? []
        let low = context.all(StoredNote.self).filter(\.lowConfidence).map { (topic: $0.title, module: $0.moduleCode) }
        return ExamMode.weakTopics(flashcardEase: flash, missed: missed, lowConfidence: low, shaky: routine.state.shakyTopics)
    }

    func toggleShaky(_ topic: String) {
        routine?.update { s in
            if s.shakyTopics.contains(topic) { s.shakyTopics.remove(topic) } else { s.shakyTopics.insert(topic) }
        }
    }
}
