import Foundation
import SwiftData
import OrbitCore

// MARK: - Academic brain: accessor API for the UI
//
// `brain.academic` (an `AcademicModel`, @Observable, main actor) is everything Orbit
// knows about the courses. Read-only for views:
//
//   brain.academic.calendar                 AcademicCalendar (term dates; Mon 21 Sep 2026 = week 1)
//   brain.academic.currentWeek              AcademicWeek? — .term, .week, .start, .isReadingWeek, .label ("Week 2")
//   brain.academic.weekLabel                "Week 2, w/c Mon 28 Sep" (or "Christmas break")
//   brain.academic.whatsHappening           WhatsHappening? — .thisWeek/.comingWeek [WeekOverview], .dueSoon,
//                                           .text(calendar:) for a ready-made summary
//   brain.academic.homework                 [HomeworkItem] — problem sheets, quizzes, tests, lecture prep (due, estimate, url)
//   brain.academic.homeworkTask(for: item)  the StoredTask Orbit created for it (nil if none/deleted)
//   brain.academic.lectures                 [TrackedLecture] — timetabled sessions with status
//                                           (.upcoming / .notesTaken / .noNotes / .notesIncomplete), slides and notes
//   brain.academic.lectureReviews           [LectureReview] — per module-week: .missed [MissedTopic] (topic + slides),
//                                           .questions [AnsweredQuestion] (question, answer, citations), .coverage
//   brain.academic.activity                 [ELEActivityItem] — ELE feed, newest first (new files, announcements,
//                                           grades, feedback, messages); .line gives "📄 BEE1022 · New file in week 3: …"
//   brain.academic.feedback                 FeedbackLedger — recurring marker feedback (.toWorkOn, .strengths)
//   brain.academic.myAssessments            [ELEMyAssessmentRow] — Exeter's "My Assessments" dashboard block
//   brain.academic.modules                  [CourseModuleInfo] sorted by code
//   brain.academic.weekOverview(module:week:)   WeekOverview? (sessions, lecture materials, readings, homework, assessments)
//   brain.academic.moduleOverview(_:)           ModuleOverview?
//   brain.academic.materials(module:week:)      [CourseDocument] (slides, handouts, sheets… with extracted text)
//   brain.academic.search(_:module:week:kinds:) [KBHit] keyword search over everything (citations included)
//   brain.academic.document(id:)                CourseDocument? (full extracted text)
//   brain.academic.review(module:week:)         LectureReview?
//   brain.academic.status / .isWorking / .lastELELiveSync / .lastResourceRun   progress for a status line
//
// Actions (async, on the brain): `brain.refreshELELive()`, `brain.refreshCourseResources()` (download + index
// now), `brain.reviewLecture(module:week:)` (run the notes-vs-slides review now).
//
// Pipelines (all logged to OrbitLog "academic"):
//   after each ELE course sync → KB update → activity diff → download/index new or changed files →
//     homework detection → tasks created/updated (stable ids) → replan
//   after each notes sync → notes into the KB → lectures matched → NotesReview (missed content +
//     answers to questions in the notes, local AI) → notifications
//   every 15 min (ELE live) → notifications, messages, announcements/forums, grades + feedback,
//     "My Assessments", course updates-since → activity feed (+ early course sync when something changed)
//   every minute (cheap) → daily "what's happening" refresh, Monday "week N starts" note.

@MainActor
@Observable
final class AcademicModel {
    private(set) var calendar = AcademicCalendar.exeter
    private(set) var currentWeek: AcademicWeek?
    private(set) var whatsHappening: WhatsHappening?
    private(set) var homework: [HomeworkItem] = []
    private(set) var lectures: [TrackedLecture] = []
    private(set) var lectureReviews: [LectureReview] = []
    private(set) var activity: [ELEActivityItem] = []
    private(set) var feedback = FeedbackLedger()
    private(set) var myAssessments: [ELEMyAssessmentRow] = []
    private(set) var modules: [CourseModuleInfo] = []
    var status = ""
    var isWorking = false
    var lastELELiveSync: Date?
    var lastResourceRun: Date?

