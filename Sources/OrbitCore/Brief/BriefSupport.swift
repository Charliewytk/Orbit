import Foundation

/// Something due soon: a task deadline or an assessment.
public struct DueItem: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case task, assessment }

    public var id: String
    public var kind: Kind
    public var title: String
    public var due: Date
    public var moduleCode: String?
    /// Calendar days from today (0 = today, negative = overdue).
    public var daysLeft: Int
    public var isOverdue: Bool
    public var weightPercent: Double?
    public var remainingMinutes: Int?

    public init(id: String, kind: Kind, title: String, due: Date, moduleCode: String? = nil, daysLeft: Int,
                isOverdue: Bool, weightPercent: Double? = nil, remainingMinutes: Int? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.due = due; self.moduleCode = moduleCode
        self.daysLeft = daysLeft; self.isOverdue = isOverdue; self.weightPercent = weightPercent
        self.remainingMinutes = remainingMinutes
    }
}

/// Shared helpers for the morning brief and evening review.
enum BriefText {
    static let narratorSystemPrompt = """
    You are Orbit, a friendly, practical personal assistant for a University of Exeter student.
    Write in UK English (British spelling, 24-hour times such as 14:00).
    Write 3 to 5 sentences of plain prose: no lists, no headings, no markdown, no emoji.
    Lead with what matters most (deadlines, the first commitment, the main focus), be encouraging but not gushing,
    and only use the facts provided. Never invent events, times or numbers.
    """

    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m)m"
        case (_, 0): return "\(h)h"
        default: return "\(h)h \(m)m"
        }
    }

    static func range(_ start: Date, _ end: Date, _ cal: DayCalendar) -> String {
        "\(cal.time(start))–\(cal.time(end))"
    }

    static func dueLabel(_ item: DueItem, _ cal: DayCalendar) -> String {
        var parts = [item.title]
        var meta: [String] = []
        if let m = item.moduleCode { meta.append(m) }
        if let w = item.weightPercent, w > 0 { meta.append("\(Int(w.rounded()))%") }
        if !meta.isEmpty { parts.append("(\(meta.joined(separator: ", ")))") }
        let when: String
        switch item.daysLeft {
        case ..<0: when = "overdue since \(cal.shortDay(item.due))"
        case 0: when = item.isOverdue ? "overdue (was due \(cal.time(item.due)) today)" : "due today at \(cal.time(item.due))"
        case 1: when = "due tomorrow"
        default: when = "due \(cal.shortDay(item.due)) (in \(item.daysLeft) days)"
        }
        return parts.joined(separator: " ") + " " + when
    }

    /// Asks the AI for a short friendly paragraph from the plain facts.
    static func narrate(facts: String, kind: String, router: LLMRouter) async throws -> String {
        let request = LLMRequest(messages: [
            .system(narratorSystemPrompt),
            .user("Write my \(kind) from these facts:\n\n\(facts)"),
        ], purpose: .reasoning, temperature: 0.4, maxTokens: 400)
        var text = try await router.complete(request).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 1, text.hasPrefix("\""), text.hasSuffix("\"") { text = String(text.dropFirst().dropLast()) }
        return text
    }

    /// Tasks and assessments due between (now - lookback) and the end of `days` days ahead.
    static func dueItems(now: Date, days: Int, tasks: [OrbitTask], assessments: [Assessment], cal: DayCalendar,
                         assessmentLookbackDays: Int = 14) -> [DueItem] {
        let limit = cal.endOfDay(cal.addingDays(days, to: now))
        let weights = Dictionary(assessments.map { ($0.id, $0.weightPercent) }, uniquingKeysWith: { a, _ in a })
        var out: [DueItem] = []
        for t in tasks where !t.isDone {
            guard let d = t.deadline, d < limit else { continue }
            out.append(DueItem(id: t.id.uuidString, kind: .task, title: t.title, due: d, moduleCode: t.moduleCode,
                               daysLeft: cal.days(from: now, to: d), isOverdue: d < now,
                               weightPercent: t.assessmentID.flatMap { weights[$0] },
                               remainingMinutes: t.remainingMinutes))
        }
        let oldest = cal.addingDays(-assessmentLookbackDays, to: cal.startOfDay(now))
        for a in assessments where !a.submitted {
            guard let d = a.due, d < limit, d >= oldest else { continue }
            out.append(DueItem(id: a.id, kind: .assessment, title: a.title, due: d, moduleCode: a.moduleCode,
                               daysLeft: cal.days(from: now, to: d), isOverdue: d < now, weightPercent: a.weightPercent))
        }
        return out.sorted { $0.due != $1.due ? $0.due < $1.due : $0.id < $1.id }
    }
}
