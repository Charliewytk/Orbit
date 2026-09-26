import Foundation
import OrbitCore

// Assistant tools for the Features (flashcards, focus, weekly report, reading plan,
// money, deadlines). Wired in `makeAssistant()` (Brain+Chat.swift) via `withFeatureTools(_:)`.

/// Bridges the tool protocol (Sendable, async) to the main-actor hub.
struct HubToolsProvider: FeatureToolsProvider {
    func flashcardsDueText(module: String?, limit: Int) async -> String {
        await MainActor.run { FeatureHub.shared.flashcardsDueText(module: module, limit: limit) }
    }
    func startFocus(taskQuery: String, minutes: Int?) async -> String {
        await MainActor.run { FeatureHub.shared.startFocus(query: taskQuery, minutes: minutes) }
    }
    func weeklyReportText() async -> String {
        await MainActor.run { FeatureHub.shared.weeklyReportText() }
    }
    func feedbackThemesText(module: String?) async -> String {
        await MainActor.run { FeatureHub.shared.feedbackThemesText(module: module) }
    }
    func readingPlanText(week: Int?) async -> String {
        await MainActor.run { FeatureHub.shared.readingPlanText(week: week) }
    }
    func moneySummaryText() async -> String {
        await MainActor.run { FeatureHub.shared.money.summaryText() }
    }
    func upcomingDeadlinesText(days: Int) async -> String {
        await MainActor.run { FeatureHub.shared.upcomingDeadlinesText(days: days) }
    }
    func aiIsLocal() async -> Bool {
        let hub = await MainActor.run { FeatureHub.shared }
        return await hub.aiIsLocalOnly()
    }
}

extension OrbitBrain {
    /// Adds the feature tools to the assistant's tool list (names stay unique).
    func withFeatureTools(_ base: [AssistantTool]) -> [AssistantTool] {
        FeatureTools.merge(base, featureTools(existing: base))
    }

    /// Feature tools that don't clash with tools the app already has, except
    /// `flashcards_due`, which replaces the simpler one (it adds today's review plan).
    func featureTools(existing: [AssistantTool]) -> [AssistantTool] {
        let taken = Set(existing.map(\.name)).subtracting(["flashcards_due"])
        return FeatureTools.make(HubToolsProvider()).filter { !taken.contains($0.name) }
    }
}
