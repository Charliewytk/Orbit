import Foundation
import SwiftData
import OrbitCore

extension FeatureHub {
    /// Homework: the academic side's detected items (done = its task is done), plus
    /// problem-set style tasks that aren't linked to an assessment.
    func homeworkStatuses() -> [HomeworkStatus] {
        guard let brain else { return [] }
        var out: [HomeworkStatus] = []
        var covered = Set<String>()
        for item in brain.academic.homework {
            let task = brain.academic.homeworkTask(for: item)
            covered.insert(item.taskID.uuidString)
            out.append(HomeworkStatus(id: item.id, moduleCode: item.moduleCode, title: item.title, due: item.due,
                                      done: task?.completedAt != nil))
        }
        for t in tasks() where !covered.contains(t.id) && t.assessmentID == nil {
            guard let module = t.moduleCode, TaskKind.classify(title: t.title, notes: t.notes) == .problemSet else { continue }
            out.append(HomeworkStatus(id: t.id, moduleCode: module, title: t.title, due: t.deadline, done: t.completedAt != nil))
        }
        return out
    }

    func buildOnTrackReport(now: Date) -> OnTrackReport? {
        guard let context, let brain else { return nil }
        let modules = context.all(StoredModule.self).map(\.value)
        guard !modules.isEmpty else { return nil }
        let events = context.all(StoredEvent.self).map(\.value)
        let blocks = context.all(StoredBlock.self)
        let input = OnTrackReportBuilder.Inputs(
            modules: modules,
            assessments: context.all(StoredAssessment.self).map(\.value),
            readings: context.all(StoredReading.self).map(\.value),
            notes: context.all(StoredNote.self).map(\.stub),
            lectures: events.filter(StudyCoach.isLecture),
            homework: homeworkStatuses(),
            tasks: context.all(StoredTask.self).map(\.value),
            blocks: blocks.filter { !$0.skipped }.map(\.value),
            focusLog: state.focusLog,
            completedBlockIDs: Set(blocks.filter(\.completed).map(\.uuid)))
        return OnTrackReportBuilder(prefs: prefs, academic: brain.academic.calendar).build(input, now: now)
    }

    /// Sunday from 18:00, once a week (or on wake if the Mac was asleep).
    func runWeeklyReportIfDue(now: Date) async {
        guard cal.weekday(now) == 1, cal.minuteOfDay(now) >= 18 * 60 else { return }
        let key = cal.format(now, "YYYY-'W'ww")
        guard state.lastReportWeek != key else { return }
        state.lastReportWeek = key
        save()
        await makeWeeklyReport(now: now, notifyStudent: true)
    }

    /// Builds, narrates (short, from the metrics only) and stores the report.
    @discardableResult
    func makeWeeklyReport(now: Date = Date(), notifyStudent: Bool = false) async -> OnTrackReport? {
        guard var report = buildOnTrackReport(now: now) else { return nil }
        if let router {
            let narrative = try? await report.narrate(using: router)
            report.narrative = narrative
        }
        state.reports.removeAll { $0.weekKey == report.weekKey }
        state.reports.insert(report, at: 0)
        state.reports = Array(state.reports.sorted { $0.generatedAt > $1.generatedAt }.prefix(52))
        save()
        OrbitLog.log("report", "weekly report \(report.weekKey): \(report.overall.rawValue)")
        if notifyStudent {
            let body = report.topActions.first.map { "First: \($0)." } ?? (report.narrative ?? report.headline)
            notify(id: "ontrack-\(report.weekKey)", title: "On track for a First? \(report.headline)",
                   body: String(body.prefix(220)), category: "brief")
        }
        return report
    }

    var latestReport: OnTrackReport? { state.reports.first }

    func weeklyReportText() -> String {
        guard let r = latestReport ?? buildOnTrackReport(now: Date()) else { return "No modules yet, so there's no report." }
        var s = r.plainText
        if let n = r.narrative { s = n + "\n\n" + s }
        return "Report from \(cal.shortDay(r.generatedAt)):\n" + s
    }
}
