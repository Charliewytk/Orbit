import Foundation

// Plain value types shared by every part of Orbit. The app layer mirrors the
// ones that need syncing into SwiftData (see App/Shared/Store).

public enum Priority: Int, Codable, CaseIterable, Comparable, Sendable {
    case low = 0, normal = 1, high = 2, critical = 3
    public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
}

/// How much focus a task needs. Used to match tasks to your best hours.
public enum Energy: Int, Codable, CaseIterable, Comparable, Sendable {
    case low = 0, medium = 1, high = 2
    public static func < (a: Energy, b: Energy) -> Bool { a.rawValue < b.rawValue }
}

public enum TaskSource: String, Codable, Sendable {
    case manual, email, ele, message, notes, assistant
}

public struct OrbitTask: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String
    /// Total estimated minutes of work.
    public var estimateMinutes: Int
    public var deadline: Date?
    /// Don't schedule before this date (e.g. "start next week").
    public var earliestStart: Date?
    public var priority: Priority
    public var energy: Energy
    /// Exeter module code such as "BEM2031".
    public var moduleCode: String?
    /// Link to an assessment this task contributes to.
    public var assessmentID: String?
    public var source: TaskSource
    public var sourceRef: String?
    public var completedAt: Date?
    /// Minutes already done (for partially complete work).
    public var minutesDone: Int
    /// Smallest useful block. Long tasks are split into blocks between min and max.
    public var minBlockMinutes: Int
    public var maxBlockMinutes: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(), title: String, notes: String = "", estimateMinutes: Int = 60,
        deadline: Date? = nil, earliestStart: Date? = nil, priority: Priority = .normal,
        energy: Energy = .medium, moduleCode: String? = nil, assessmentID: String? = nil,
        source: TaskSource = .manual, sourceRef: String? = nil, completedAt: Date? = nil,
        minutesDone: Int = 0, minBlockMinutes: Int = 25, maxBlockMinutes: Int = 120,
        createdAt: Date = Date()
    ) {
        self.id = id; self.title = title; self.notes = notes; self.estimateMinutes = estimateMinutes
        self.deadline = deadline; self.earliestStart = earliestStart; self.priority = priority
        self.energy = energy; self.moduleCode = moduleCode; self.assessmentID = assessmentID
        self.source = source; self.sourceRef = sourceRef; self.completedAt = completedAt
        self.minutesDone = minutesDone; self.minBlockMinutes = minBlockMinutes
        self.maxBlockMinutes = maxBlockMinutes; self.createdAt = createdAt
    }

    public var isDone: Bool { completedAt != nil }
    public var remainingMinutes: Int { max(0, estimateMinutes - minutesDone) }
}

public enum CalendarSource: String, Codable, Sendable {
    case google, orbit, timetable, ele, outlook, local
}

public struct CalendarEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var calendarID: String
    public var source: CalendarSource
    /// Busy events block scheduling. Free/transparent ones don't.
    public var isBusy: Bool

    public init(id: String = UUID().uuidString, title: String, start: Date, end: Date,
                isAllDay: Bool = false, location: String? = nil, notes: String? = nil,
                calendarID: String = "primary", source: CalendarSource = .google, isBusy: Bool = true) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay
        self.location = location; self.notes = notes; self.calendarID = calendarID
        self.source = source; self.isBusy = isBusy
    }

    public var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
}

/// A block of time Orbit has planned for a task. Written to the "Orbit" calendar.
public struct ScheduledBlock: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var taskID: UUID
    public var title: String
    public var start: Date
    public var end: Date
    public var moduleCode: String?
    /// Set once written to Google Calendar.
    public var externalEventID: String?
    public var locked: Bool
    /// Where the work happens ("Forum library (on campus)", "Holland Hall").
    public var locationHint: String?

    public init(id: UUID = UUID(), taskID: UUID, title: String, start: Date, end: Date,
                moduleCode: String? = nil, externalEventID: String? = nil, locked: Bool = false, locationHint: String? = nil) {
        self.id = id; self.taskID = taskID; self.title = title; self.start = start; self.end = end
        self.moduleCode = moduleCode; self.externalEventID = externalEventID; self.locked = locked
        self.locationHint = locationHint
    }

    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

