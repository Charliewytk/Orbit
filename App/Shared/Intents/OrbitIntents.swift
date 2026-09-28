import AppIntents
import SwiftData
import OrbitCore

/// "Hey Siri, add to Orbit" → asks what, parses it like quick add, saves it.
/// The Mac schedules it on its next pass.
struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Orbit"
    static let description: IntentDescription? = IntentDescription(
        "Adds a to-do. Orbit works out the estimate, deadline and module, then finds it a slot.")

    @Parameter(title: "To-do", requestValueDialog: "What should I add?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to Orbit")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = OrbitStore.shared.mainContext
        let prefs = context.prefs
        let parsed = QuickAddParser(now: Date(), timeZone: prefs.timeZone).parse(text)
        guard !parsed.task.title.isEmpty else {
            return .result(dialog: "I didn't catch a to-do there.")
        }
        context.insert(StoredTask(task: parsed.task))
        try context.save()
        try? Agenda.widgetSnapshot(context: context).save()
        var reply = "Added “\(parsed.task.title)”"
        if let deadline = parsed.task.deadline {
            reply += ", due \(Fmt.dayTime(deadline, DayCalendar(timeZone: prefs.timeZone)))"
        }
        return .result(dialog: "\(reply).")
    }
}

/// "What's next in Orbit?"
struct WhatsNextIntent: AppIntent {
    static let title: LocalizedStringResource = "What's next in Orbit"
    static let description: IntentDescription? = IntentDescription("Tells you what's on now or next.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = OrbitStore.shared.mainContext
        let cal = DayCalendar(timeZone: context.prefs.timeZone)
        let now = Date()
        guard let next = Agenda.nextUp(events: context.all(StoredEvent.self), blocks: context.all(StoredBlock.self),
                                       now: now, calendar: cal) else {
            return .result(dialog: "Nothing else is planned today. Enjoy it.")
        }
        let when = next.contains(now) ? "Right now" : "At \(Fmt.dayTime(next.start, cal, now: now))"
        let what = next.kind == .block ? "you've planned \(next.title)" : "you've got \(next.title)"
        let place = next.location.map { " at \($0)" } ?? ""
        return .result(dialog: "\(when), \(what)\(place).")
    }
}

struct OrbitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddTaskIntent(),
                    phrases: ["Add to \(.applicationName)", "Add a to-do in \(.applicationName)", "\(.applicationName) add a task"],
                    shortTitle: "Add to Orbit", systemImageName: "plus.circle")
        AppShortcut(intent: WhatsNextIntent(),
                    phrases: ["What's next in \(.applicationName)", "What's next on \(.applicationName)", "Ask \(.applicationName) what's next"],
                    shortTitle: "What's next", systemImageName: "clock")
    }
}
