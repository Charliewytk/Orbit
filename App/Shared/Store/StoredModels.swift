import Foundation
import SwiftData

// SwiftData models synced through the CloudKit private database.
//
// CloudKit rules followed here:
// - every attribute is optional or has a default value,
// - no @Attribute(.unique) (CloudKit can't enforce it), so each model carries
//   its own `id` string and the app de-duplicates when it reads,
// - no relationships (records link by id instead), which keeps sync simple.
//
// Full email bodies and full handwriting text never go in here: they stay on
// the Mac in Application Support. Only summaries sync.

/// Models whose records are keyed by a string id.
protocol StringIdentified: AnyObject {
    var id: String { get }
}

@Model
final class StoredTask {
    var id: String = ""
    var title: String = ""
    var notes: String = ""
    var estimateMinutes: Int = 60
    var deadline: Date?
    var earliestStart: Date?
    var priorityRaw: Int = 1
    var energyRaw: Int = 1
    var moduleCode: String?
    var assessmentID: String?
    var sourceRaw: String = "manual"
    var sourceRef: String?
    var completedAt: Date?
    var minutesDone: Int = 0
    var minBlockMinutes: Int = 25
    var maxBlockMinutes: Int = 120
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// "Move to later" history (JSON `[DeferralRecord]`), for pushback after repeated moves.
    var deferralHistoryData: Data?

    init(id: String = UUID().uuidString, title: String = "") {
        self.id = id
        self.title = title
    }
}

@Model
final class StoredBlock {
    var id: String = ""
    var taskID: String = ""
    var title: String = ""
    var start: Date = Date()
    var end: Date = Date()
    var moduleCode: String?
    var externalEventID: String?
    var locked: Bool = false
    /// Ticked off with "Done".
    var completed: Bool = false
    /// Skipped with "Skip" (the work gets planned again elsewhere).
    var skipped: Bool = false
    /// Started with "Start" (shows a focus state; the block is locked in place).
    var startedAt: Date?
    /// Where the work happens ("Forum library (on campus)", "Holland Hall").
    var locationHint: String?

    init(id: String = UUID().uuidString) { self.id = id }
}

@Model
final class StoredEvent {
    /// "<calendarID>|<eventID>".
    var id: String = ""
    var eventID: String = ""
    var title: String = ""
    var start: Date = Date()
    var end: Date = Date()
    var isAllDay: Bool = false
    var location: String?
    var notes: String?
    var calendarID: String = ""
    var sourceRaw: String = "google"
    var isBusy: Bool = true
    var syncedAt: Date = Date()

    init(id: String = UUID().uuidString) { self.id = id }
}

@Model
final class StoredEmailDigest {
    var id: String = ""
    var accountRaw: String = "gmail"
    var from: String = ""
    var subject: String = ""
    var date: Date = Date()
    var categoryRaw: String = "other"
    var summary: String = ""
    var importance: Double = 0.3
    /// JSON `[SuggestedTask]`.
    var suggestedTasksData: Data?
    /// JSON `[SuggestedEvent]`.
    var suggestedEventsData: Data?
    var draftReply: String?
    /// True while the Mac is drafting a reply requested from the iPhone.
    var draftRequested: Bool = false
    var draftSavedAt: Date?
    var notify: Bool = false
    /// Hidden from the inbox ("done with this").
    var handled: Bool = false
    /// Suggestions already added, as "task:<index>" / "event:<index>".
    var addedSuggestions: [String] = []

    init(id: String = UUID().uuidString) { self.id = id }
}

@Model
final class StoredModule {
    /// The module code, e.g. "BEM2031".
    var id: String = ""
    var name: String = ""
    var credits: Int = 15
    var eleCourseID: Int?
    var colorHex: String?
    /// Credits typed in by the student (ELE doesn't publish them), so sync never overwrites them.
    var creditsEdited: Bool = false
    /// Weeks from the ELE course page ([ELEModuleWeek] as JSON): slides, readings, tutorials.
    var weeksJSON: String?

    init(id: String = "") { self.id = id }
}

@Model
final class StoredAssessment {
    var id: String = ""
    var moduleCode: String = ""
    var title: String = ""
    var kindRaw: String = "coursework"
    var weightPercent: Double = 0
    var due: Date?
    var wordCount: Int?
    var mark: Double?
    var submitted: Bool = false
    var eleURL: String?
    var weightEdited: Bool = false
    /// Set once "Plan this assessment" created tasks for it.
    var plannedAt: Date?
    /// Extra facts from the ELE assessment table: format, duration, AI status, "TBA" notes.
    var details: String?

    init(id: String = UUID().uuidString) { self.id = id }
}

@Model
final class StoredReading {
    var id: String = ""
    var moduleCode: String = ""
    var title: String = ""
    var url: String?
    var essential: Bool = false
    var week: Int?
    var done: Bool = false

    init(id: String = UUID().uuidString) { self.id = id }
}

@Model
final class StoredAnnouncement {
    var id: String = ""
    var moduleCode: String = ""
    var subject: String = ""
    var message: String = ""
    var author: String?
    var posted: Date?
    var url: String?

