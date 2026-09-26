import AppKit
import Foundation
import SwiftData
import WebKit
import OrbitCore

/// Grades, lecture recordings, exam countdown, group work, daily briefing, weekend review,
/// economics news, money insights and chat search. Logic lives in OrbitCore (Companion/);
/// this runs it on a timer and keeps its JSON on this Mac (Application Support/Orbit/Companion).
@MainActor @Observable
final class CompanionHub {
    static let shared = CompanionHub()

    @ObservationIgnored weak var brain: OrbitBrain?
    @ObservationIgnored let files = FeatureFiles(subdirectory: "Companion")
    @ObservationIgnored private var loop: Task<Void, Never>?

    var state: CompanionState
    var status = ""
    var processingRecording: String?
    var refreshingNews = false

    private init() {
        state = files.load(CompanionState.self, "companion.json") ?? CompanionState()
    }

    var hub: FeatureHub { .shared }
    var context: ModelContext? { brain?.context }
    var prefs: UserPrefs { brain?.prefs ?? UserPrefs() }
    var cal: DayCalendar { DayCalendar(timeZone: prefs.timeZone) }

    func save() { files.save(state, "companion.json") }

    // MARK: Settings (UserDefaults; nothing secret)

    enum Keys {
        static let briefingEnabled = "companion.briefing.enabled"
        static let briefingMinute = "companion.briefing.minute"
        static let recapEnabled = "companion.recap.enabled"
        static let recapMinute = "companion.recap.minute"
        static let recordingsAuto = "companion.recordings.auto"
        static let newsFullText = "companion.news.fullText"
        static let moneyAlerts = "companion.money.alerts"
    }

    var briefingSchedule: BriefingSchedule {
        BriefingSchedule(enabled: FeatureSettings.bool(Keys.briefingEnabled, default: true),
                         minute: FeatureSettings.int(Keys.briefingMinute, default: 7 * 60 + 35))
    }

    var recapSchedule: WeekRecapSchedule {
        WeekRecapSchedule(enabled: FeatureSettings.bool(Keys.recapEnabled, default: true),
                          minute: FeatureSettings.int(Keys.recapMinute, default: 19 * 60))
    }

    // MARK: Lifecycle