// MARK: - Uni

public struct Module: Identifiable, Codable, Hashable, Sendable {
    public var id: String { code }
    public var code: String
    public var name: String
    public var credits: Int
    /// Moodle course ID on ELE.
    public var eleCourseID: Int?
    /// Hex colour for UI, assigned automatically.
    public var colorHex: String?

    public init(code: String, name: String, credits: Int = 15, eleCourseID: Int? = nil, colorHex: String? = nil) {
        self.code = code; self.name = name; self.credits = credits
        self.eleCourseID = eleCourseID; self.colorHex = colorHex
    }
}

public enum AssessmentKind: String, Codable, Sendable {
    case essay, exam, report, presentation, quiz, coursework, groupwork, other
}

public struct Assessment: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var moduleCode: String
    public var title: String
    public var kind: AssessmentKind
    /// Percentage of the module mark (0–100).
    public var weightPercent: Double
    public var due: Date?
    public var wordCount: Int?
    /// Mark out of 100 once returned.
    public var mark: Double?
    public var submitted: Bool
    public var eleURL: String?

    public init(id: String, moduleCode: String, title: String, kind: AssessmentKind = .coursework,
                weightPercent: Double = 0, due: Date? = nil, wordCount: Int? = nil,
                mark: Double? = nil, submitted: Bool = false, eleURL: String? = nil) {
        self.id = id; self.moduleCode = moduleCode; self.title = title; self.kind = kind
        self.weightPercent = weightPercent; self.due = due; self.wordCount = wordCount
        self.mark = mark; self.submitted = submitted; self.eleURL = eleURL
    }
}

public struct ReadingItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var moduleCode: String
    public var title: String
    public var url: String?
    public var essential: Bool
    public var week: Int?
    public var done: Bool

    public init(id: String, moduleCode: String, title: String, url: String? = nil,
                essential: Bool = false, week: Int? = nil, done: Bool = false) {
        self.id = id; self.moduleCode = moduleCode; self.title = title; self.url = url
        self.essential = essential; self.week = week; self.done = done
    }
}

// MARK: - Email

public enum MailAccount: String, Codable, Sendable { case gmail, exeter }

public struct EmailMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var account: MailAccount
    public var threadID: String?
    public var from: String
    public var fromName: String?
    public var to: [String]
    public var subject: String
    public var snippet: String
    public var body: String
    public var date: Date
    public var isUnread: Bool
    public var labels: [String]

    public init(id: String, account: MailAccount, threadID: String? = nil, from: String,
                fromName: String? = nil, to: [String] = [], subject: String, snippet: String = "",
                body: String = "", date: Date, isUnread: Bool = true, labels: [String] = []) {
        self.id = id; self.account = account; self.threadID = threadID; self.from = from
        self.fromName = fromName; self.to = to; self.subject = subject; self.snippet = snippet
        self.body = body; self.date = date; self.isUnread = isUnread; self.labels = labels
    }
}

public enum EmailCategory: String, Codable, CaseIterable, Sendable {
    case urgent, needsReply, hasDate, uni, other, ignore

    public var emoji: String {
        switch self {
        case .urgent: "🔴"; case .needsReply: "🟠"; case .hasDate: "📅"
        case .uni: "📚"; case .other: "🔵"; case .ignore: "⚪"
        }
    }
}

public struct SuggestedTask: Codable, Hashable, Sendable {
    public var title: String
    public var deadline: Date?
    public var estimateMinutes: Int?
    public var moduleCode: String?
    public init(title: String, deadline: Date? = nil, estimateMinutes: Int? = nil, moduleCode: String? = nil) {
        self.title = title; self.deadline = deadline; self.estimateMinutes = estimateMinutes; self.moduleCode = moduleCode
    }
}

public struct SuggestedEvent: Codable, Hashable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date?
    public var location: String?
    public init(title: String, start: Date, end: Date? = nil, location: String? = nil) {
        self.title = title; self.start = start; self.end = end; self.location = location
    }
}