    /// The full knowledge base (large; not observed — views read the published arrays above).
    @ObservationIgnored var knowledge = CourseKnowledgeBase()
    @ObservationIgnored var state = AcademicState()
    @ObservationIgnored weak var context: ModelContext?

    var weekLabel: String {
        if let w = currentWeek { return calendar.describe(w) }
        if let n = calendar.currentOrNextWeek(Date()) { return "Holiday · back \(calendar.describe(n))" }
        return "Holiday"
    }

    func weekOverview(module: String, week: Int) -> WeekOverview? { knowledge.weekOverview(module: module, week: week) }
    func moduleOverview(_ module: String) -> ModuleOverview? { knowledge.moduleOverview(module: module) }
    func materials(module: String, week: Int) -> [CourseDocument] { knowledge.materials(for: module, week: week) }
    func document(id: String) -> CourseDocument? { knowledge.document(id: id) }
    func review(module: String, week: Int) -> LectureReview? {
        lectureReviews.first { $0.moduleCode == module && $0.week == week }
    }

    func search(_ query: String, module: String? = nil, week: Int? = nil, kinds: Set<CourseDocKind>? = nil) -> [KBHit] {
        knowledge.search(query, moduleCode: module, week: week, kinds: kinds, limit: 12)
    }

    func homeworkTask(for item: HomeworkItem) -> StoredTask? {
        context?.record(StoredTask.self, id: item.taskID.uuidString)
    }

    /// Copies the knowledge base into the observed properties.
    func publish(now: Date = Date()) {
        calendar = knowledge.calendar
        currentWeek = calendar.week(for: now)
        whatsHappening = knowledge.whatsHappening(now: now)
        homework = knowledge.homework.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        activity = Array(knowledge.activity.items.prefix(200))
        feedback = knowledge.feedback
        myAssessments = knowledge.myAssessments
        modules = knowledge.modules.values.sorted { $0.code < $1.code }
        lectureReviews = state.reviews.sorted { $0.updatedAt > $1.updatedAt }
    }

    func setLectures(_ l: [TrackedLecture]) { lectures = l }
}

/// Mac-only academic state kept between launches (Application Support/Orbit/academic-state.json).
struct AcademicState: Codable {
    var resources = ResourceCache()
    var reviews: [LectureReview] = []
    /// Homework ids Orbit has made tasks for (a missing task later means the student deleted it).
    var homeworkTasks: [String: String] = [:]
    var notified: Set<String> = []
    var lastResourceRun: Date?
    var lastLiveSync: Date?
    var lastFullSyncTrigger: Date?
    var lastUpdatesCheck: [String: Date] = [:]
    var userID: Int?
    var forums: [ELEForum] = []
    var forumsFetchedAt: Date?
    /// AJAX functions ELE refused, with when (retried after a day).
    var unavailable: [String: Date] = [:]
    var lastHappeningDay: String?
    var lastWeekStartNotice: String?
    var feedbackDone: Set<String> = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resources = (try? c.decode(ResourceCache.self, forKey: .resources)) ?? ResourceCache()
        reviews = (try? c.decode([LectureReview].self, forKey: .reviews)) ?? []
        homeworkTasks = (try? c.decode([String: String].self, forKey: .homeworkTasks)) ?? [:]
        notified = (try? c.decode(Set<String>.self, forKey: .notified)) ?? []
        lastResourceRun = try? c.decode(Date.self, forKey: .lastResourceRun)
        lastLiveSync = try? c.decode(Date.self, forKey: .lastLiveSync)
        lastFullSyncTrigger = try? c.decode(Date.self, forKey: .lastFullSyncTrigger)
        lastUpdatesCheck = (try? c.decode([String: Date].self, forKey: .lastUpdatesCheck)) ?? [:]
        userID = try? c.decode(Int.self, forKey: .userID)
        forums = (try? c.decode([ELEForum].self, forKey: .forums)) ?? []
        forumsFetchedAt = try? c.decode(Date.self, forKey: .forumsFetchedAt)
        unavailable = (try? c.decode([String: Date].self, forKey: .unavailable)) ?? [:]
        lastHappeningDay = try? c.decode(String.self, forKey: .lastHappeningDay)
        lastWeekStartNotice = try? c.decode(String.self, forKey: .lastWeekStartNotice)
        feedbackDone = (try? c.decode(Set<String>.self, forKey: .feedbackDone)) ?? []
    }
}

