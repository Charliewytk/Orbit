import AppKit
import Foundation
import Observation
import SwiftData
import OrbitCore

/// Orbit's "extras" on the Mac: flashcards, the weekly on-track report, feedback
/// reminders, focus mode, quick capture, the reading planner, deadline alerts,
/// money and auto-updates. Owns their state and runs their jobs from one timer.
///
/// Started from `OrbitBrain.start()` with `FeatureHub.shared.start(brain: self)`.
/// Views read `FeatureHub.shared` (it's @Observable).
@MainActor
@Observable
final class FeatureHub {
    static let shared = FeatureHub()

    @ObservationIgnored weak var brain: OrbitBrain?
    @ObservationIgnored let files = FeatureFiles()
    /// Persisted feature state (local to this Mac).
    var state: FeatureState

    let focus = FocusController()
    let money = MoneyService()
    let updates = UpdateService()
    let capture = QuickCaptureController()

    // UI status
    var flashcardStatus = ""
    var generatingFlashcards = false
    var readingStatus = ""

    /// Hooks the academic side (or tests) can set to supply extra material.
    @ObservationIgnored var studyMaterialProvider: (@MainActor () -> [StudyMaterial])?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?

    private init() {
        state = files.load(FeatureState.self, "feature-state.json") ?? FeatureState()
    }

    var context: ModelContext? { brain?.context }
    var prefs: UserPrefs { brain?.prefs ?? UserPrefs() }
    var cal: DayCalendar { DayCalendar(timeZone: prefs.timeZone) }

    // MARK: Lifecycle

    func start(brain: OrbitBrain) {
        guard !started else { return }
        started = true
        self.brain = brain
        OrbitLog.log("features", "starting")
        focus.hub = self
        money.hub = self
        updates.hub = self
        capture.hub = self
        focus.restore(state.activeFocus)
        capture.registerFromSettings()
        money.load()
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FeatureHub.shared.willTerminate() }
        }
        loop = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(45))
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick(now: Date())
                try? await Task.sleep(for: .seconds(60))
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            await self.updates.check(reason: "launch")
        }
    }

    func willTerminate() {
        focus.appWillTerminate()
        save()
        money.save()
    }

    /// Every minute. Each job decides for itself whether it's due.
    func tick(now: Date) async {
        guard brain != nil else { return }
        await runDeadlineAlerts(now: now)
        focus.tick(now: now)
        learnFromCompletedTasks()
        await ensureDailyFlashcardReview(now: now)
        await planReadingIfNeeded(now: now)
        remindFeedbackForNewPlans()
        await runWeeklyReportIfDue(now: now)
        await generateFlashcardsIfDue(now: now)
        await money.syncIfDue(now: now)
        await updates.checkIfDue(now: now)
        save()
    }

    func save() { files.save(state, "feature-state.json") }

    // MARK: Store helpers

    func tasks() -> [StoredTask] { context?.all(StoredTask.self) ?? [] }

    /// Tells the brain tasks changed (replan + widgets).
    func tasksChanged() { brain?.tasksChanged() }

    func notify(id: String, title: String, body: String, category: String, onMac: Bool = true) {
        brain?.notify(id: id, title: title, body: body, category: category, onMac: onMac)
    }

    func toast(_ message: String) { brain?.app?.show(message) }

    var router: LLMRouter? { brain?.router }

    /// True when chat answers come only from the Mac's own AI (local-only mode).
    func aiIsLocalOnly() async -> Bool {
        guard let router else { return false }
        if await router.localOnly { return true }
        let providers = await router.providers
        return providers.allSatisfy(\.isLocal)
    }
}

// MARK: - Settings (UserDefaults, this Mac only)

enum FeatureSettings {
    static var defaults: UserDefaults { .standard }

