import Foundation
import SwiftData
import OrbitCore

// Conversions between the synced SwiftData records and OrbitCore's value types.
// OrbitCore works on plain values; the app copies them in and out of the store.

enum StoreCoding {
    static func encode<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder().encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    static func uuid(_ s: String) -> UUID { UUID(uuidString: s) ?? StableUUID.make(s) }
}

// MARK: - Tasks

extension StoredTask {
    convenience init(task: OrbitTask) {
        self.init(id: task.id.uuidString, title: task.title)
        createdAt = task.createdAt
        apply(task)
    }

    func apply(_ t: OrbitTask) {
        title = t.title
        notes = t.notes
        estimateMinutes = t.estimateMinutes
        deadline = t.deadline
        earliestStart = t.earliestStart
        priorityRaw = t.priority.rawValue
        energyRaw = t.energy.rawValue
        moduleCode = t.moduleCode
        assessmentID = t.assessmentID
        sourceRaw = t.source.rawValue
        sourceRef = t.sourceRef
        completedAt = t.completedAt
        minutesDone = t.minutesDone
        minBlockMinutes = t.minBlockMinutes
        maxBlockMinutes = t.maxBlockMinutes
        updatedAt = Date()
    }

    var uuid: UUID { StoreCoding.uuid(id) }

    var value: OrbitTask {
        OrbitTask(id: uuid, title: title, notes: notes, estimateMinutes: estimateMinutes, deadline: deadline,
                  earliestStart: earliestStart, priority: priority, energy: energy, moduleCode: moduleCode,
                  assessmentID: assessmentID, source: source, sourceRef: sourceRef, completedAt: completedAt,
                  minutesDone: minutesDone, minBlockMinutes: minBlockMinutes, maxBlockMinutes: maxBlockMinutes,
                  createdAt: createdAt)
    }

    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .normal }
        set { priorityRaw = newValue.rawValue; updatedAt = Date() }
    }

    var energy: Energy {
        get { Energy(rawValue: energyRaw) ?? .medium }
        set { energyRaw = newValue.rawValue; updatedAt = Date() }
    }

    var source: TaskSource { TaskSource(rawValue: sourceRaw) ?? .manual }
    var isDone: Bool { completedAt != nil }
    var remainingMinutes: Int { max(0, estimateMinutes - minutesDone) }
}

// MARK: - Blocks

extension StoredBlock {
    convenience init(block: ScheduledBlock) {
        self.init(id: block.id.uuidString)
        apply(block)
    }

    func apply(_ b: ScheduledBlock) {
        taskID = b.taskID.uuidString
        title = b.title
        start = b.start
        end = b.end
        moduleCode = b.moduleCode
        externalEventID = b.externalEventID
        locked = b.locked
    }

    var uuid: UUID { StoreCoding.uuid(id) }

    var value: ScheduledBlock {
        ScheduledBlock(id: uuid, taskID: StoreCoding.uuid(taskID), title: title, start: start, end: end,
                       moduleCode: moduleCode, externalEventID: externalEventID, locked: locked)
    }

    var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
}

// MARK: - Events

extension StoredEvent {
    static func key(_ e: CalendarEvent) -> String { "\(e.calendarID)|\(e.id)" }

    convenience init(event: CalendarEvent) {
        self.init(id: StoredEvent.key(event))
        apply(event)
    }

    func apply(_ e: CalendarEvent) {
        eventID = e.id
        title = e.title
        start = e.start
        end = e.end
        isAllDay = e.isAllDay
        location = e.location
        notes = e.notes.map { String($0.prefix(600)) }
        calendarID = e.calendarID
        sourceRaw = e.source.rawValue
        isBusy = e.isBusy
        syncedAt = Date()
    }

    var source: CalendarSource { CalendarSource(rawValue: sourceRaw) ?? .google }

    var value: CalendarEvent {
        CalendarEvent(id: eventID, title: title, start: start, end: end, isAllDay: isAllDay, location: location,
                      notes: notes, calendarID: calendarID, source: source, isBusy: isBusy)
    }
}

// MARK: - Email

extension StoredEmailDigest {
    convenience init(digest: EmailDigest) {
        self.init(id: digest.id)
        apply(digest)
    }

