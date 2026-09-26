import Foundation
import Observation
import SwiftData
import OrbitCore
#if canImport(WidgetKit)
import WidgetKit
#endif

/// App-wide state and the actions both apps share. Anything that needs the
/// Mac (AI, Google writes, scheduling) goes through `backend`.
@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    var backend: any OrbitBackend
    /// Cached synced preferences (reloaded on launch and when the app comes forward).
    private(set) var prefs: UserPrefs = UserPrefs()
    private(set) var firstName: String = ""
    /// The toast shown at the bottom of the window (one at a time).
    var toast: Toast?
    /// The current toast's text (kept for older call sites).
    var banner: String? { toast?.text }

    // UI routing shared by the Mac shell, the command palette and the menu bar.
    /// The task selected in Tasks (the inspector shows it).
    var selectedTaskID: String?
    /// The module open in Uni (nil = the year overview).
    var selectedModuleID: String?
    /// The note open in Notes.
    var selectedNoteID: String?

    var context: ModelContext { container.mainContext }
    var calendar: DayCalendar { DayCalendar(timeZone: prefs.timeZone) }

    init(container: ModelContainer, backend: any OrbitBackend) {
        self.container = container
        self.backend = backend
        reloadSettings()
    }

    // MARK: Settings

    func reloadSettings() {
        prefs = context.prefs
        firstName = context.existingSettings?.firstName ?? ""
        AppGroup.defaults.set(firstName, forKey: "firstName")
    }

    func savePrefs(_ new: UserPrefs) {
        guard new != prefs else { return }
        prefs = new
        context.settingsForWriting().prefs = new
        context.saveQuietly()
        backend.tasksChanged()
    }

    func setFirstName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != firstName else { return }
        firstName = trimmed
        let s = context.settingsForWriting()
        s.firstName = trimmed
        s.updatedAt = Date()
        context.saveQuietly()
        AppGroup.defaults.set(trimmed, forKey: "firstName")
    }

    /// Shows a toast. With `undo`, the toast offers Undo and stays a little longer.
    func show(_ message: String, undo: (@MainActor () -> Void)? = nil) {
        let toast = Toast(text: message, undo: undo)
        self.toast = toast
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(undo == nil ? 4 : 6))
            if self.toast?.id == toast.id { self.toast = nil }
        }
    }

    func dismissToast() { toast = nil }

    func undoToast() {
        guard let toast else { return }
        self.toast = nil
        toast.undo?()
    }

    // MARK: Tasks

    func parse(_ text: String, now: Date = Date()) -> QuickAddResult {
        QuickAddParser(now: now, timeZone: prefs.timeZone).parse(text)
    }

    /// Quick add from natural language. The Mac schedules it.
    @discardableResult
    func addTask(text: String) -> StoredTask? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return addTask(parse(trimmed).task)
    }

    @discardableResult
    func addTask(_ task: OrbitTask) -> StoredTask {
        let stored = StoredTask(task: task)
        context.insert(stored)
        context.saveQuietly()
        backend.tasksChanged()
        refreshWidgets()
        return stored
    }

    func toggleComplete(_ task: StoredTask) {
        task.completedAt = task.completedAt == nil ? Date() : nil
        task.updatedAt = Date()
        context.saveQuietly()
        backend.tasksChanged()
        refreshWidgets()
    }

    func taskEdited(_ task: StoredTask) {
        task.updatedAt = Date()
        context.saveQuietly()
        backend.tasksChanged()
        refreshWidgets()
    }

    /// Deletes a task and offers Undo.
    func deleteWithUndo(_ task: StoredTask) {
        let snapshot = task.value
        let notes = task.notes
        let title = task.title
        delete(task)
        show("Deleted “\(title)”", undo: { [weak self] in
            guard let self else { return }
            let restored = self.addTask(snapshot)
            restored.notes = notes
            self.context.saveQuietly()
        })
    }

    func delete(_ task: StoredTask) {
        for b in context.all(StoredBlock.self) where b.taskID == task.id && b.start > Date() { context.delete(b) }
        context.delete(task)
        context.saveQuietly()
        backend.tasksChanged()
        refreshWidgets()
    }

    func task(for block: StoredBlock) -> StoredTask? { context.record(StoredTask.self, id: block.taskID) }

    // MARK: Blocks (Next up)

    func start(_ block: StoredBlock) {
        block.startedAt = Date()
        block.locked = true
        context.saveQuietly()
    }

    func done(_ block: StoredBlock) {
        guard !block.completed else { return }
        block.completed = true
        block.locked = true
        if let task = task(for: block) {
            task.minutesDone += block.minutes
            if task.minutesDone >= task.estimateMinutes { task.completedAt = Date() }
            task.updatedAt = Date()
        }
        context.saveQuietly()
        backend.tasksChanged()
        refreshWidgets()
    }

    /// Skips a block: its work is planned again, not in the same slot.
    func skip(_ block: StoredBlock) {
        let now = Date()
        block.skipped = true
        block.locked = false
        if block.start < now { block.end = max(block.start, now) }
        if let task = task(for: block), !task.isDone {
            task.earliestStart = max(task.earliestStart ?? .distantPast, now.addingTimeInterval(30 * 60))
            task.updatedAt = Date()
        }
        context.saveQuietly()
        backend.tasksChanged()
        refreshWidgets()
    }

    // MARK: Email suggestions

    func addSuggestedTask(_ digest: StoredEmailDigest, index: Int) {
        let list = digest.suggestedTasks
        guard list.indices.contains(index) else { return }
        let s = list[index]
        var task = parse(s.title).task
        task.title = s.title
        task.deadline = s.deadline ?? task.deadline
        task.estimateMinutes = s.estimateMinutes ?? task.estimateMinutes
        task.moduleCode = s.moduleCode ?? task.moduleCode
        task.source = .email
        task.sourceRef = digest.id
        addTask(task)
        digest.addedSuggestions.append("task:\(index)")
        context.saveQuietly()
        show("Added “\(s.title)” to your to-dos")
    }

    func addSuggestedEvent(_ digest: StoredEmailDigest, index: Int) async {
        let list = digest.suggestedEvents
        guard list.indices.contains(index) else { return }
        let s = list[index]
        let plan = StoredPlan(id: "email-\(digest.id)-\(index)")
        plan.title = s.title
        plan.start = s.start
        plan.end = s.end
        plan.location = s.location
        plan.sourceRaw = "email"
        plan.quote = digest.subject
        plan.status = .accepted
        context.insert(plan)
        digest.addedSuggestions.append("event:\(index)")
        context.saveQuietly()
        show("Adding “\(s.title)” to your calendar")
        await backend.planAccepted()
    }

    func markHandled(_ digest: StoredEmailDigest, _ handled: Bool = true) {
        digest.handled = handled
        context.saveQuietly()
    }

    /// Marks an email done with an Undo toast.
    func markHandledWithUndo(_ digest: StoredEmailDigest) {
        markHandled(digest, true)
        show("Marked done", undo: { [weak self] in self?.markHandled(digest, false) })
    }

    // MARK: Plans

    func accept(_ plan: StoredPlan) async {
        plan.status = .accepted
        context.saveQuietly()
        show("Adding “\(plan.title)” to your calendar")
        await backend.planAccepted()
    }

    func dismiss(_ plan: StoredPlan) {
        plan.status = .dismissed
        context.saveQuietly()
    }

    /// Turns extracted plans into pending suggestions, skipping ones already known.
    @discardableResult
    func ingest(plans: [ExtractedPlan], source: String) -> Int {
        guard !plans.isEmpty else { return 0 }
        let events = context.all(StoredEvent.self).map(\.value)
        let existingPlans = context.all(StoredPlan.self)
        let accepted = existingPlans.filter { $0.status == .accepted && $0.calendarEventID == nil }.map(\.event)
        let suggestions = PlanToCalendar().suggestions(for: plans, existing: events + accepted)
        var added = 0
        var known = existingPlans
        for s in suggestions {
            let clash = known.contains {
                $0.id == s.plan.id.uuidString
                    || (abs($0.start.timeIntervalSince(s.event.start)) < 1800 && PlanTitleMatch.similar($0.title, s.event.title))
            }
            guard !clash else { continue }
            let stored = StoredPlan(suggestion: s, source: source)
            context.insert(stored)
            known.append(stored)
            if stored.status == .pending { added += 1 }
        }
        context.saveQuietly()
        return added
    }

    // MARK: Flashcards

    func review(_ card: StoredFlashcard, grade: Int) {
        card.apply(SpacedRepetition.reviewWithLearningSteps(card.value, grade: grade, now: Date()))
        context.saveQuietly()
    }

    // MARK: Uni

    /// "Plan this assessment": breaks it into scheduled chunks (or a revision
    /// timetable for exams), replacing any earlier unfinished plan for it.
    @discardableResult
    func planAssessment(_ assessment: StoredAssessment) -> Int {
        let value = assessment.value
        for t in context.all(StoredTask.self) where t.assessmentID == value.id && !t.isDone { context.delete(t) }
        var topics: [String] = []
        if value.kind == .exam {
            topics = backend.revisionTopics(moduleCode: value.moduleCode)
            if topics.isEmpty {
                topics = RevisionPlanner.topics(fromNotes: context.all(StoredNote.self).map(\.stub),
                                                moduleCode: value.moduleCode)
            }
        }
        var tasks = StudyCoach(prefs: prefs).planAssessment(value, now: Date(), topics: topics)
        for i in tasks.indices {
            tasks[i].assessmentID = value.id
            tasks[i].moduleCode = tasks[i].moduleCode ?? value.moduleCode
            tasks[i].source = .ele
            context.insert(StoredTask(task: tasks[i]))
        }
        assessment.plannedAt = Date()
        context.saveQuietly()
        backend.tasksChanged()
        show(tasks.isEmpty ? "Nothing to plan for “\(value.title)”" : "Planned \(tasks.count) steps for “\(value.title)”")
        return tasks.count
    }

    func setCredits(_ module: StoredModule, _ credits: Int) {
        module.credits = credits
        module.creditsEdited = true
        context.saveQuietly()
    }

    func toggle(_ reading: StoredReading) {
        reading.done.toggle()
        context.saveQuietly()
    }

    // MARK: Share extension inbox

    func ingestPendingInbox() async {
        let items = PendingInbox.loadAll()
        guard !items.isEmpty else { return }
        var tasks = 0, plans = 0
        for item in items {
            switch item.kind {
            case .task:
                let title = item.title ?? item.text ?? ""
                if !title.isEmpty {
                    var task = parse(title).task
                    task.title = title
                    if let m = item.estimateMinutes { task.estimateMinutes = m }
                    if let d = item.deadline { task.deadline = d }
                    if let m = item.moduleCode { task.moduleCode = m }
                    task.source = .message
                    addTask(task)
                    tasks += 1
                }
            case .plan:
                if let title = item.title, let start = item.start {
                    let plan = ExtractedPlan(title: title, start: start, end: item.end, location: item.location,
                                             people: item.people, source: .shared, quote: item.quote ?? item.text ?? "",
                                             confidence: item.confidence ?? 0.6)
                    plans += ingest(plans: [plan], source: "shared")
                }
            case .text:
                if let text = item.text { plans += await importText(text) }
            case .image:
                if let data = PendingInbox.imageData(for: item) { plans += (try? await importScreenshot(data)) ?? 0 }
            }
            PendingInbox.remove(item)
        }
        if tasks + plans > 0 {
            show("From the share sheet: \(tasks) to-do\(tasks == 1 ? "" : "s"), \(plans) plan\(plans == 1 ? "" : "s")")
        }
    }

    // MARK: Widgets

    func refreshWidgets() {
        try? Agenda.widgetSnapshot(context: context).save()
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

/// A short message at the bottom of the window, optionally with Undo.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var undo: (@MainActor () -> Void)?

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}