    func start(brain: OrbitBrain) {
        guard loop == nil else { return }
        self.brain = brain
        loop = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick(now: Date())
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func tick(now: Date) async {
        refreshGrades(now: now)
        if briefingSchedule.isDue(now: now, lastDay: state.lastBriefingDay, calendar: cal) {
            await makeBriefing(now: now, notify: true)
        }
        if recapSchedule.isDue(now: now, lastRun: state.lastRecap, calendar: cal) {
            makeRecap(now: now, notify: true)
        }
        if state.lastNewsFetch.map({ now.timeIntervalSince($0) > 3 * 3600 }) ?? true {
            await refreshNews(now: now)
        }
        if FeatureSettings.bool(Keys.recordingsAuto, default: true),
           state.lastRecordingScan.map({ now.timeIntervalSince($0) > 2 * 3600 }) ?? true {
            await scanRecordings(now: now)
            await processPendingRecordings(limit: 2)
        }
        if FeatureSettings.bool(Keys.moneyAlerts, default: true) { moneyAlerts(now: now) }
        if state.lastChatExport.map({ now.timeIntervalSince($0) > 600 }) ?? true { exportChatArchive(now: now) }
    }

    // MARK: 1. Grades

    func refreshGrades(now: Date) {
        guard let context else { return }
        let modules = context.all(StoredModule.self).map(\.value)
        guard !modules.isEmpty else { return }
        let before = state.gradeBook
        state.gradeBook.merge(modules: modules, assessments: context.all(StoredAssessment.self).map(\.value), now: now)
        state.gradeBook.updatedAt = before.updatedAt
        if state.gradeBook != before {
            state.gradeBook.updatedAt = now
            save()
        }
    }

    var projection: GradeProjection { GradePredictor.project(state.gradeBook, targets: state.targets) }

    func editGrade(module: String, item: String, weight: Double?, mark: Double??) {
        state.gradeBook.edit(module: module, item: item, weight: weight, mark: mark)
        save()
    }

    func addGradeItem(module: String, title: String, weight: Double) {
        guard let i = state.gradeBook.modules.firstIndex(where: { $0.code == module }) else { return }
        state.gradeBook.modules[i].items.append(.init(title: title, weight: weight, edited: true))
        save()
    }

    func removeGradeItem(module: String, item: String) {
        guard let i = state.gradeBook.modules.firstIndex(where: { $0.code == module }) else { return }
        state.gradeBook.modules[i].items.removeAll { $0.id == item }
        save()
    }

    // MARK: 3. Exam countdown (fed from ExamService's past papers and weak topics)

    func examPlan(now: Date = Date()) -> ExamRevisionPlan {
        let exam = hub.exam
        return ExamCountdownPlanner(calendar: cal).plan(assessments: exam.assessments(), pastPapers: exam.pastPapers(),
                                                        weakTopics: exam.weakTopics(), now: now)
    }

    // MARK: 4. Group work

    func update(_ project: GroupProject) { state.groups.update(project); save() }

    func delete(_ project: GroupProject) { state.groups.projects.removeAll { $0.id == project.id }; save() }

    // MARK: 5. Daily briefing

    func makeBriefing(now: Date = Date(), notify: Bool) async {
        guard let brain, let context else { return }
        let cal = self.cal
        let events = context.all(StoredEvent.self).map(\.value)
        let blocks = context.all(StoredBlock.self).map(\.value)
        let tasks = context.all(StoredTask.self).map(\.value)
        let assessments = context.all(StoredAssessment.self).map(\.value)
        let emails = context.all(StoredEmailDigest.self).map(\.value)
        let brief = MorningBriefBuilder(prefs: prefs).build(now: now, events: events, blocks: blocks, tasks: tasks,
                                                            assessments: assessments, emails: emails,
                                                            flashcardsDue: hub.dailyReviewPlan(now: now).dueCount)
        let since = state.lastBriefingDay ?? now.addingTimeInterval(-86400)
        var newItems = brain.academic.activity.filter { $0.date > since }.prefix(8).map {
            DailyBriefing.NewItem(id: $0.id, source: "ELE", title: $0.title, moduleCode: $0.moduleCode, url: $0.url)
        }
        newItems += hub.ed.state.items.filter { $0.date > since && !$0.baseline }.prefix(6).map {
            DailyBriefing.NewItem(id: $0.id, source: "Ed", title: $0.title, moduleCode: $0.moduleCode, url: $0.url)
        }
        let momentum = hub.stats.momentum(tasks: context.all(StoredTask.self), blocks: context.all(StoredBlock.self))
        if state.todaysNewsDay.map({ !cal.isSameDay($0, now) }) ?? true { await refreshNews(now: now) }
        let exams = examPlan(now: now)
        let examLine = exams.exams.first(where: \.inWindow).map { e in
            let today = exams.sessions(on: now, calendar: cal).map(\.title).joined(separator: "; ")
            return "\(e.moduleCode) exam in \(e.daysLeft) days." + (today.isEmpty ? "" : " Today: \(today).")
        }
        let groupDue = state.groups.myDue(now: now, days: 3).map { "\($0.task.title) (\($0.project.name))" }
        let saturday = cal.weekday(now) == 7
        let weather = await fetchWeather()
        let recap: WeekRecap? = saturday ? buildRecap(now: now) : nil
        var briefing = DailyBriefing(day: cal.startOfDay(now), generatedAt: now, weather: weather, brief: brief,
                                     newOnELE: Array(newItems), keyEmail: DailyBriefing.keyEmail(emails, now: now),
                                     streakDays: momentum.streak(now: now), flashcardStreak: 0, news: state.todaysNews,
                                     weeklyReview: recap, groupTasksDue: groupDue, examLine: examLine)
        briefing.brief = await brief.narrated(using: brain.router)
        state.briefing = briefing
        state.lastBriefingDay = now
        save()
        if notify {
            brain.notify(id: "briefing|\(cal.format(now, "yyyy-MM-dd"))", title: briefing.notificationTitle,
                         body: briefing.notificationBody, category: "briefing")
        }
    }

    private func fetchWeather() async -> WeatherToday? {
        guard let result = try? await URLSession.shared.data(from: OpenMeteo.forecastURL()) else { return nil }
        return OpenMeteo.parse(result.0)
    }

    // MARK: 6. Weekend review (Saturday and Sunday evening)

    func buildRecap(now: Date) -> WeekRecap? {
        guard let context else { return nil }
        let momentum = hub.stats.momentum(tasks: context.all(StoredTask.self), blocks: context.all(StoredBlock.self))
        let groupDue = state.groups.myDue(now: now, days: 7).map { "\($0.task.title) (\($0.project.name))" }
        return WeekRecapBuilder(calendar: cal).build(now: now, tasks: context.all(StoredTask.self).map(\.value),
                                                     assessments: context.all(StoredAssessment.self).map(\.value),
                                                     events: context.all(StoredEvent.self).map(\.value),
                                                     days: Array(momentum.days.values), groupDue: groupDue)
    }

    func makeRecap(now: Date = Date(), notify: Bool) {
        guard let recap = buildRecap(now: now) else { return }
        state.recap = recap
        state.lastRecap = now
        save()
        if notify {
            brain?.notify(id: "recap|\(cal.format(now, "yyyy-MM-dd"))", title: "Weekly review", body: recap.headline + " Tap to plan next week.",
                          category: "briefing")
        }
    }

    // MARK: 7. Money (informational)

    func moneyOverview(now: Date = Date()) -> MoneyOverview {
        MoneyInsights.overview(hub.money.data.transactions, categoriser: hub.money.data.categoriser, now: now, calendar: cal)
    }

    private func moneyAlerts(now: Date) {
        guard hub.money.hasAnyData else { return }
        for alert in moneyOverview(now: now).alerts where !state.sentMoneyAlerts.contains(alert.id) {
            state.sentMoneyAlerts.append(alert.id)
            brain?.notify(id: "money|\(alert.id)", title: "Spending note", body: alert.message, category: "money")
        }
        if state.sentMoneyAlerts.count > 300 { state.sentMoneyAlerts.removeFirst(state.sentMoneyAlerts.count - 300) }
        save()
    }

    // MARK: 8. Economics news

    var linker: NewsLinker {
        let modules = context?.all(StoredModule.self).map(\.value) ?? []
        return NewsLinker(moduleConcepts: NewsLinker.defaultModuleConcepts(modules))
    }

    func refreshNews(now: Date = Date()) async {
        guard !refreshingNews else { return }
        refreshingNews = true
        defer { refreshingNews = false }
        var stories: [NewsStory] = []
        await withTaskGroup(of: [NewsStory].self) { group in
            for feed in NewsFeeds.defaults {
                group.addTask {
                    guard let url = URL(string: feed.url), let result = try? await URLSession.shared.data(from: url) else { return [] }
                    return RSSParser.parse(result.0, source: feed.name)
                }
            }
            for await list in group { stories += list }
        }
        stories += newsletterStories(now: now)
        guard !stories.isEmpty else { return }
        state.news = Array(stories.prefix(400))
        state.lastNewsFetch = now
        if state.todaysNewsDay.map({ !cal.isSameDay($0, now) }) ?? true {
            let recent = Set(state.shownNewsIDs.suffix(60))
            state.todaysNews = linker.pick(stories, count: 3, now: now, exclude: recent)
            state.todaysNewsDay = now
            state.shownNewsIDs += state.todaysNews.map(\.id)
        }
        save()
    }

    /// FT / Economist newsletters already in the student's mail (mail cache). No passwords involved.
    private func newsletterStories(now: Date) -> [NewsStory] {
        let cached = brain?.local.load([EmailMessage].self, "mail-cache.json") ?? []
        return cached.filter { NewsFeeds.isNewsletter(from: $0.from) && now.timeIntervalSince($0.date) < 48 * 3600 }
            .flatMap { NewsletterStories.extract(subject: $0.subject, from: $0.from, body: $0.body, date: $0.date) }
    }

    /// Full text using the student's own ft.com / economist.com login cookies (kept in the app's website data store).
    func fullText(for story: LinkedStory) async -> String? {
        guard FeatureSettings.bool(Keys.newsFullText, default: false), let raw = story.story.url, let url = URL(string: raw),
              let result = try? await CookieFetcher.data(url) else { return nil }
        let text = ArticleText.extract(html: String(decoding: result.0, as: UTF8.self))
        return text.isEmpty ? nil : text
    }

    // MARK: 2. Lecture recordings

    func scanRecordings(now: Date) async {
        guard let brain else { return }
        state.lastRecordingScan = now
        guard let snap = brain.local.load(ELEWebSnapshot.self, "ele-web-snapshot.json") else { save(); return }
        var found: [LectureRecording] = []
        var toOpen: [(url: URL, code: String, title: String, week: Int?)] = []
        for (_, content) in snap.contents {
            for section in content.sections {
                for item in section.items {
                    let blob = "<a href=\"\(item.url ?? "")\">\(item.name)</a> " + item.text
                    var hits = RecordingDetector.detect(html: blob, pageTitle: item.name, moduleCode: content.moduleCode)
                    for i in hits.indices { hits[i].week = section.week }
                    found += hits
                    if hits.isEmpty, item.role == .recording, let raw = item.url, let url = URL(string: raw),
                       state.recordings.known.values.first(where: { $0.title == item.name }) == nil {
                        toOpen.append((url, content.moduleCode, item.name, section.week))
                    }
                }
            }
        }
        // Recording items that are ELE wrappers: open the page and look for the embed.
        for page in toOpen.prefix(6) {
            guard let html = try? await brain.accounts.eleWeb.fetchText(page.url) else { continue }
            var hits = RecordingDetector.detect(html: html, pageTitle: page.title, moduleCode: page.code)
            for i in hits.indices { hits[i].week = page.week; hits[i].title = page.title }
            found += hits
        }
        let pending = state.recordings.register(found)
        save()
        if !pending.isEmpty { status = "\(pending.count) lecture recording\(pending.count == 1 ? "" : "s") to process" }
    }

    func processPendingRecordings(limit: Int) async {
        for r in state.recordings.pending.prefix(limit) { await process(r) }
    }

    func process(_ r: LectureRecording) async {
        guard processingRecording == nil, let brain else { return }
        processingRecording = r.id
        defer { processingRecording = nil }
        status = "Getting “\(r.title)”…"
        var transcript = ""
        var source = TranscriptSource.unavailable
        for raw in r.captionURLs + [r.panoptoCaptionURL].compactMap({ $0 }) {
            guard let url = URL(string: raw), let result = try? await CookieFetcher.data(url) else { continue }
            let text = CaptionParser.transcript(String(decoding: result.0, as: UTF8.self))
            if text.count > 200 { transcript = text; source = .captions; break }
        }
        if transcript.isEmpty {
            let choice = TranscriptSource.choose(hasCaptions: false, appleSpeechOnDevice: LocalTranscriber.appleOnDeviceAvailable,
                                                 whisperPath: LocalTranscriber.whisperBinary())
            if choice != .unavailable, let audioRaw = r.panoptoPodcastURL ?? (r.platform == .media ? r.url : nil),
               let audioURL = URL(string: audioRaw) {
                status = "Transcribing “\(r.title)” on this Mac…"
                do {
                    let file = try await CookieFetcher.download(audioURL)
                    defer { try? FileManager.default.removeItem(at: file) }
                    transcript = choice == .appleSpeech ? try await LocalTranscriber.transcribeApple(file)
                                                        : try await LocalTranscriber.transcribeWhisper(file)
                    source = choice
                } catch {
                    OrbitLog.log("companion", "transcription failed for \(r.id): \(error)")
                }
            }
        }
        guard transcript.count > 200 else {
            state.recordings.failed[r.id] = source == .unavailable ? "No captions, and no on-device transcriber" : "Empty transcript"
            status = "Couldn't get a transcript for “\(r.title)”"
            save()
            return
        }
        status = "Summarising “\(r.title)”…"
        let note = RecordingNotesMatcher.best(for: r, notes: brain.local.allNotes(), calendar: cal)
        let digest = await LectureDigester.digest(recording: r, transcript: transcript, source: source,
                                                  notes: note?.allText, router: brain.router)
        state.digests.removeAll { $0.recordingID == r.id }
        state.digests.insert(digest, at: 0)
        state.recordings.processed.insert(r.id)
        save()
        addFlashcards(digest)
        let gapLine = digest.gaps.map { " You might have missed: \($0.missedTerms.prefix(3).joined(separator: ", "))." } ?? ""
        brain.notify(id: "lecture|\(r.id)", title: "Lecture ready: \(r.title)",
                     body: "Summary, \(digest.questions.count) questions and \(digest.flashcards.count) flashcards." + gapLine, category: "uni")
        status = "Processed “\(r.title)”"
    }

    private func addFlashcards(_ d: LectureDigest) {
        guard let context, !d.flashcards.isEmpty else { return }
        for c in d.flashcards {
            let id = StableUUID.make("lecture-card|\(d.recordingID)|\(c.front)")
            guard context.record(StoredFlashcard.self, id: id.uuidString) == nil else { continue }
            context.insert(StoredFlashcard(card: Flashcard(id: id, moduleCode: d.moduleCode, front: c.front, back: c.back)))
        }
        context.saveQuietly()
    }

    func retry(_ id: String) {
        state.recordings.failed[id] = nil
        save()
        if let r = state.recordings.known[id] { Task { await process(r) } }
    }

    // MARK: 10. Chat that remembers

    func assistantTools() -> [AssistantTool] {
        [UniversalSearch.tool(calendar: cal) { await MainActor.run { CompanionHub.shared.searchDocuments() } },
         AssistantTool(name: "grade_predictor", description: "Module marks so far, the mark needed on remaining work for 70 and 80, and the year projection.") { _ in
             await MainActor.run { GradePredictor.summary(CompanionHub.shared.projection) }
         },
         AssistantTool(name: "daily_briefing", description: "Today's briefing: weather, schedule, due items, new on ELE/Ed, key email, news.") { _ in
             await MainActor.run { CompanionHub.shared.state.briefing?.plainText() ?? "No briefing yet today." }
         }]
    }

    func searchDocuments() -> [SearchDocument] {
        guard let context, let brain else { return [] }
        var docs: [SearchDocument] = []
        for t in context.all(StoredTask.self).map(\.value) {
            docs.append(.init(id: "task|\(t.id)", kind: .task, title: t.title, text: t.notes + (t.moduleCode.map { " \($0)" } ?? ""), date: t.deadline))
        }
        let now = Date()
        for e in context.all(StoredEvent.self).map(\.value) where abs(e.start.timeIntervalSince(now)) < 60 * 86400 {
            docs.append(.init(id: "event|\(e.id)", kind: .event, title: e.title, text: [e.location, e.notes].compactMap { $0 }.joined(separator: " "), date: e.start))
        }
        for m in context.all(StoredEmailDigest.self).map(\.value) {
            docs.append(.init(id: "mail|\(m.id)", kind: .mail, title: m.subject, text: "From \(m.from). \(m.summary)", date: m.date))
        }
        for a in brain.academic.activity {
            docs.append(.init(id: "ele|\(a.id)", kind: .ele, title: a.title, text: a.detail + (a.moduleCode.map { " \($0)" } ?? ""), date: a.date, ref: a.url))
        }
        for i in hub.ed.state.items {
            docs.append(.init(id: "ed|\(i.id)", kind: .ed, title: i.title, text: String(i.text.prefix(1500)), date: i.date, ref: i.url))
        }
        for n in brain.local.allNotes() {
            docs.append(.init(id: "note|\(n.id)", kind: .note, title: n.title, text: String(n.allText.prefix(4000)), date: n.created))
        }
        for m in state.gradeBook.modules {
            for i in m.items {
                docs.append(.init(id: "grade|\(i.id)", kind: .grade, title: "\(m.code) \(i.title)",
                                  text: "Weight \(Int(i.weight))%. " + (i.mark.map { "Mark \(Int($0))." } ?? "Not marked yet."), date: i.due))
            }
        }
        for d in state.digests {
            docs.append(.init(id: "lecture|\(d.id)", kind: .lecture, title: d.title, text: d.summary + " " + d.keyPoints.joined(separator: "; "), date: d.createdAt))
        }
        for s in state.news.prefix(150) {
            docs.append(.init(id: "news|\(s.id)", kind: .news, title: s.title, text: s.summary, date: s.published, ref: s.url))
        }
        for p in state.groups.projects {
            docs.append(.init(id: "group|\(p.id)", kind: .group, title: p.name,
                              text: p.tasks.map(\.title).joined(separator: "; ") + " " + p.notes, date: p.deadline))
        }
        // Money only when the AI runs on this Mac (same rule as money_summary).
        if prefs.localOnlyMode {
            for t in hub.money.data.transactions.prefix(500) {
                docs.append(.init(id: "money|\(t.id)", kind: .money, title: t.name, text: MoneyInsights.pounds(-t.amountPence), date: t.date))
            }
        }
        docs += chatArchive().searchDocuments
        return docs
    }

    func chatArchive() -> ChatArchive {
        let messages = (context?.all(StoredChatMessage.self) ?? []).sorted { $0.createdAt < $1.createdAt }
            .filter { $0.role == .user || $0.role == .assistant }
            .map { ChatArchive.Message(id: $0.id, role: $0.role == .user ? .user : .assistant, text: $0.text, date: $0.createdAt) }
        return ChatArchive(messages: messages)
    }

    /// The conversation is already stored (SwiftData, on disk); this keeps a plain JSON copy next to it.
    private func exportChatArchive(now: Date) {
        files.save(chatArchive(), "chat-archive.json")
        state.lastChatExport = now
    }
}

struct CompanionState: Codable {
    var gradeBook = GradeBook()
    var targets: [Double] = GradePredictor.defaultTargets
    var groups = GroupWorkBoard()
    var recordings = RecordingLedger()
    var digests: [LectureDigest] = []
    var briefing: DailyBriefing?
    var lastBriefingDay: Date?
    var recap: WeekRecap?
    var lastRecap: Date?
    var news: [NewsStory] = []
    var todaysNews: [LinkedStory] = []
    var todaysNewsDay: Date?
    var lastNewsFetch: Date?
    var shownNewsIDs: [String] = []
    var lastRecordingScan: Date?
    var sentMoneyAlerts: [String] = []
    var lastChatExport: Date?

