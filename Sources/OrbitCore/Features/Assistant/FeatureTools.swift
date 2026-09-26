import Foundation

/// What the feature tools need from the app. Each method returns short plain text
/// for the model (the app formats it; OrbitCore stays UI-free).
public protocol FeatureToolsProvider: Sendable {
    func flashcardsDueText(module: String?, limit: Int) async -> String
    func startFocus(taskQuery: String, minutes: Int?) async -> String
    func weeklyReportText() async -> String
    func feedbackThemesText(module: String?) async -> String
    func readingPlanText(week: Int?) async -> String
    /// Only when the student explicitly asked about money; only answered by a local model.
    func moneySummaryText() async -> String
    func upcomingDeadlinesText(days: Int) async -> String
    /// True when the current AI is on this Mac (money data never goes to a cloud model).
    func aiIsLocal() async -> Bool
}

public enum FeatureTools {
    public static let names = ["flashcards_due", "start_focus", "weekly_report", "feedback_themes", "reading_plan",
                               "money_summary", "upcoming_deadlines"]

    public static func make(_ p: FeatureToolsProvider) -> [AssistantTool] {
        [
            AssistantTool(
                name: "flashcards_due",
                description: "Flashcards due for review today (for quizzing). Ask the fronts one at a time.",
                arguments: ["module": "module code (optional)", "limit": "default 5"]
            ) { args in
                await p.flashcardsDueText(module: args["module"]?.string?.uppercased(), limit: max(1, min(20, args["limit"]?.int ?? 5)))
            },
            AssistantTool(
                name: "start_focus",
                description: "Start a focus session (timer + Do Not Disturb) on a to-do or planned block.",
                arguments: ["task": "part of the task title", "minutes": "timer length (optional)"],
                mutates: true
            ) { args in
                await p.startFocus(taskQuery: args["task"]?.string ?? "", minutes: args["minutes"]?.int)
            },
            AssistantTool(
                name: "weekly_report",
                description: "The latest 'on track for a First' report: traffic light per module with reasons."
            ) { _ in
                await p.weeklyReportText()
            },
            AssistantTool(
                name: "feedback_themes",
                description: "Recurring themes in marker feedback (what to work on, strengths).",
                arguments: ["module": "module code (optional)"]
            ) { args in
                await p.feedbackThemesText(module: args["module"]?.string?.uppercased())
            },
            AssistantTool(
                name: "reading_plan",
                description: "The reading plan: which readings are split into which daily chunks.",
                arguments: ["week": "teaching week number (optional)"]
            ) { args in
                await p.readingPlanText(week: args["week"]?.int)
            },
            AssistantTool(
                name: "money_summary",
                description: "Balances, this month's spending and safe-to-spend. ONLY use when the user explicitly asks about money."
            ) { _ in
                guard await p.aiIsLocal() else {
                    return "Money data is only shared with the AI on this Mac. Switch on local-only mode (or start Ollama) and ask again."
                }
                return await p.moneySummaryText()
            },
            AssistantTool(
                name: "upcoming_deadlines",
                description: "Deadlines coming up (assessments, homework, tasks) with the next step for each.",
                arguments: ["days": "look-ahead in days (default 7)"]
            ) { args in
                await p.upcomingDeadlinesText(days: max(1, min(60, args["days"]?.int ?? 7)))
            },
        ]
    }

    /// Adds `extra` tools, replacing any existing tool with the same name
    /// (so tool names stay unique for `Assistant`).
    public static func merge(_ base: [AssistantTool], _ extra: [AssistantTool]) -> [AssistantTool] {
        let names = Set(extra.map(\.name))
        return base.filter { !names.contains($0.name) } + extra
    }
}