extension LocalStore {
    /// Application Support/Orbit/Knowledge — the long-term knowledge store (see `KnowledgeStore`).
    var knowledgeStore: KnowledgeStore { KnowledgeStore(directory: root.appendingPathComponent("Knowledge", isDirectory: true)) }
    var knowledgeURL: URL { knowledgeStore.url(.courseKnowledge) }
    var legacyKnowledgeURL: URL { root.appendingPathComponent("course-knowledge.json") }
}

extension OrbitBrain {
    static let academicLog = "academic"

    // MARK: Loading and saving

    /// Loads the knowledge base and state from disk (once, on first use).
    func academicLoadIfNeeded() {
        guard !academicLoaded else { return }
        academicLoaded = true
        academic.context = context
        local.knowledgeStore.migrateLegacy(local.legacyKnowledgeURL, to: .courseKnowledge)
        if let kb = try? CourseKnowledgeBase.load(from: local.knowledgeURL) { academic.knowledge = kb }
        academic.knowledge.calendarConfig = prefs.academicCalendar ?? .exeter2026
        academic.state = local.load(AcademicState.self, "academic-state.json") ?? AcademicState()
        academic.lastELELiveSync = academic.state.lastLiveSync
        academic.lastResourceRun = academic.state.lastResourceRun
        academic.publish()
        wireAcademicDataSource()
        OrbitLog.log(Self.academicLog, "loaded: \(academic.knowledge.documents.count) documents, \(academic.knowledge.homework.count) homework, \(academic.state.reviews.count) reviews")
    }

    func saveAcademic() {
        try? academic.knowledge.save(to: local.knowledgeURL)
        local.save(academic.state, "academic-state.json")
    }

    private func wireAcademicDataSource() {
        dataSource.knowledgeProvider = { [weak self] in self?.academic.knowledge ?? CourseKnowledgeBase() }
        dataSource.lectureReviewsProvider = { [weak self] in self?.academic.state.reviews ?? [] }
        dataSource.embedderProvider = { [weak self] in self?.embedder }
        dataSource.lectureReviewRunner = { [weak self] module, week in await self?.reviewLecture(module: module, week: week) }
    }

    /// Tools and system-prompt context for the chat assistant.
    func academicTools() -> [AssistantTool] {
        academicLoadIfNeeded()
        return AcademicTools.make(dataSource, timeZone: prefs.timeZone)
    }

    func academicContext() -> String {
        academicLoadIfNeeded()
        return AcademicTools.context(academic.knowledge, reviews: academic.state.reviews)
    }

    // MARK: Every minute

    /// Cheap: refreshes "what's happening" once a day (and the timetable copy), and on
    /// Monday morning says which week it is.
    func academicTick(now: Date = Date()) async {
        academicLoadIfNeeded()
        let cal = DayCalendar(timeZone: prefs.timeZone)
        let day = cal.format(now, "yyyy-MM-dd")
        guard academic.state.lastHappeningDay != day else { return }
        academic.state.lastHappeningDay = day
        refreshTimetable(now: now)
        academic.publish(now: now)
        if let w = academic.calendar.week(for: now), cal.weekday(now) == 2, academic.state.lastWeekStartNotice != day {
            academic.state.lastWeekStartNotice = day
            let happening = academic.knowledge.whatsHappening(now: now)
            let due = happening.dueSoon.filter { $0.due < now.addingTimeInterval(7 * 86400) }
            let body = due.isEmpty ? "Tap to see this week's lectures and reading."
                : "Due this week: " + due.prefix(3).map { "\($0.moduleCode) \($0.title)" }.joined(separator: "; ")
            notify(id: "academic-week-\(day)", title: "📅 \(w.label) starts", body: body, category: "ele")
        }
        saveAcademic()
        OrbitLog.log(Self.academicLog, "daily refresh: \(academic.weekLabel)")
    }

