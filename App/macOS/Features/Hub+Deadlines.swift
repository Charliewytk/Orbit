import Foundation
import SwiftData
import OrbitCore

extension FeatureHub {
    /// Assessments, homework and plain to-dos with deadlines. Steps of a planned
    /// assessment, reading chunks and review tasks are left out (their parent is covered).
    func deadlineItems(now: Date = Date()) -> [DeadlineItem] {
        guard let context else { return [] }
        let tasks = context.all(StoredTask.self)
        let homeworkIDs = Set((brain?.academic.homework ?? []).map { $0.taskID.uuidString })
        var items: [DeadlineItem] = []
        for a in context.all(StoredAssessment.self) where !a.submitted && a.mark == nil {
            guard let due = a.due, due > now.addingTimeInterval(-3600) else { continue }
            let next = tasks.filter { $0.assessmentID == a.id && $0.completedAt == nil }
                .sorted { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }.first
            let step = next.map { t -> String in
                let name = t.title.components(separatedBy: " · ").last ?? t.title
                return "\(name) (\(Fmt.duration(t.remainingMinutes)) left)"
            }
            items.append(DeadlineItem(id: "assessment-\(a.id)", kind: .assessment, title: a.title, moduleCode: a.moduleCode,
                                      due: due, done: false, nextStep: step ?? (a.plannedAt == nil ? "Plan it in Orbit (Uni → Plan this assessment)" : nil),
                                      weightPercent: a.weightPercent))
        }
        for t in tasks where t.completedAt == nil && t.assessmentID == nil {
            guard let due = t.deadline, due > now.addingTimeInterval(-3600) else { continue }
            let ref = t.sourceRef ?? ""
            if ref.hasPrefix(Self.readingRefPrefix) || ref.hasPrefix("flashcards:") { continue }
            let isHomework = homeworkIDs.contains(t.id) || TaskKind.classify(title: t.title, notes: t.notes) == .problemSet
            let step = t.remainingMinutes > 0 ? "about \(Fmt.duration(t.remainingMinutes)) of work left" : nil
            items.append(DeadlineItem(id: "task-\(t.id)", kind: isHomework ? .homework : .task, title: t.title,
                                      moduleCode: t.moduleCode, due: due, done: false, nextStep: step))
        }
        return items.sorted { $0.due < $1.due }
    }

    func runDeadlineAlerts(now: Date) async {
        guard FeatureSettings.bool(FeatureSettings.deadlineAlertsEnabled, default: true) else { return }
        let planner = DeadlineAlertPlanner(quietHours: FeatureSettings.quietHours, timeZone: prefs.timeZone)
        let sent = Set(state.sentDeadlineAlerts.keys)
        let result = planner.due(deadlineItems(now: now), now: now, sent: sent)
        for key in result.alsoMarkSent { state.sentDeadlineAlerts[key] = now }
        for alert in result.alerts {
            state.sentDeadlineAlerts[alert.id] = now
            notify(id: alert.id, title: alert.title, body: alert.body, category: "deadline")
            OrbitLog.log("deadlines", "alert \(alert.level.hours)h: \(alert.itemID)")
        }
        // Forget keys after a fortnight.
        state.sentDeadlineAlerts = state.sentDeadlineAlerts.filter { now.timeIntervalSince($0.value) < 14 * 86400 }
    }

    func upcomingDeadlinesText(days: Int) -> String {
        let now = Date()
        let limit = now.addingTimeInterval(Double(days) * 86400)
        let items = deadlineItems(now: now).filter { $0.due >= now && $0.due <= limit }
        guard !items.isEmpty else { return "Nothing due in the next \(days) days." }
        return items.map { i in
            var s = "\(cal.shortDay(i.due)) \(cal.time(i.due)): " + (i.moduleCode.map { "\($0) " } ?? "") + i.title
            if let w = i.weightPercent, w > 0 { s += " (\(Int(w.rounded()))%)" }
            s += " [\(i.kind.rawValue)]"
            if let step = i.nextStep { s += " — next: \(step)" }
            return s
        }.joined(separator: "\n")
    }
}