    /// Updates triage fields; keeps what the student did (handled, added suggestions, drafts).
    func apply(_ d: EmailDigest) {
        accountRaw = d.account.rawValue
        from = d.from
        subject = d.subject
        date = d.date
        categoryRaw = d.category.rawValue
        summary = d.summary
        importance = d.importance
        suggestedTasksData = StoreCoding.encode(d.suggestedTasks)
        suggestedEventsData = StoreCoding.encode(d.suggestedEvents)
        if let draft = d.draftReply { draftReply = draft }
        notify = d.notify
    }

    var account: MailAccount { MailAccount(rawValue: accountRaw) ?? .gmail }
    var category: EmailCategory { EmailCategory(rawValue: categoryRaw) ?? .other }
    var suggestedTasks: [SuggestedTask] { StoreCoding.decode([SuggestedTask].self, suggestedTasksData) ?? [] }
    var suggestedEvents: [SuggestedEvent] { StoreCoding.decode([SuggestedEvent].self, suggestedEventsData) ?? [] }

    var value: EmailDigest {
        EmailDigest(id: id, account: account, from: from, subject: subject, date: date, category: category,
                    summary: summary, importance: importance, suggestedTasks: suggestedTasks,
                    suggestedEvents: suggestedEvents, draftReply: draftReply, notify: notify)
    }

    /// Link to open the original message in the browser.
    var webURL: URL? {
        switch account {
        case .gmail:
            return URL(string: "https://mail.google.com/mail/u/0/#all/\(id)")
        case .exeter:
            // Graph message ids are long opaque strings; Apple Mail ids are short row ids.
            guard id.count > 60 else { return URL(string: "https://outlook.office.com/mail/inbox") }
            let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
            return URL(string: "https://outlook.office.com/mail/deeplink/read/\(escaped)")
        }
    }
}

// MARK: - Uni

extension StoredModule {
    convenience init(module: Module) {
        self.init(id: module.code)
        apply(module)
    }

    func apply(_ m: Module) {
        name = m.name
        if !creditsEdited { credits = m.credits }
        eleCourseID = m.eleCourseID ?? eleCourseID
        if let c = m.colorHex { colorHex = c }
    }

    var code: String { id }

    /// ELE weeks decoded from `weeksJSON`.
    var weeks: [ELEModuleWeek] {
        guard let json = weeksJSON, let data = json.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ELEModuleWeek].self, from: data)) ?? []
    }

    func setWeeks(_ weeks: [ELEModuleWeek]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let json = (try? encoder.encode(weeks)).map { String(decoding: $0, as: UTF8.self) }
        if json != weeksJSON { weeksJSON = json }
    }

    var value: Module {
        Module(code: id, name: name, credits: credits, eleCourseID: eleCourseID, colorHex: colorHex)
    }
}

extension StoredAssessment {
    convenience init(assessment: Assessment) {
        self.init(id: assessment.id)
        apply(assessment)
    }

    func apply(_ a: Assessment) {
        moduleCode = a.moduleCode
        title = a.title
        kindRaw = a.kind.rawValue
        if !weightEdited && (a.weightPercent > 0 || weightPercent == 0) { weightPercent = a.weightPercent }
        due = a.due
        wordCount = a.wordCount ?? wordCount
        if let m = a.mark { mark = m }
        submitted = a.submitted || submitted
        eleURL = a.eleURL ?? eleURL
    }

    var kind: AssessmentKind { AssessmentKind(rawValue: kindRaw) ?? .coursework }

    var value: Assessment {
        Assessment(id: id, moduleCode: moduleCode, title: title, kind: kind, weightPercent: weightPercent, due: due,
                   wordCount: wordCount, mark: mark, submitted: submitted, eleURL: eleURL)
    }
}

extension StoredReading {
    convenience init(reading: ReadingItem) {
        self.init(id: reading.id)
        apply(reading)
    }

    func apply(_ r: ReadingItem) {
        moduleCode = r.moduleCode
        title = r.title
        url = r.url
        essential = r.essential
        week = r.week
        done = done || r.done
    }

    var value: ReadingItem {
        ReadingItem(id: id, moduleCode: moduleCode, title: title, url: url, essential: essential, week: week, done: done)
    }
}