    /// Copies timetabled sessions (5 weeks back, 3 ahead) into the knowledge base.
    func refreshTimetable(now: Date = Date()) {
        let from = now.addingTimeInterval(-35 * 86400), to = now.addingTimeInterval(21 * 86400)
        let modules = Array(academic.knowledge.modules.values)
        academic.knowledge.timetable = context.all(StoredEvent.self)
            .filter { $0.start >= from && $0.start <= to && !$0.isAllDay }
            .map(\.value)
            .filter { LectureTracker.moduleCode(of: $0, modules: modules) != nil }
    }

    // MARK: After an ELE course sync

    /// KB update → activity diff → resources → homework → tasks → replan.
    func academicAfterELESync(_ snap: ELEWebSnapshot, previous: ELEWebSnapshot?) async {
        academicLoadIfNeeded()
        academic.isWorking = true
        defer { academic.isWorking = false }
        let started = Date()
        academic.knowledge.calendarConfig = prefs.academicCalendar ?? .exeter2026
        academic.knowledge.update(from: snap)
        refreshTimetable()
        OrbitLog.log(Self.academicLog, "ELE structure: \(snap.contents.count) module page(s) → \(academic.knowledge.documents.count) documents")

        let fresh = academic.knowledge.recordActivity(ELEActivityFeed.changes(from: previous, to: snap))
        announceActivity(fresh)

        let dueForFull = academic.state.lastResourceRun.map { Date().timeIntervalSince($0) > 2 * 3600 } ?? true
        await fetchCourseResources(snap, recheckKnown: dueForFull)
        detectHomework(snap)
        await StudyHub.shared.afterELESync(snap, previous: previous)
        saveAcademic()
        academic.publish()
        OrbitLog.log(Self.academicLog, "ELE pipeline done in \(Int(Date().timeIntervalSince(started)))s")
    }