    init() {}

    enum CodingKeys: String, CodingKey {
        case gradeBook, targets, groups, recordings, digests, briefing, lastBriefingDay, recap, lastRecap, news, todaysNews,
             todaysNewsDay, lastNewsFetch, shownNewsIDs, lastRecordingScan, sentMoneyAlerts, lastChatExport
    }

    /// Tolerant decoding: a field that fails (or is new) falls back to its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        gradeBook = v(.gradeBook, GradeBook())
        targets = v(.targets, GradePredictor.defaultTargets)
        groups = v(.groups, GroupWorkBoard())
        recordings = v(.recordings, RecordingLedger())
        digests = v(.digests, [])
        briefing = v(.briefing, nil)
        lastBriefingDay = v(.lastBriefingDay, nil)
        recap = v(.recap, nil)
        lastRecap = v(.lastRecap, nil)
        news = v(.news, [])
        todaysNews = v(.todaysNews, [])
        todaysNewsDay = v(.todaysNewsDay, nil)
        lastNewsFetch = v(.lastNewsFetch, nil)
        shownNewsIDs = v(.shownNewsIDs, [])
        lastRecordingScan = v(.lastRecordingScan, nil)
        sentMoneyAlerts = v(.sentMoneyAlerts, [])
        lastChatExport = v(.lastChatExport, nil)
    }
}