extension StoredAnnouncement {
    convenience init(announcement: ELEAnnouncement) {
        self.init(id: announcement.id)
        apply(announcement)
    }

    func apply(_ a: ELEAnnouncement) {
        moduleCode = a.moduleCode
        subject = a.subject
        message = String(a.message.prefix(1500))
        author = a.author
        posted = a.posted
        url = a.url
    }
}

// MARK: - Notes

extension StoredNote {
    convenience init(note: LectureNote) {
        self.init(id: note.id)
        apply(note)
    }

    /// Copies metadata and the typed key points. The full handwriting text stays on the Mac.
    func apply(_ n: LectureNote) {
        title = n.title
        notebook = n.notebook
        section = n.section
        moduleCode = n.moduleCode
        week = n.week
        created = n.created
        modified = n.modified
        keyPoints = String(n.keyPoints.prefix(4000))
        if let s = n.summary { summary = s }
        hasTyped = n.hasTyped
        hasHandwriting = n.hasHandwriting
        let handwriting = n.segments.filter { $0.kind != .typed }
        uncertainWordCount = handwriting.reduce(0) { $0 + $1.uncertainWords.count }
        averageConfidence = handwriting.isEmpty ? 1 : handwriting.map(\.confidence).reduce(0, +) / Double(handwriting.count)
        lowConfidence = averageConfidence < 0.6 || uncertainWordCount >= 5
    }

    /// A metadata-only `LectureNote` for gap detection and weekly reviews.
    var stub: LectureNote {
        var segments: [NoteSegment] = []
        if hasTyped { segments.append(NoteSegment(kind: .typed, text: keyPoints.isEmpty ? title : keyPoints)) }
        if hasHandwriting {
            segments.append(NoteSegment(kind: .handwriting, text: "…", confidence: averageConfidence,
                                        uncertainWords: Array(repeating: "?", count: uncertainWordCount)))
        }
        return LectureNote(id: id, title: title, notebook: notebook, section: section, moduleCode: moduleCode,
                           week: week, created: created, modified: modified, segments: segments, summary: summary)
    }
}

extension StoredFlashcard {
    convenience init(card: Flashcard) {
        self.init(id: card.id.uuidString)
        apply(card)
    }

    func apply(_ c: Flashcard) {
        noteID = c.noteID
        moduleCode = c.moduleCode
        front = c.front
        back = c.back
        easeFactor = c.easeFactor
        intervalDays = c.intervalDays
        repetitions = c.repetitions
        due = c.due
    }

    var value: Flashcard {
        Flashcard(id: StoreCoding.uuid(id), noteID: noteID, moduleCode: moduleCode, front: front, back: back,
                  easeFactor: easeFactor, intervalDays: intervalDays, repetitions: repetitions, due: due)
    }
}

// MARK: - Plans

enum PlanStatus: String { case pending, accepted, dismissed }

extension StoredPlan {
    convenience init(suggestion s: PlanCalendarSuggestion, source: String) {
        self.init(id: s.plan.id.uuidString)
        title = s.event.title
        start = s.event.start
        end = s.event.end
        location = s.event.location
        people = s.plan.people
        sourceRaw = source
        quote = s.plan.quote
        confidence = s.plan.confidence
        kindLabel = s.kind.label
        let day = DayCalendar()
        conflicts = s.conflicts.map { "\(day.time($0.start))–\(day.time($0.end)) \($0.title)" }
        isDuplicate = s.isDuplicate
        statusRaw = s.isDuplicate ? PlanStatus.dismissed.rawValue : PlanStatus.pending.rawValue
    }