/// What's stored and synced about an email after triage (not the full body).
public struct EmailDigest: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var account: MailAccount
    public var from: String
    public var subject: String
    public var date: Date
    public var category: EmailCategory
    public var summary: String
    public var importance: Double
    public var suggestedTasks: [SuggestedTask]
    public var suggestedEvents: [SuggestedEvent]
    public var draftReply: String?
    public var notify: Bool

    public init(id: String, account: MailAccount, from: String, subject: String, date: Date,
                category: EmailCategory, summary: String, importance: Double,
                suggestedTasks: [SuggestedTask] = [], suggestedEvents: [SuggestedEvent] = [],
                draftReply: String? = nil, notify: Bool = false) {
        self.id = id; self.account = account; self.from = from; self.subject = subject; self.date = date
        self.category = category; self.summary = summary; self.importance = importance
        self.suggestedTasks = suggestedTasks; self.suggestedEvents = suggestedEvents
        self.draftReply = draftReply; self.notify = notify
    }
}

// MARK: - Notes

public enum NoteSegmentKind: String, Codable, Sendable {
    /// Typed text: treated as the key points.
    case typed
    /// Transcribed handwriting: full lecture detail.
    case handwriting
    /// Diagram or drawing, described in words.
    case diagram
    /// Maths converted to LaTeX.
    case math
}

public struct NoteSegment: Codable, Hashable, Sendable {
    public var kind: NoteSegmentKind
    public var text: String
    /// OCR confidence 0–1 (1 for typed text).
    public var confidence: Double
    /// Words the OCR wasn't sure about.
    public var uncertainWords: [String]

    public init(kind: NoteSegmentKind, text: String, confidence: Double = 1, uncertainWords: [String] = []) {
        self.kind = kind; self.text = text; self.confidence = confidence; self.uncertainWords = uncertainWords
    }
}

public struct LectureNote: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var notebook: String
    public var section: String
    public var moduleCode: String?
    public var week: Int?
    public var created: Date
    public var modified: Date
    public var segments: [NoteSegment]
    public var summary: String?

    public init(id: String, title: String, notebook: String = "", section: String = "",
                moduleCode: String? = nil, week: Int? = nil, created: Date = Date(),
                modified: Date = Date(), segments: [NoteSegment] = [], summary: String? = nil) {
        self.id = id; self.title = title; self.notebook = notebook; self.section = section
        self.moduleCode = moduleCode; self.week = week; self.created = created
        self.modified = modified; self.segments = segments; self.summary = summary
    }

    public var keyPoints: String { segments.filter { $0.kind == .typed }.map(\.text).joined(separator: "\n") }
    public var fullDetail: String { segments.filter { $0.kind == .handwriting }.map(\.text).joined(separator: "\n") }
    public var hasTyped: Bool { segments.contains { $0.kind == .typed && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    public var hasHandwriting: Bool { segments.contains { $0.kind == .handwriting } }
    public var allText: String { segments.map(\.text).joined(separator: "\n") }
}

public struct Flashcard: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var noteID: String?
    public var moduleCode: String?
    public var front: String
    public var back: String
    // Spaced-repetition state (SM-2).
    public var easeFactor: Double
    public var intervalDays: Int
    public var repetitions: Int
    public var due: Date

    public init(id: UUID = UUID(), noteID: String? = nil, moduleCode: String? = nil, front: String, back: String,
                easeFactor: Double = 2.5, intervalDays: Int = 0, repetitions: Int = 0, due: Date = Date()) {
        self.id = id; self.noteID = noteID; self.moduleCode = moduleCode; self.front = front; self.back = back
        self.easeFactor = easeFactor; self.intervalDays = intervalDays; self.repetitions = repetitions; self.due = due
    }
}

// MARK: - Plans from messages

public enum MessageSource: String, Codable, Sendable { case whatsapp, instagram, imessage, screenshot, shared }

public struct ExtractedPlan: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var start: Date
    public var end: Date?
    public var location: String?
    public var people: [String]
    public var source: MessageSource
    public var quote: String
    public var confidence: Double

    public init(id: UUID = UUID(), title: String, start: Date, end: Date? = nil, location: String? = nil,
                people: [String] = [], source: MessageSource, quote: String, confidence: Double = 0.5) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.location = location
        self.people = people; self.source = source; self.quote = quote; self.confidence = confidence
    }
}

