import Foundation
import Observation
import SwiftData
import OrbitCore
import ServiceManagement

/// The Mac is Orbit's brain. It owns the AI (OpenCode first, Ollama as
/// backup), the account sign-ins and every sync job, runs the scheduler, and
/// answers chat queued from the iPhone. Everything it learns goes into the
/// synced SwiftData store (summaries only) or Application Support (full text).
@MainActor
@Observable
final class OrbitBrain: OrbitBackend {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    @ObservationIgnored let local = LocalStore()
    let accounts = AccountManager()
    let launcher: OpenCodeLauncher
    let ollama = OllamaManager()
    let router = LLMRouter(providers: [])
    @ObservationIgnored weak var app: AppModel?

    // UI state
    var isThinking = false
    private(set) var running: Set<SyncSource> = []
    private(set) var openCodeUp = false
    var lastProviderName: String?

    // Mac-only state
    @ObservationIgnored var state: BrainState
    @ObservationIgnored var eleSnapshot: ELESnapshot?
    @ObservationIgnored var noteIndex: NoteIndex
    @ObservationIgnored var handwritingProfile: PersonalHandwritingProfile
    @ObservationIgnored var mailCoordinator: MailSyncCoordinator?
    @ObservationIgnored var mailCache: [String: EmailMessage]?
    @ObservationIgnored var calendarClient: (session: OAuthSession, client: GoogleCalendarClient)?
    @ObservationIgnored var assistant: Assistant?
    @ObservationIgnored let dataSource: StoreDataSource
    /// Courses, homework, lectures, reviews and ELE activity (see Brain+Academic.swift for the API).
    let academic = AcademicModel()
    /// The notes Library (file tree, OCR status, to-dos found in notes). See Brain+NotesLibrary.swift.
    let notesLibrary = NotesLibraryModel()
    @ObservationIgnored var academicLoaded = false
    @ObservationIgnored var eleLiveRunning = false

    @ObservationIgnored private var started = false
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored var replanTask: Task<Void, Never>?
    @ObservationIgnored var replanning = false
    @ObservationIgnored var processingQueue = false
    @ObservationIgnored private var taskFingerprint = ""
    @ObservationIgnored private var lastSnapshot: WidgetSnapshot?

    init(container: ModelContainer) {
        self.container = container
        let local = LocalStore()
        launcher = OpenCodeLauncher(workspace: local.openCodeWorkspace, logsDirectory: local.logsDirectory)
        state = local.load(BrainState.self, "state.json") ?? BrainState()
        eleSnapshot = local.load(ELESnapshot.self, "ele-snapshot.json")
        noteIndex = (try? NoteIndex.load(from: local.noteIndexURL)) ?? NoteIndex()
        handwritingProfile = local.load(PersonalHandwritingProfile.self, "handwriting-profile.json") ?? PersonalHandwritingProfile()
        dataSource = StoreDataSource(context: container.mainContext)
        wireDataSource()
    }

    var prefs: UserPrefs { context.prefs }
    var firstName: String { app?.firstName ?? context.existingSettings?.firstName ?? "" }
    var embedder: OllamaProvider { OllamaProvider(baseURL: ollama.baseURL, embeddingModel: "nomic-embed-text") }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        startedAt = Date()
        configureLoginItemOnce()
        configureAISharing()
        rebuildRouter()
        FeatureHub.shared.start(brain: self)
        StudyHub.shared.start(brain: self)
        Task { await accounts.refreshStatus() }

