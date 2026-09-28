import Foundation
import SwiftData
import OrbitCore

extension FeatureHub {
    /// The running list of marker-feedback themes (filled by the academic side from ELE).
    var feedbackLedger: FeedbackLedger { brain?.academic.feedback ?? FeedbackLedger() }

    /// When an assessment's plan starts ("Plan this assessment" or auto-planning), add
    /// last time's feedback to its first step and send one reminder.
    func remindFeedbackForNewPlans(now: Date = Date()) {
        guard let context else { return }
        let ledger = feedbackLedger
        guard !ledger.toWorkOn.isEmpty else { return }
        let allTasks = context.all(StoredTask.self)
        for stored in context.all(StoredAssessment.self) {
            guard let planned = stored.plannedAt, !stored.submitted, stored.mark == nil,
                  !state.remindedAssessments.contains(stored.id) else { continue }
            // Only fresh plans (not everything planned before this feature existed).
            guard now.timeIntervalSince(planned) < 3 * 86400 else { state.remindedAssessments.insert(stored.id); continue }
            let assessment = stored.value
            let reminders = ledger.reminders(for: assessment)
            state.remindedAssessments.insert(stored.id)
            guard !reminders.isEmpty else { continue }
            let steps = allTasks.filter { $0.assessmentID == stored.id && $0.completedAt == nil }
                .sorted { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }
            if let first = steps.first, !first.notes.contains("Feedback to act on") {
                first.notes = "Feedback to act on:\n" + reminders.map { "• " + $0 }.joined(separator: "\n")
                    + (first.notes.isEmpty ? "" : "\n\n" + first.notes)
                first.updatedAt = now
            }
            notify(id: "feedback-reminder-\(stored.id)", title: "Before you start \(assessment.title)",
                   body: reminders[0], category: "ele")
            OrbitLog.log("feedback", "reminders added to \(assessment.moduleCode) \(assessment.title): \(reminders.count)")
        }
        context.saveQuietly()
    }

    func feedbackThemesText(module: String?) -> String {
        let ledger = feedbackLedger
        let work = ledger.toWorkOn.filter { module == nil || $0.modules.contains(module!) }
        let strengths = ledger.strengths.filter { module == nil || $0.modules.contains(module!) }
        guard !work.isEmpty || !strengths.isEmpty else { return "No marker feedback yet." }
        var lines: [String] = []
        if !work.isEmpty {
            lines.append("To work on:")
            lines += work.map { "- \($0.label) (\($0.needsWorkCount)×, last on \($0.lastAssessment))" }
        }
        if !strengths.isEmpty {
            lines.append("Strengths:")
            lines += strengths.map { "- \($0.label) (\($0.praisedCount)×)" }
        }
        return lines.joined(separator: "\n")
    }
}