    init(id: String = UUID().uuidString) { self.id = id }
}

@Model
final class StoredNote {
    var id: String = ""
    var title: String = ""
    var notebook: String = ""
    var section: String = ""
    var moduleCode: String?
    var week: Int?
    var created: Date = Date()
    var modified: Date = Date()
    /// The typed part of the page (the student's own key points).
    var keyPoints: String = ""
    /// AI summary (five bullets).
    var summary: String?
    var hasTyped: Bool = false
    var hasHandwriting: Bool = false
    /// Some handwriting was hard to read.
    var lowConfidence: Bool = false
    var uncertainWordCount: Int = 0
    var averageConfidence: Double = 1

    init(id: String = UUID().uuidString) { self.id = id }
}

@Model
final class StoredFlashcard {
    var id: String = ""
    var noteID: String?
    var moduleCode: String?
    var front: String = ""
    var back: String = ""
    var easeFactor: Double = 2.5
    var intervalDays: Int = 0
    var repetitions: Int = 0
    var due: Date = Date()

    init(id: String = UUID().uuidString) { self.id = id }
}

@Model
final class StoredPlan {
    var id: String = ""
    var title: String = ""
    var start: Date = Date()
    var end: Date?
    var location: String?
    var people: [String] = []
    /// whatsapp / instagram / imessage / screenshot / shared / email / assistant.
    var sourceRaw: String = "shared"
    var quote: String = ""
    var confidence: Double = 0.5
    /// pending / accepted / dismissed.
    var statusRaw: String = "pending"
    var kindLabel: String?
    /// "10:00 Seminar" style lines for clashes found when it was suggested.
    var conflicts: [String] = []
    var isDuplicate: Bool = false
    /// Set once the event is on the calendar.
    var calendarEventID: String?
    var createdAt: Date = Date()
    /// A "tickets on sale" alert rather than a plan: shown as an info card, never auto-added.
    var isTicketDrop: Bool = false
    /// Where to buy (ticket drops).
    var buyURL: String?
    /// "Add if I buy": the user wants it on the calendar once a ticket email arrives.
    var addIfBought: Bool = false

    init(id: String = UUID().uuidString) { self.id = id }
}

@Model
final class StoredChatMessage {
    var id: String = ""
    /// user / assistant / command.
    var roleRaw: String = "user"
    var text: String = ""
    /// queued / processing / answered / failed.
    var statusRaw: String = "answered"
    /// mac / ios.
    var device: String = "mac"
    var createdAt: Date = Date()
    var toolsUsed: [String] = []
    /// Which AI answered ("OpenCode", "Ollama").
    var provider: String?
    /// For replies: the message being answered.
    var replyToID: String?

    init(id: String = UUID().uuidString) { self.id = id }
}

@Model
final class StoredBrief {
    /// "morning-2026-10-14", "evening-…", "weekly-…".
    var id: String = ""
    /// morning / evening / weekly.
    var kindRaw: String = "morning"
    var date: Date = Date()
    var narrative: String?
    var plainText: String = ""
    /// JSON of `MorningBrief`, `EveningReview` or `WeeklyReview`.
    var payload: Data?
    var createdAt: Date = Date()

    init(id: String = UUID().uuidString) { self.id = id }
}

@Model
final class StoredNotification {
    var id: String = ""
    var title: String = ""
    var body: String = ""
    /// mail / ele / brief / plan / schedule.
    var category: String = "general"
    var createdAt: Date = Date()

    init(id: String = UUID().uuidString) { self.id = id }
}

@Model
final class StoredSettings {
    static let singletonID = "settings"

    var id: String = "settings"
    /// JSON `UserPrefs`.
    var prefsData: Data?
    var firstName: String = ""
    /// Tailscale / LAN address of the Mac, for instant chat from the iPhone.
    var macAddress: String?
    /// Password the Mac's OpenCode server uses when shared with the iPhone.
    var macServerPassword: String?
    /// JSON `[String: SyncStatusEntry]` written by the Mac, shown in Diagnostics.
    var syncStatusData: Data?
    /// JSON `[String: Bool]`: which accounts the Mac has connected.
    var connectionsData: Data?
    var updatedAt: Date = Date()

    init() {}
}

// Conformances kept out of the @Model declarations so the macro's own
// PersistentModel conformance isn't affected.
extension StoredTask: StringIdentified {}
extension StoredBlock: StringIdentified {}
extension StoredEvent: StringIdentified {}
extension StoredEmailDigest: StringIdentified {}
extension StoredModule: StringIdentified {}
extension StoredAssessment: StringIdentified {}
extension StoredReading: StringIdentified {}
extension StoredAnnouncement: StringIdentified {}
extension StoredNote: StringIdentified {}
extension StoredFlashcard: StringIdentified {}
extension StoredPlan: StringIdentified {}
extension StoredChatMessage: StringIdentified {}
extension StoredBrief: StringIdentified {}
extension StoredNotification: StringIdentified {}
extension StoredSettings: StringIdentified {}