// MARK: - Preferences

/// A time of day in minutes after midnight (e.g. 9:30 = 570).
public typealias MinuteOfDay = Int

public struct EnergyWindow: Codable, Hashable, Sendable {
    public var start: MinuteOfDay
    public var end: MinuteOfDay
    public var energy: Energy
    public init(start: MinuteOfDay, end: MinuteOfDay, energy: Energy) {
        self.start = start; self.end = end; self.energy = energy
    }
}

public struct UserPrefs: Codable, Hashable, Sendable {
    public var dayStart: MinuteOfDay
    public var dayEnd: MinuteOfDay
    /// Latest time for focused work (no uni work after this).
    public var workCutoff: MinuteOfDay
    public var lunch: ClosedRange<MinuteOfDay>?
    public var dinner: ClosedRange<MinuteOfDay>?
    public var bufferMinutes: Int
    public var maxFocusMinutesPerDay: Int
    public var energyWindows: [EnergyWindow]
    /// Weekday numbers (1 = Sunday … 7 = Saturday) with no scheduled work.
    public var restDays: Set<Int>
    public var importantSenders: [String]
    public var localOnlyMode: Bool
    public var morningBriefTime: MinuteOfDay
    public var eveningReviewTime: MinuteOfDay
    public var targetGrade: Double
    public var timeZoneID: String
    /// Term dates; nil = Exeter's defaults (`AcademicCalendarConfig.exeter2026`).
    public var academicCalendar: AcademicCalendarConfig?
    /// Meals, reading, shutdown and sleep; nil = Holland Hall defaults (`effectiveRoutine`).
    public var routine: RoutineSettings?

    public init(dayStart: MinuteOfDay = 8 * 60, dayEnd: MinuteOfDay = 22 * 60, workCutoff: MinuteOfDay = 21 * 60,
                lunch: ClosedRange<MinuteOfDay>? = (12 * 60 + 30)...(13 * 60 + 15),
                dinner: ClosedRange<MinuteOfDay>? = (18 * 60 + 30)...(19 * 60 + 15),
                bufferMinutes: Int = 10, maxFocusMinutesPerDay: Int = 6 * 60,
                energyWindows: [EnergyWindow] = [
                    EnergyWindow(start: 9 * 60, end: 12 * 60 + 30, energy: .high),
                    EnergyWindow(start: 13 * 60 + 30, end: 16 * 60, energy: .medium),
                    EnergyWindow(start: 16 * 60, end: 22 * 60, energy: .low),
                ],
                restDays: Set<Int> = [], importantSenders: [String] = [], localOnlyMode: Bool = false,
                morningBriefTime: MinuteOfDay = 7 * 60 + 30, eveningReviewTime: MinuteOfDay = 21 * 60 + 30,
                targetGrade: Double = 70, timeZoneID: String = "Europe/London",
                academicCalendar: AcademicCalendarConfig? = nil, routine: RoutineSettings? = nil) {
        self.dayStart = dayStart; self.dayEnd = dayEnd; self.workCutoff = workCutoff
        self.lunch = lunch; self.dinner = dinner; self.bufferMinutes = bufferMinutes
        self.maxFocusMinutesPerDay = maxFocusMinutesPerDay; self.energyWindows = energyWindows
        self.restDays = restDays; self.importantSenders = importantSenders; self.localOnlyMode = localOnlyMode
        self.morningBriefTime = morningBriefTime; self.eveningReviewTime = eveningReviewTime
        self.targetGrade = targetGrade; self.timeZoneID = timeZoneID; self.academicCalendar = academicCalendar
        self.routine = routine
    }

    /// The teaching calendar to use.
    public var academic: AcademicCalendar { AcademicCalendar(config: academicCalendar ?? .exeter2026) }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    public func energy(at minute: MinuteOfDay) -> Energy {
        energyWindows.first { minute >= $0.start && minute < $0.end }?.energy ?? .medium
    }
}