    /// Downloads, extracts and indexes every file/page linked from each module page
    /// (new ones at once; known ones re-checked with a HEAD when due or flagged as changed).
    func fetchCourseResources(_ snap: ELEWebSnapshot, recheckKnown: Bool, maxDownloads: Int = 80) async {
        guard accounts.eleWebSignedIn else { return }
        let web = accounts.eleWeb
        // Everything on the course pages: files, pages, folders, books, assignments, quizzes, forums.
        let targets = ELECoverage.targets(kb: academic.knowledge, snap: snap)
        var downloaded = 0, unchanged = 0, skipped = 0, failed = 0
        let now = Date()
        for target in targets {
            let cache = academic.state.resources
            let isNew = cache.entries[target.cmid] == nil
            guard isNew || cache.dirty.contains(target.cmid) || (recheckKnown && cache.needsCheck(target.cmid, now: now)) else { continue }
            guard downloaded < maxDownloads else { break }
            academic.status = "Reading \(target.moduleCode): \(target.name)"
            do {
                switch target.itemKind {
                case .page, .book, .assign, .quiz, .forum, .turnitin, .other:
                    guard let url = ELECoverage.fetchURL(for: target, site: Self.eleSite) else { continue }
                    let html = try await web.fetchText(url)
                    let text = Self.mainContent(html)
                    index(target, text: text, head: nil)
                    downloaded += 1
                case .folder:
                    let text = try await folderText(target, web: web)
                    index(target, text: text, head: nil)
                    downloaded += 1
                default:
                    let item = ELEWebItem(cmid: target.cmid, name: target.name, kind: .resource, url: target.url)
                    guard let url = ELEWebParser.downloadURL(for: item) else { continue }
                    let head = try? await web.head(url)
                    if let head, academic.state.resources.isUnchanged(target.cmid, head: head) {
                        academic.state.resources.markChecked(target.cmid, now: now)
                        unchanged += 1
                        continue
                    }
                    if let head, ResourceCache.tooLarge(head.bytes) {
                        academic.state.resources.record(target.cmid, head: head, characters: 0, skipped: "too large (\(head.bytes ?? 0) bytes)")
                        skipped += 1
                        continue
                    }
                    var file = try await web.fetchData(url)
                    if file.contentType.contains("text/html"),
                       let link = ELEWebParser.pluginFileURL(inHTML: String(decoding: file.data, as: UTF8.self)) {
                        file = try await web.fetchData(link)
                    }
                    guard file.data.count <= ResourceCache.maxBytes else {
                        academic.state.resources.record(target.cmid, head: head, characters: 0, skipped: "too large")
                        skipped += 1
                        continue
                    }
                    let asSlides = target.kind == .slides
                    let data = file.data, type = file.contentType, final = file.finalURL
                    let text = await Task.detached(priority: .utility) {
                        ELEDocumentText.text(from: data, contentType: type, url: final, asSlides: asSlides)
                    }.value
                    let effectiveHead = head ?? ResourceCache.Head(finalURL: final, bytes: data.count, contentType: type)
                    if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        index(target, text: text, head: effectiveHead)
                        downloaded += 1
                    } else {
                        academic.state.resources.record(target.cmid, head: effectiveHead, characters: 0,
                                                        skipped: "no text (\(type.isEmpty ? "unknown type" : type))")
                        skipped += 1
                    }
                }
            } catch let e where Self.isELESignInError(e) {
                OrbitLog.log(Self.academicLog, "resources: ELE sign-in expired; stopping")
                break
            } catch {
                failed += 1
                academic.state.resources.markChecked(target.cmid, now: now)
                OrbitLog.log(Self.academicLog, "resource \(target.moduleCode) “\(target.name)” failed: \(error.localizedDescription)")
            }
            // Save now and then so a long first run isn't lost.
            if (downloaded + skipped) % 10 == 9 { saveAcademic() }
        }
        if recheckKnown { academic.state.lastResourceRun = Date(); academic.lastResourceRun = academic.state.lastResourceRun }
        academic.status = ""
        await embedKnowledge()
        OrbitLog.log(Self.academicLog, "resources: \(targets.count) linked, \(downloaded) read, \(unchanged) unchanged, \(skipped) skipped, \(failed) failed")
    }

    /// Embeds new chunks with the local Ollama model (skipped quietly when it isn't running).
    func embedKnowledge() async {
        var kb = academic.knowledge
        let stamp = kb.updatedAt, count = kb.documents.count, activity = kb.activity.items.count
        do {
            let n = try await kb.embedMissing(using: embedder)
            // Only write back if nothing else changed the knowledge base meanwhile.
            if n > 0, academic.knowledge.updatedAt == stamp, academic.knowledge.documents.count == count,
               academic.knowledge.activity.items.count == activity {
                academic.knowledge = kb
                OrbitLog.log(Self.academicLog, "embedded \(n) chunk(s)")
            }
        } catch {
            OrbitLog.log(Self.academicLog, "embeddings skipped: \(error.localizedDescription)")
        }
    }

    private func index(_ target: ResourceTarget, text: String, head: ResourceCache.Head?) {
        let clipped = String(text.prefix(400_000))
        academic.knowledge.upsert(CourseDocument(id: target.documentID, moduleCode: target.moduleCode, term: target.term,
                                                 week: target.week, kind: target.kind, title: target.name, section: target.section,
                                                 url: target.url, cmid: target.cmid, text: clipped))
        academic.state.resources.record(target.cmid, head: head, characters: clipped.count)
    }

    /// Every file in a Moodle folder, as one document.
    private func folderText(_ target: ResourceTarget, web: ELEWebSession) async throws -> String {
        guard let url = URL(string: target.url) else { return "" }
        let html = try await web.fetchText(url)
        let links = UniRegexLite.pluginFileLinks(html).prefix(15)
        var parts: [String] = []
        for link in links {
            guard let u = URL(string: link) else { continue }
            if let head = try? await web.head(u), ResourceCache.tooLarge(head.bytes) { continue }
            guard let file = try? await web.fetchData(u), file.data.count <= ResourceCache.maxBytes else { continue }
            let data = file.data, type = file.contentType, final = file.finalURL
            let text = await Task.detached(priority: .utility) { ELEDocumentText.text(from: data, contentType: type, url: final) }.value
            if let text, !text.isEmpty {
                let name = URL(string: final)?.lastPathComponent.removingPercentEncoding ?? "file"
                parts.append("# \(name)\n\(text)")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// The main region of a Moodle page (drops navigation and footers).
    static func mainContent(_ html: String) -> String {
        if let r = html.range(of: "<div role=\"main\""), let end = html.range(of: "<footer", range: r.upperBound..<html.endIndex) {
            return UniHTML.text(String(html[r.lowerBound..<end.lowerBound]))
        }
        if let r = html.range(of: "id=\"region-main\"") {
            return UniHTML.text(String(html[r.lowerBound...].prefix(300_000)))
        }
        return UniHTML.text(html)
    }

    // MARK: Homework → tasks

    /// Finds set work across modules and creates/updates one task per item (stable ids).
    func detectHomework(_ snap: ELEWebSnapshot) {
        let now = Date()
        let kb = academic.knowledge
        var texts: [Int: String] = [:]
        for d in kb.documents.values { if let cmid = d.cmid { texts[cmid] = d.text } }
        let terms = kb.modules.compactMapValues(\.term)
        let detector = HomeworkDetector(calendar: kb.calendar, now: now)
        let items = detector.detect(snapshot: snap, texts: texts, moduleTerms: terms)
        let before = Set(academic.knowledge.homework.map(\.id))
        academic.knowledge.homework = items

        var created = 0, updated = 0
        let wanted = detector.tasks(for: items)
        let byID = Dictionary(items.map { ($0.taskID.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        for task in wanted {
            let key = task.id.uuidString
            guard let item = byID[key] else { continue }
            if let existing = context.record(StoredTask.self, id: key) {
                guard existing.completedAt == nil else { continue }
                // Keep the student's own edits to title/estimate; refresh the due date and details.
                if existing.deadline != task.deadline || existing.notes != task.notes {
                    existing.deadline = task.deadline
                    existing.notes = task.notes
                    existing.updatedAt = Date()
                    updated += 1
                }
            } else if academic.state.homeworkTasks[item.id] != nil {
                continue // made before and deleted by the student: don't bring it back
            } else {
                context.insert(StoredTask(task: task))
                academic.state.homeworkTasks[item.id] = key
                created += 1
                if !before.contains(item.id) && !before.isEmpty {
                    let cal = DayCalendar(timeZone: prefs.timeZone)
                    let due = item.due.map { " · due \(Fmt.dayTime($0, cal))" } ?? ""
                    notify(id: "homework-\(item.id)", title: "🧮 \(item.moduleCode): \(item.kind == .prep ? "Lecture prep" : "Homework set")",
                           body: "\(item.title)\(due)", category: "ele")
                }
            }
        }
        if created + updated > 0 {
            context.saveQuietly()
            tasksChanged()
        }
        OrbitLog.log(Self.academicLog, "homework: \(items.count) found, \(created) task(s) created, \(updated) updated")
    }

    // MARK: After a notes sync

    /// Notes into the KB, lectures matched, then reviews (missed content + answers) for weeks with notes.
    func academicAfterNotesSync(maxReviews: Int = 4) async {
        academicLoadIfNeeded()
        academic.isWorking = true
        defer { academic.isWorking = false }
        let notes = local.allNotes()
        academic.knowledge.addNotes(notes)
        refreshTimetable()
        let since = Date().addingTimeInterval(-42 * 86400)
        let coverage = Dictionary(academic.state.reviews.flatMap { r in r.lectureIDs.map { ($0, r.coverage ?? 1) } },
                                  uniquingKeysWith: { a, _ in a })
        let tracker = LectureTracker(knowledge: academic.knowledge, notes: notes, coverage: coverage)
        let sessions = tracker.sessions(since: since)
        academic.setLectures(sessions)
        let lectures = sessions.filter { $0.kind == .lecture && $0.status != .upcoming }
        OrbitLog.log(Self.academicLog, "lectures: \(lectures.count) since \(since) — \(lectures.filter { $0.status == .noNotes }.count) without notes")

        // One review per module-week that has notes.
        var groups: [String: [TrackedLecture]] = [:]
        for l in lectures where !l.noteIDs.isEmpty {
            groups[LectureReview.id(moduleCode: l.moduleCode, term: l.term, week: l.week, noteID: l.noteIDs.first), default: []].append(l)
        }
        // Notes tagged with a module and week but no timetable entry still get reviewed.
        for n in notes where n.moduleCode != nil && n.week != nil && n.modified > since {
            let term = academic.knowledge.modules[n.moduleCode!]?.term ?? 1
            let id = LectureReview.id(moduleCode: n.moduleCode!, term: term, week: n.week)
            if groups[id] == nil { groups[id] = [] }
        }
        var ran = 0
        for id in groups.keys.sorted().reversed() where ran < maxReviews {
            let lectures = groups[id] ?? []
            guard let parsed = Self.parseReviewID(id, lectures: lectures) else { continue }
            let (module, term, week) = parsed
            let previous = academic.state.reviews.first { $0.id == id }
            let weekNotes = notes.filter { n in
                n.moduleCode == module && (n.week == week || lectures.contains { $0.noteIDs.contains(n.id) })
            }
            guard !weekNotes.isEmpty else { continue }
            let slides = week.map { academic.knowledge.documents(moduleCode: module, week: $0, kinds: [.slides]) } ?? []
            // Skip when nothing changed and no question is waiting for an answer.
            let unanswered = weekNotes.flatMap(NotesReview.extractQuestions).contains { q in
                !(previous?.questions.contains { $0.question.id == q.id && $0.isAnswered } ?? false)
            }
            if let previous, !unanswered, previous.noteIDs.sorted() == weekNotes.map(\.id).sorted(),
               previous.slideDocumentIDs.sorted() == slides.map(\.id).sorted(),
               previous.updatedAt >= (weekNotes.map(\.modified).max() ?? .distantPast) {
                continue
            }
            let title = week.flatMap { w in academic.knowledge.modules[module]?.weeks.first { $0.week == w }?.title } ?? weekNotes.first?.title ?? module
            let answeredBefore = previous?.questions.filter(\.isAnswered).count ?? 0
            let review = await NotesReview.review(moduleCode: module, term: term, week: week, title: title,
                                                  lectureIDs: lectures.map(\.id), notes: weekNotes, slides: slides,
                                                  kb: academic.knowledge, router: router, previous: previous, embedder: embedder)
            ran += 1
            academic.state.reviews.removeAll { $0.id == id }
            academic.state.reviews.append(review)
            let newlyAnswered = review.questions.filter { $0.isAnswered && !$0.notFound }.count
                - (previous?.questions.filter { $0.isAnswered && !$0.notFound }.count ?? 0)
            OrbitLog.log(Self.academicLog, "review \(id): coverage \(review.coverage.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"), \(review.missed.count) missed, \(review.questions.count) question(s), \(review.questions.filter(\.isAnswered).count - answeredBefore) answered now")
            if let n = review.missedNotification, !review.missed.isEmpty {
                let key = "missed-\(id)-\(review.inputHash.prefix(8))"
                if academic.state.notified.insert(key).inserted {
                    notify(id: key, title: n.title, body: n.body, category: "notes")
                }
            }
            if newlyAnswered > 0, let n = review.answeredNotification(newlyAnswered: newlyAnswered) {
                notify(id: "answered-\(id)-\(review.questions.filter(\.isAnswered).count)", title: n.title, body: n.body, category: "notes")
            }
            saveAcademic()
        }
        // Coverage feeds back into lecture status.
        let cov = Dictionary(academic.state.reviews.flatMap { r in r.lectureIDs.map { ($0, r.coverage ?? 1) } }, uniquingKeysWith: { a, _ in a })
        academic.setLectures(LectureTracker(knowledge: academic.knowledge, notes: notes, coverage: cov).sessions(since: since))
        await embedKnowledge()
        saveAcademic()
        academic.publish()
    }

    static func parseReviewID(_ id: String, lectures: [TrackedLecture]) -> (String, Int?, Int?)? {
        if let l = lectures.first { return (l.moduleCode, l.term, l.week) }
        let parts = id.split(separator: "-")
        guard parts.count == 3, parts[1].hasPrefix("t"), parts[2].hasPrefix("w"),
              let t = Int(parts[1].dropFirst()), let w = Int(parts[2].dropFirst()) else { return nil }
        return (String(parts[0]), t, w)
    }

    /// Runs the notes-vs-slides review for one module week now (used by chat and the UI).
    func reviewLecture(module: String, week: Int) async -> LectureReview? {
        academicLoadIfNeeded()
        let notes = local.allNotes().filter { $0.moduleCode == module && $0.week == week }
        guard !notes.isEmpty else { return nil }
        let term = academic.knowledge.modules[module]?.term ?? 1
        let id = LectureReview.id(moduleCode: module, term: term, week: week)
        let slides = academic.knowledge.documents(moduleCode: module, week: week, kinds: [.slides])
        let title = academic.knowledge.modules[module]?.weeks.first { $0.week == week }?.title ?? notes[0].title
        let review = await NotesReview.review(moduleCode: module, term: term, week: week, title: title, notes: notes,
                                              slides: slides, kb: academic.knowledge, router: router,
                                              previous: academic.state.reviews.first { $0.id == id }, embedder: embedder)
        academic.state.reviews.removeAll { $0.id == id }
        academic.state.reviews.append(review)
        saveAcademic()
        academic.publish()
        return review
    }

    /// Downloads and indexes course files now (ignores the two-hour gap).
    func refreshCourseResources() async {
        academicLoadIfNeeded()
        guard let snap = local.load(ELEWebSnapshot.self, "ele-web-snapshot.json") else { return }
        await fetchCourseResources(snap, recheckKnown: true)
        detectHomework(snap)
        saveAcademic()
        academic.publish()
    }

    // MARK: Notifications

    /// Posts the important new activity (a few at a time; never on the very first sync).
    func announceActivity(_ items: [ELEActivityItem]) {
        guard !items.isEmpty else { return }
        let firstRun = academic.knowledge.activity.items.count == items.count
        OrbitLog.log(Self.academicLog, "activity: \(items.count) new item(s)\(firstRun ? " (first run, not notifying)" : "")")
        guard !firstRun else { return }
        for item in items.filter(\.important).prefix(4) {
            notify(id: "activity-\(item.id)", title: "\(item.kind.emoji) \(item.moduleCode ?? "ELE")",
                   body: String((item.title + (item.detail.isEmpty ? "" : " — \(item.detail)")).prefix(200)), category: "ele")
        }
    }
}

/// Small regex helpers for the app layer.
enum UniRegexLite {
    /// Every pluginfile.php link in a page (folder listings), de-duplicated, in order.
    static func pluginFileLinks(_ html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "(https?://[^\"'\\s<>]+/pluginfile\\.php/[^\"'\\s<>]+)") else { return [] }
        let ns = html as NSString
        var seen = Set<String>(), out: [String] = []
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let link = UniHTML.decodeEntities(ns.substring(with: m.range(at: 1)))
            let clean = link.components(separatedBy: "?").first ?? link
            if seen.insert(clean).inserted { out.append(link) }
        }
        return out
    }
}