    var status: PlanStatus {
        get { PlanStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var event: CalendarEvent {
        let finish = end.flatMap { $0 > start ? $0 : nil } ?? start.addingTimeInterval(PlanToCalendar.defaultDuration(for: title))
        var notes = "Added by Orbit"
        if !quote.isEmpty { notes += " from: “\(quote)”" }
        return CalendarEvent(id: calendarEventID ?? "plan-\(id)", title: title, start: start, end: finish,
                             location: location, notes: notes, calendarID: "orbit", source: .local, isBusy: true)
    }

    var sourceLabel: String {
        switch sourceRaw {
        case "whatsapp": "WhatsApp"
        case "instagram": "Instagram"
        case "imessage": "iMessage"
        case "screenshot": "Screenshot"
        case "email": "Email"
        case "assistant": "Chat"
        default: "Shared"
        }
    }

    var sourceSymbol: String {
        switch sourceRaw {
        case "whatsapp": "phone.bubble"
        case "instagram": "camera"
        case "imessage": "message"
        case "screenshot": "photo"
        case "email": "envelope"
        case "assistant": "text.bubble"
        default: "square.and.arrow.down"
        }
    }
}

// MARK: - Chat

enum ChatRole: String { case user, assistant, command }
enum ChatStatus: String { case queued, processing, answered, failed }

extension StoredChatMessage {
    var role: ChatRole { ChatRole(rawValue: roleRaw) ?? .user }
    var status: ChatStatus {
        get { ChatStatus(rawValue: statusRaw) ?? .answered }
        set { statusRaw = newValue.rawValue }
    }
}

// MARK: - Briefs

enum BriefKind: String { case morning, evening, weekly }

extension StoredBrief {
    static func id(_ kind: BriefKind, day: Date, calendar: DayCalendar) -> String {
        "\(kind.rawValue)-\(calendar.format(day, "yyyy-MM-dd"))"
    }

    var kind: BriefKind { BriefKind(rawValue: kindRaw) ?? .morning }
    var morning: MorningBrief? { StoreCoding.decode(MorningBrief.self, payload) }
    var evening: EveningReview? { StoreCoding.decode(EveningReview.self, payload) }
    var weekly: WeeklyReview? { StoreCoding.decode(WeeklyReview.self, payload) }
}

// MARK: - Settings

extension StoredSettings {
    var prefs: UserPrefs {
        get { StoreCoding.decode(UserPrefs.self, prefsData) ?? UserPrefs() }
        set { prefsData = StoreCoding.encode(newValue); updatedAt = Date() }
    }

    var syncStatus: [String: SyncStatusEntry] {
        get { StoreCoding.decode([String: SyncStatusEntry].self, syncStatusData) ?? [:] }
        set { syncStatusData = StoreCoding.encode(newValue) }
    }

    var connections: [String: Bool] {
        get { StoreCoding.decode([String: Bool].self, connectionsData) ?? [:] }
        set { connectionsData = StoreCoding.encode(newValue) }
    }
}

// MARK: - Context helpers

extension ModelContext {
    func all<T: PersistentModel>(_ type: T.Type) -> [T] {
        (try? fetch(FetchDescriptor<T>())) ?? []
    }

    /// Records by id. Duplicate records (CloudKit can create them when two
    /// devices insert the same id while offline) are deleted here.
    func indexed<T: PersistentModel & StringIdentified>(_ type: T.Type) -> [String: T] {
        var out: [String: T] = [:]
        for item in all(type) {
            if out[item.id] != nil { delete(item) } else { out[item.id] = item }
        }
        return out
    }

    func record<T: PersistentModel & StringIdentified>(_ type: T.Type, id: String) -> T? {
        all(type).first { $0.id == id }
    }

    /// The settings row if one exists. Reading never creates one, so a fresh
    /// device can't overwrite synced preferences with defaults.
    var existingSettings: StoredSettings? {
        let rows = all(StoredSettings.self)
        guard rows.count > 1 else { return rows.first }
        let keep = rows.sorted { a, b in
            if (a.prefsData != nil) != (b.prefsData != nil) { return a.prefsData != nil }
            return a.updatedAt > b.updatedAt
        }
        for extra in keep.dropFirst() {
            if keep[0].syncStatusData == nil { keep[0].syncStatusData = extra.syncStatusData }
            delete(extra)
        }
        return keep[0]
    }

    /// The settings row, created if needed (only call when writing).
    func settingsForWriting() -> StoredSettings {
        if let s = existingSettings { return s }
        let s = StoredSettings()
        insert(s)
        return s
    }

    var prefs: UserPrefs { existingSettings?.prefs ?? UserPrefs() }

    func saveQuietly() {
        guard hasChanges else { return }
        do { try save() } catch { print("Orbit: save failed: \(error)") }
    }
}