        every(120, after: 0) { await $0.checkAI() }
        every(60, after: 5) { await $0.tick() }
        every(10, after: 6) { await $0.processChatQueue() }
        every(300, after: 3) { await $0.syncCalendar() }
        every(300, after: 10) { await $0.syncMail() }
        every(3600, after: 20) { await $0.syncELE() }
        every(900, after: 150) { await $0.syncELELive() }
        every(1800, after: 40) { await $0.syncNotes() }
        every(900, after: 60) { await $0.syncIMessage() }
    }

    func stop() {
        loops.forEach { $0.cancel() }
        loops = []
        launcher.stop()
        saveState()
        saveIndex()
        if academicLoaded { saveAcademic() }
    }

    /// Runs `job` every `seconds`, starting after `delay`.
    private func every(_ seconds: Double, after delay: Double, _ job: @escaping @MainActor (OrbitBrain) async -> Void) {
        loops.append(Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            while !Task.isCancelled {
                guard let self else { return }
                await job(self)
                try? await Task.sleep(for: .seconds(seconds))
            }
        })
    }

    /// Every minute: briefs, replanning after edits from the iPhone, accepted plans, widgets.
    func tick() async {
        await router.setLocalOnly(prefs.localOnlyMode)
        let fingerprint = currentTaskFingerprint()
        if fingerprint != taskFingerprint {
            let first = taskFingerprint.isEmpty
            taskFingerprint = fingerprint
            if !first { scheduleReplan(after: 2) }
        }
        await writeAcceptedPlans()
        // Give the first calendar and mail syncs a head start before any brief.
        if Date().timeIntervalSince(startedAt) > 90 { await runScheduledBriefs(now: Date()) }
        await academicTick()
        pruneOldRecords()
        refreshWidgetsIfChanged()
    }

    private func currentTaskFingerprint() -> String {
        let tasks = context.all(StoredTask.self).map { "\($0.id)\($0.updatedAt.timeIntervalSince1970)\($0.completedAt != nil)" }
        let blocks = context.all(StoredBlock.self).filter { $0.completed || $0.skipped }.map(\.id)
        return (tasks.sorted() + blocks.sorted()).joined(separator: "|").hashValue.description
    }

    func refreshWidgetsIfChanged() {
        let snap = Agenda.widgetSnapshot(context: context)
        let comparable = WidgetSnapshot(generatedAt: .distantPast, nextUp: snap.nextUp, dueThisWeek: snap.dueThisWeek)
        guard comparable != lastSnapshot else { return }
        lastSnapshot = comparable
        app?.refreshWidgets()
    }

    private func pruneOldRecords() {
        let now = Date()
        for n in context.all(StoredNotification.self) where n.createdAt < now.addingTimeInterval(-7 * 86400) { context.delete(n) }
        for m in context.all(StoredChatMessage.self) where m.role == .command && m.status == .answered
            && m.createdAt < now.addingTimeInterval(-86400) { context.delete(m) }
        for d in context.all(StoredEmailDigest.self) where d.date < now.addingTimeInterval(-45 * 86400) { context.delete(d) }
        for p in context.all(StoredPlan.self) where (p.end ?? p.start) < now.addingTimeInterval(-30 * 86400) { context.delete(p) }
        context.saveQuietly()
    }

    // MARK: AI

    func checkAI() async {
        running.insert(.ai)
        defer { running.remove(.ai) }
        configureAISharing()
        await launcher.ensureRunning()
        openCodeUp = await launcher.isAnswering()
        if openCodeUp { await resolveOpenCodeModel() }
        await ollama.refresh()
        rebuildRouter()
        var parts: [String] = []
        parts.append(openCodeUp ? "OpenCode ✓" : "OpenCode ✗")
        parts.append(ollama.available ? "Ollama ✓ (\(ollama.installed.count) models)" : "Ollama ✗")
        let error: String? = !openCodeUp && !ollama.available
            ? "No AI available. Install OpenCode or Ollama (see docs/SETUP.md)." : nil
        record(.ai, error: error, detail: parts.joined(separator: " · "))
    }

    /// Rebuilds the provider list from the current settings.
    func rebuildRouter() {
        let model = (MacPrefs.string(MacPrefs.openCodeModel) ?? MacPrefs.string(MacPrefs.openCodeResolvedModel))
            .flatMap(OpenCodeProvider.ModelRef.init)
        let openCode = launcher.provider(model: model, variant: openCodeVariant())
        let ollamaProvider = OllamaProvider(baseURL: ollama.baseURL,
                                            model: MacPrefs.string(MacPrefs.ollamaModel) ?? "qwen3:8b",
                                            visionModel: MacPrefs.string(MacPrefs.ollamaVisionModel) ?? "qwen2.5vl:7b")
        let localOnly = prefs.localOnlyMode
        let router = self.router
        Task {
            await router.setProviders([openCode, ollamaProvider])
            await router.setLocalOnly(localOnly)
            await router.setContextProvider { request in await StudyHub.shared.knowledgeContext(for: request) }
        }
        assistant = nil // picks up new settings next time
    }

    /// Lets the iPhone reach this Mac's OpenCode over Tailscale/LAN with a password.
    func configureAISharing() {
        let share = MacPrefs.defaults.bool(forKey: MacPrefs.shareAIWithPhone)
        var password = context.existingSettings?.macServerPassword
        if share && (password ?? "").isEmpty {
            password = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
            context.settingsForWriting().macServerPassword = password
            context.saveQuietly()
        }
        launcher.configureSharing(enabled: share, password: password)
    }

    func providerName(_ kind: LLMProviderKind?) -> String? {
        switch kind {
        case .opencode: "OpenCode"
        case .ollama: "Ollama"
        case .mock: "Test AI"
        case nil: nil
        }
    }

    // MARK: Status

    /// Records a job's outcome in the synced settings row (shown in Diagnostics on both devices).
    func record(_ source: SyncSource, error: String? = nil, detail: String? = nil) {
        let settings = context.settingsForWriting()
        var all = settings.syncStatus
        var entry = all[source.rawValue] ?? SyncStatusEntry()
        entry.lastAttempt = Date()
        if let error {
            entry.lastError = String(error.prefix(500))
        } else {
            entry.lastError = nil
            entry.lastSuccess = Date()
        }
        if let detail { entry.detail = detail }
        OrbitLog.log("sync", "\(source.title): \(error.map { "ERROR \($0)" } ?? "ok")\(detail.map { " · \($0)" } ?? "")")
        all[source.rawValue] = entry
        settings.syncStatus = all
        context.saveQuietly()
    }

    func begin(_ source: SyncSource) -> Bool {
        guard !running.contains(source) else { return false }
        running.insert(source)
        return true
    }

    func end(_ source: SyncSource) { running.remove(source) }

    /// Adds a synced notification (the iPhone shows it) and, optionally, shows it here too.
    func notify(id: String, title: String, body: String, category: String, onMac: Bool = true) {
        guard context.record(StoredNotification.self, id: id) == nil else { return }
        let n = StoredNotification(id: id)
        n.title = title
        n.body = body
        n.category = category
        context.insert(n)
        context.saveQuietly()
        if onMac { Task { await Notifier.post(id: id, title: title, body: body, category: category) } }
    }

    func saveState() { local.save(state, "state.json") }

    func saveIndex() { try? noteIndex.save(to: local.noteIndexURL) }

    // MARK: Login item

    private func configureLoginItemOnce() {
        guard !MacPrefs.defaults.bool(forKey: MacPrefs.loginItemConfigured) else { return }
        MacPrefs.defaults.set(true, forKey: MacPrefs.loginItemConfigured)
        try? SMAppService.mainApp.register()
    }

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            app?.show("Couldn't change the login item: \(error.localizedDescription)")
        }
    }

    // MARK: Data source wiring

    private func wireDataSource() {
        dataSource.onTasksChanged = { [weak self] in self?.tasksChanged() }
        dataSource.onPlanAccepted = { [weak self] in await self?.writeAcceptedPlans() }
        dataSource.replanHandler = { [weak self] in
            guard let self else { return SchedulePlan() }
            return await self.replanNow()
        }
        dataSource.lightenHandler = { [weak self] day, fraction in
            guard let self else { return SchedulePlan() }
            return await self.lightenNow(day: day, fraction: fraction)
        }
        dataSource.noteSearchHandler = { [weak self] query, module, limit in
            guard let self else { return [] }
            return await self.searchNotes(query, moduleCode: module).prefix(limit).map { hit in
                let meta = [hit.moduleCode, hit.week.map { "Week \($0)" }].compactMap { $0 }.joined(separator: ", ")
                return "\(hit.title)\(meta.isEmpty ? "" : " (\(meta))")\(hit.isTyped ? " [key point]" : "")\n\(hit.snippet)"
            }
        }
    }

    // MARK: OrbitBackend

    var isBrain: Bool { true }
    var planRouter: LLMRouter? { router }

    /// ELE-matched lectures (notes status) and their slide links, for the conversational planner.
    func plannerLectures() -> (lectures: [TrackedLecture], links: [String: [URL]]) {
        let docs = academic.knowledge.documents
        var links: [String: [URL]] = [:]
        for l in academic.lectures {
            let urls = l.slideDocumentIDs.compactMap { docs[$0]?.url }.compactMap(URL.init(string:))
            if !urls.isEmpty { links[l.id] = urls }
        }
        return (academic.lectures, links)
    }

    func tasksChanged() {
        taskFingerprint = currentTaskFingerprint()
        scheduleReplan(after: 2)
    }

    func requestReplan() async { _ = await replanNow() }

    func lighten(day: Date, fraction: Double) async { _ = await lightenNow(day: day, fraction: fraction) }

    func planAccepted() async { await writeAcceptedPlans() }

    func syncNow() async {
        await syncCalendar()
        await syncMail()
        await syncELE()
        await syncELELive()
        await syncNotes()
        await syncIMessage()
        _ = await replanNow()
    }
}