    static let quickCaptureEnabled = "features.quickCapture.enabled"
    static let quickCaptureKeyCode = "features.quickCapture.keyCode"
    static let quickCaptureModifiers = "features.quickCapture.modifiers"
    static let focusUseShortcuts = "features.focus.useShortcuts"
    static let quietStart = "features.deadlines.quietStart"
    static let quietEnd = "features.deadlines.quietEnd"
    static let quietEnabled = "features.deadlines.quietEnabled"
    static let deadlineAlertsEnabled = "features.deadlines.enabled"
    static let readingPlannerEnabled = "features.reading.enabled"
    static let flashcardGenerationEnabled = "features.flashcards.generate"
    static let dailyReviewTaskEnabled = "features.flashcards.dailyTask"
    static let autoUpdateEnabled = "features.updates.auto"

    static func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    static func int(_ key: String, default value: Int) -> Int {
        defaults.object(forKey: key) == nil ? value : defaults.integer(forKey: key)
    }

    static var quietHours: QuietHours {
        QuietHours(start: int(quietStart, default: 23 * 60), end: int(quietEnd, default: 8 * 60),
                   enabled: bool(quietEnabled, default: true))
    }
}

// MARK: - Persistence

/// JSON files in ~/Library/Application Support/Orbit/Features (never synced).
struct FeatureFiles {
    let root: URL

    init(subdirectory: String = "Features") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Orbit", isDirectory: true).appendingPathComponent(subdirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
        do { return try Self.decoder.decode(T.self, from: data) } catch {
            OrbitLog.log("features", "couldn't read \(name): \(error)")
            return nil
        }
    }

    /// Writes atomically with owner-only permissions (0600).
    func save<T: Encodable>(_ value: T, _ name: String) {
        let url = root.appendingPathComponent(name)
        do {
            try Self.encoder.encode(value).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            OrbitLog.log("features", "couldn't save \(name): \(error)")
        }
    }
}

/// Everything the features remember between launches. Every field decodes
/// leniently so adding a field never wipes the rest.
struct FeatureState: Codable {
    // Flashcards
    var processedMaterials: [String: String] = [:]
    var cardMeta: [String: FlashcardMeta] = [:]
    var lastFlashcardRun: Date?
    var lastReviewTaskDay: String?
    var reviewedToday: [String: Int] = [:]
    // Weekly report
    var reports: [OnTrackReport] = []
    var lastReportWeek: String?
    // Focus
    var focusLog: [FocusLogEntry] = []
    var activeFocus: FocusSession?
    var learner = DurationLearner()
    var appliedMultipliers: [String: Double] = [:]
    var learnedTaskIDs: Set<String> = []
    // Deadlines
    var sentDeadlineAlerts: [String: Date] = [:]
    // Feedback
    var remindedAssessments: Set<String> = []
    // Reading
    var lastReadingPlan: Date?
    var readingFingerprint: String?
    var readingChunks: [ReadingChunk] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case processedMaterials, cardMeta, lastFlashcardRun, lastReviewTaskDay, reviewedToday, reports, lastReportWeek,
             focusLog, activeFocus, learner, appliedMultipliers, learnedTaskIDs, sentDeadlineAlerts, remindedAssessments,
             lastReadingPlan, readingFingerprint, readingChunks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A missing or unreadable field falls back to its default.
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            do { return try c.decode(T.self, forKey: key) } catch { return fallback }
        }
        processedMaterials = v(.processedMaterials, [:])
        cardMeta = v(.cardMeta, [:])
        lastFlashcardRun = v(.lastFlashcardRun, nil as Date?)
        lastReviewTaskDay = v(.lastReviewTaskDay, nil as String?)
        reviewedToday = v(.reviewedToday, [:])
        reports = v(.reports, [])
        lastReportWeek = v(.lastReportWeek, nil as String?)
        focusLog = v(.focusLog, [])
        activeFocus = v(.activeFocus, nil as FocusSession?)
        learner = v(.learner, DurationLearner())
        appliedMultipliers = v(.appliedMultipliers, [:])
        learnedTaskIDs = v(.learnedTaskIDs, [])
        sentDeadlineAlerts = v(.sentDeadlineAlerts, [:])
        remindedAssessments = v(.remindedAssessments, [])
        lastReadingPlan = v(.lastReadingPlan, nil as Date?)
        readingFingerprint = v(.readingFingerprint, nil as String?)
        readingChunks = v(.readingChunks, [])
    }
}
