import Foundation
import SwiftData
import OrbitCore

/// `OrbitDataSource` on top of the synced store, for the chat assistant.
/// Reads come straight from SwiftData; the actions that need the Mac
/// (replanning, calendar writes, note search) are handed in as closures so the
/// same class works on the Mac and, in direct-chat mode, on the iPhone.
@MainActor
final class StoreDataSource: OrbitDataSource {
    let context: ModelContext
    var onTasksChanged: (() -> Void)?
    var onPlanAccepted: (() async -> Void)?
    var replanHandler: (() async throws -> SchedulePlan)?
    var lightenHandler: ((Date, Double) async throws -> SchedulePlan)?
    var noteSearchHandler: ((String, String?, Int) async -> [String])?

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: OrbitDataSource

    func tasks() async -> [OrbitTask] {
        context.all(StoredTask.self).map(\.value)
    }

    func events(from: Date, to: Date) async -> [CalendarEvent] {
        context.all(StoredEvent.self).filter { $0.start < to && $0.end > from }.map(\.value)
    }

    func blocks(from: Date, to: Date) async -> [ScheduledBlock] {
        context.all(StoredBlock.self).filter { $0.start < to && $0.end > from && !$0.skipped }.map(\.value)
    }

    func assessments() async -> [Assessment] {
        context.all(StoredAssessment.self).map(\.value)
    }

    func emails(limit: Int, category: EmailCategory?) async -> [EmailDigest] {
        context.all(StoredEmailDigest.self)
            .filter { !$0.handled && $0.category != .ignore && (category == nil || $0.category == category) }
            .sorted { ($0.importance, $0.date) > ($1.importance, $1.date) }
            .prefix(max(1, limit)).map(\.value)
    }

    func searchNotes(_ query: String, moduleCode: String?, limit: Int) async -> [String] {
        if let handler = noteSearchHandler { return await handler(query, moduleCode, limit) }
        return Self.keywordSearch(context.all(StoredNote.self), query: query, moduleCode: moduleCode, limit: limit)
            .map { n in
                let meta = [n.moduleCode, n.week.map { "Week \($0)" }].compactMap { $0 }.joined(separator: ", ")
                let body = [n.summary ?? "", n.keyPoints].filter { !$0.isEmpty }.joined(separator: "\n")
                return "\(n.title)\(meta.isEmpty ? "" : " (\(meta))")\n\(body.prefix(700))"
            }
    }

    func addTask(_ task: OrbitTask) async throws {
        context.insert(StoredTask(task: task))
        context.saveQuietly()
        onTasksChanged?()
    }

    func completeTask(id: UUID) async throws {
        guard let t = context.record(StoredTask.self, id: id.uuidString) else { return }
        t.completedAt = Date()
        t.updatedAt = Date()
        context.saveQuietly()
        onTasksChanged?()
    }

    /// Events from chat become accepted plans, which the Mac writes to the Orbit calendar.
    func addEvent(_ event: CalendarEvent) async throws {
        let plan = StoredPlan(id: UUID().uuidString)
        plan.title = event.title
        plan.start = event.start
        plan.end = event.end
        plan.location = event.location
        plan.sourceRaw = "assistant"
        plan.quote = event.notes ?? ""
        plan.status = .accepted
        context.insert(plan)
        context.saveQuietly()
        await onPlanAccepted?()
    }

    func replan() async throws -> SchedulePlan {
        guard let replanHandler else { return SchedulePlan(warnings: ["Replanning isn't available here."]) }
        return try await replanHandler()
    }

    func lighten(day: Date, fraction: Double) async throws -> SchedulePlan {
        guard let lightenHandler else { return SchedulePlan(warnings: ["Lightening isn't available here."]) }
        return try await lightenHandler(day, fraction)
    }

    // MARK: Extra tools

    /// Tools beyond `StandardTools`: quizzing from flashcards and "am I on track?".
    func extraTools() -> [AssistantTool] {
        [
            AssistantTool(
                name: "flashcards_due",
                description: "Flashcards due for review, to quiz the student. Ask the fronts one at a time.",
                arguments: ["module": "module code (optional)", "limit": "default 5"]
            ) { [weak self] args in
                guard let self else { return "Unavailable." }
                return await self.flashcardsText(module: args["module"]?.string?.uppercased(), limit: args["limit"]?.int ?? 5)
            },
            AssistantTool(
                name: "module_standing",
                description: "Marks so far and what average is needed on remaining work for the target grade, per module."
            ) { [weak self] _ in
                guard let self else { return "Unavailable." }
                return await self.standingText()
            },
        ]
    }

    func flashcardsText(module: String?, limit: Int) -> String {
        var cards = SpacedRepetition.dueCards(context.all(StoredFlashcard.self).map(\.value), now: Date(),
                                              moduleCode: module, limit: max(1, min(20, limit)))
        if cards.isEmpty {
            cards = Array(context.all(StoredFlashcard.self).map(\.value)
                .filter { module == nil || $0.moduleCode == module }.shuffled().prefix(limit))
        }
        if cards.isEmpty { return "No flashcards yet." }
        return cards.map { "Q: \($0.front)\nA: \($0.back)\($0.moduleCode.map { " [\($0)]" } ?? "")" }.joined(separator: "\n\n")
    }

    func standingText() -> String {
        let prefs = context.prefs
        let modules = context.all(StoredModule.self).map(\.value)
        guard !modules.isEmpty else { return "No modules synced from ELE yet." }
        let year = StudyCoach(prefs: prefs).yearStanding(modules: modules, assessments: context.all(StoredAssessment.self).map(\.value))
        var lines = ["Target: \(Int(prefs.targetGrade))%"]
        if let avg = year.currentAverage { lines.append(String(format: "Year average so far: %.1f%%", avg)) }
        if let req = year.requiredAverageOnRemaining { lines.append(String(format: "Needed on remaining work: %.1f%%", req)) }
        for m in year.modules {
            var s = "\(m.moduleCode) (\(m.credits) credits): \(m.outlook.rawValue)"
            if let a = m.currentAverage { s += String(format: ", average %.0f%%", a) }
            if let r = m.requiredAverageOnRemaining { s += String(format: ", needs %.0f%% on the rest", r) }
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    /// Simple keyword search over synced key points and summaries (used on the iPhone).
    static func keywordSearch(_ notes: [StoredNote], query: String, moduleCode: String?, limit: Int) -> [StoredNote] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count > 2 }
        return notes
            .filter { moduleCode == nil || $0.moduleCode?.caseInsensitiveCompare(moduleCode!) == .orderedSame }
            .map { n -> (StoredNote, Int) in
                let hay = "\(n.title) \(n.keyPoints) \(n.summary ?? "")".lowercased()
                let score = words.isEmpty ? 1 : words.reduce(0) { $0 + (hay.contains($1) ? 1 : 0) }
                return (n, score)
            }
            .filter { $0.1 > 0 }
            .sorted { ($0.1, $0.0.modified) > ($1.1, $1.0.modified) }
            .prefix(limit).map(\.0)
    }
}
