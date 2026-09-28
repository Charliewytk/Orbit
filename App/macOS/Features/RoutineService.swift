import AppKit
import Foundation
import Observation
import SwiftData
import OrbitCore

/// The fixed personal routine on the Mac: today's hall meals, reading, shutdown and
/// sleep; type-up blocks after every lecture/tutorial; the evening shutdown ritual and
/// its history; exam-mode switches. Nudges live in `NudgeService`, backups in `BackupService`.
///
/// Owned by `FeatureHub` (`FeatureHub.shared.routine`), ticked every minute.
@MainActor
@Observable
final class RoutineService {
    @ObservationIgnored weak var hub: FeatureHub?
    private(set) var state = RoutineState()
    /// Presents the full-screen shutdown sheet.
    var showShutdown = false
    private(set) var lastTypeUpRun: Date?

    private let fileName = "routine-state.json"
    /// Marks events Orbit wrote to Google for routine blocks (opt-in), so sync ignores them.
    static let googleTag = "[orbit-routine]"
    /// Task `sourceRef` prefix for type-up to-dos ("orbit-" makes them Orbit recommends).
    static let typeUpRefPrefix = "orbit-typeup:"

    // MARK: Persistence

    func load() {
        if let saved = hub?.files.load(RoutineState.self, fileName) { state = saved }
    }

    func save() { hub?.files.save(state, fileName) }

    func update(_ change: (inout RoutineState) -> Void) {
        change(&state)
        save()
    }

    // MARK: Accessors

    var prefs: UserPrefs { hub?.prefs ?? UserPrefs() }
    var settings: RoutineSettings { prefs.effectiveRoutine }
    var cal: DayCalendar { DayCalendar(timeZone: prefs.timeZone) }
    var context: ModelContext? { hub?.context }

    func events(around now: Date) -> [CalendarEvent] {
        let from = now.addingTimeInterval(-4 * 86400), to = now.addingTimeInterval(4 * 86400)
        return (context?.all(StoredEvent.self) ?? []).filter { $0.end > from && $0.start < to }.map(\.value)
    }

    /// Today's routine blocks (meals placed around today's classes).
    func blocks(on day: Date) -> [RoutineBlock] {
        RoutinePlanner(prefs: prefs).blocks(on: day, events: events(around: day))
    }

    func isDone(_ block: RoutineBlock) -> Bool { state.routineDone.contains(block.id) }

    /// Ticks a meal (or reading) as done, e.g. "ate dinner".
    func toggleDone(_ block: RoutineBlock) {
        update { s in
            if s.routineDone.contains(block.id) { s.routineDone.remove(block.id) } else { s.routineDone.insert(block.id) }
            // Keep a fortnight of ticks.
            let cutoff = cal.format(Date().addingTimeInterval(-14 * 86400), "yyyy-MM-dd")
            s.routineDone = s.routineDone.filter { ($0.split(separator: "@").last.map(String.init) ?? "") >= cutoff }
        }
    }

    /// Day keys with a completed shutdown (they count towards the streak).
    var shutdownDays: Set<String> { Set(state.shutdownHistory.map(\.id)) }

    var shutdownDoneToday: Bool { shutdownDays.contains(cal.format(Date(), "yyyy-MM-dd")) }

    // MARK: Tick

    func tick(now: Date) async {
        guard settings.enabled else { return }
        if now.timeIntervalSince(lastTypeUpRun ?? .distantPast) >= 5 * 60 {
            lastTypeUpRun = now
            planTypeUps(now: now)
            refreshTypeUps(now: now)
        }
        await pushRoutineToGoogleIfWanted(now: now)
    }

    // MARK: Type-up blocks

    /// Timetabled sessions from the last few days and today (module + kind from the title).
    func recentSessions(now: Date) -> [TypeUpSession] {
        guard let brain = hub?.brain else { return [] }
        let academic = brain.academic
        let events = events(around: now).filter { $0.start > now.addingTimeInterval(-Double(settings.typeUpExpiryDays) * 86400) }
        let tracker = LectureTracker(calendar: academic.calendar, modules: academic.modules, events: events, notes: [], now: now)
        return tracker.sessions(since: now.addingTimeInterval(-Double(settings.typeUpExpiryDays) * 86400),
                                kinds: TypeUpPlanner.kinds)
            .filter { cal.isSameDay($0.start, now) || $0.end <= now }
            .map(TypeUpSession.init)
    }

    /// Plans a "Type up <Module> <Lecture> notes" block after each session that doesn't have one:
    /// a to-do (Orbit recommends, linked to module and week) plus a locked block on the plan.
    func planTypeUps(now: Date) {
        guard settings.typeUpEnabled, let context else { return }
        let sessions = recentSessions(now: now)
        let known = Set(state.typeUps.keys)
        guard sessions.contains(where: { !known.contains($0.id) }) else { return }
        let blocks = context.all(StoredBlock.self).filter { !$0.skipped && $0.end > now }
        let busy = blocks.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
        let planner = TypeUpPlanner(prefs: prefs)
        let planned = planner.plan(sessions: sessions, alreadyPlanned: known, events: events(around: now), busy: busy, now: now)
        guard !planned.isEmpty else { return }
        for b in planned {
            guard let session = sessions.first(where: { $0.id == b.sessionID }) else { continue }
            let weekText = b.week.map { "Week \($0)" } ?? "this week"
            let task = OrbitTask(id: b.taskID, title: b.title,
                                 notes: "Type up your \(session.kindLabel.lowercased()) notes for \(b.moduleCode) (\(weekText)) while it's fresh. Orbit ticks this off when a typed note for \(b.moduleCode) \(weekText) appears in the Library.",
                                 estimateMinutes: settings.typeUpMinutes,
                                 deadline: b.end.addingTimeInterval(Double(settings.typeUpExpiryDays) * 86400),
                                 earliestStart: b.start, priority: .normal, energy: .medium, moduleCode: b.moduleCode,
                                 source: .assistant, sourceRef: Self.typeUpRefPrefix + b.sessionID,
                                 minBlockMinutes: settings.typeUpMinutes, maxBlockMinutes: settings.typeUpMinutes)
            if context.record(StoredTask.self, id: task.id.uuidString) == nil { context.insert(StoredTask(task: task)) }
            if context.record(StoredBlock.self, id: b.blockID.uuidString) == nil {
                let block = ScheduledBlock(id: b.blockID, taskID: b.taskID, title: b.title, start: b.start, end: b.end,
                                           moduleCode: b.moduleCode, locked: true, locationHint: b.locationHint)
                context.insert(StoredBlock(block: block))
            }
            state.typeUps[b.sessionID] = TypeUpRecord(sessionID: b.sessionID, moduleCode: b.moduleCode, week: b.week,
                                                      sessionStart: session.start, blockStart: b.start, blockEnd: b.end,
                                                      locationHint: b.locationHint, status: .pending)
            OrbitLog.log("routine", "type-up planned: \(b.title) \(cal.shortDay(b.start)) \(cal.time(b.start)) @ \(b.locationHint)")
        }
        context.saveQuietly()
        save()
        hub?.tasksChanged()
    }

    /// Ticks type-ups off when a typed note appears; removes ones not done after the expiry.
    func refreshTypeUps(now: Date) {
        guard let context, !state.typeUps.isEmpty else { return }
        let typed = context.all(StoredNote.self).filter(\.hasTyped)
            .map { TypedNoteRef(moduleCode: $0.moduleCode, week: $0.week, modified: $0.modified) }
        let planner = TypeUpPlanner(prefs: prefs)
        var changed = false
        for (id, rec) in state.typeUps where rec.status == .pending {
            let taskID = TypeUpPlanner.taskID(sessionID: id).uuidString
            let task = context.record(StoredTask.self, id: taskID)
            // Ticked off by hand: done.
            if let task, task.completedAt != nil {
                state.typeUps[id]?.status = .done
                changed = true
                continue
            }
            let block = TypeUpBlock(sessionID: id, moduleCode: rec.moduleCode, week: rec.week, title: "", start: rec.blockStart,
                                    end: rec.blockEnd, locationHint: rec.locationHint, onCampus: false)
            switch planner.status(of: block, sessionStart: rec.sessionStart, typedNotes: typed, now: now) {
            case .pending:
                // Deleted by the student: treat as dropped.
                if task == nil { state.typeUps[id]?.status = .expired; changed = true }
            case .done:
                state.typeUps[id]?.status = .done
                if let task {
                    task.completedAt = now
                    task.minutesDone = task.estimateMinutes
                    task.updatedAt = now
                }
                for b in context.all(StoredBlock.self) where b.taskID == taskID && !b.completed {
                    if b.start <= now { b.completed = true } else { context.delete(b) }
                }
                OrbitLog.log("routine", "type-up done (typed note found): \(rec.moduleCode) week \(rec.week.map(String.init) ?? "?")")
                changed = true
            case .expired:
                state.typeUps[id]?.status = .expired
                for b in context.all(StoredBlock.self) where b.taskID == taskID && !b.completed {
                    if b.start > now { context.delete(b) } else { b.skipped = true; b.locked = false }
                }
                if let task { context.delete(task) }
                OrbitLog.log("routine", "type-up removed after \(settings.typeUpExpiryDays) days: \(rec.moduleCode)")
                changed = true
            }
        }
        // Forget records older than a month.
        let old = now.addingTimeInterval(-30 * 86400)
        state.typeUps = state.typeUps.filter { $0.value.sessionStart > old }
        if changed {
            context.saveQuietly()
            save()
            hub?.tasksChanged()
        }
    }

    // MARK: Shutdown ritual

    func openShutdown() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.identifier?.rawValue.contains("main") == true || w.title == "Orbit" {
            w.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(name: .orbitNavigate, object: Destination.home)
        showShutdown = true
    }

    /// Today's review for the sheet.
    func shutdownReview(now: Date) -> (done: [StoredTask], notDone: [StoredTask]) {
        guard let context else { return ([], []) }
        let stored = context.all(StoredTask.self)
        let byID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let r = ShutdownPlanner(prefs: prefs).review(tasks: stored.map(\.value), blocks: context.all(StoredBlock.self).filter { !$0.skipped }.map(\.value), on: now)
        return (r.done.compactMap { byID[$0.id.uuidString] }, r.notDone.compactMap { byID[$0.id.uuidString] })
    }

    /// Applies the roll-over choices, records the shutdown (it extends the streak) and replans.
    func completeShutdown(choices: [String: RolloverChoice], journal: String, now: Date = Date()) {
        guard let context, let app = hub?.brain?.app else { return }
        let planner = ShutdownPlanner(prefs: prefs)
        let review = shutdownReview(now: now)
        var rolled = 0, dropped = 0
        for task in review.notDone where task.completedAt == nil {
            let choice = choices[task.id] ?? .tomorrow
            switch planner.apply(choice, to: task.value, now: now) {
            case .moved(let t, let warning):
                task.earliestStart = t.earliestStart
                task.deadline = t.deadline
                task.updatedAt = now
                rolled += 1
                if let warning { hub?.toast(warning) }
            case .dropped:
                app.delete(task)
                dropped += 1
            }
        }
        context.saveQuietly()
        let doneCount = shutdownReview(now: now).done.count
        let streakBefore = hub?.stats.momentum(tasks: context.all(StoredTask.self), blocks: context.all(StoredBlock.self)).streak(now: now) ?? 0
        let todayAlready = hub?.stats.momentum(tasks: context.all(StoredTask.self), blocks: context.all(StoredBlock.self)).todayCounts(now: now) ?? false
        let rec = ShutdownRecord(id: planner.dayKey(now), completedAt: now, doneCount: doneCount, rolledOver: rolled, dropped: dropped,
                                 journal: journal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : journal,
                                 streakAfter: streakBefore + (todayAlready ? 0 : 1))
        update { $0.shutdownHistory = planner.record(rec, into: $0.shutdownHistory) }
        OrbitLog.log("routine", "shutdown done: \(doneCount) done, \(rolled) rolled over, \(dropped) dropped")
        hub?.tasksChanged()
    }

    // MARK: Google (opt-in)

    /// When the student opts in, writes tomorrow's meals and reading to the Orbit Google calendar once a day.
    private func pushRoutineToGoogleIfWanted(now: Date) async {
        guard settings.pushRoutineToGoogle, let brain = hub?.brain, let google = brain.googleCalendarClient(),
              let session = brain.accounts.google else { return }
        let tomorrow = cal.addingDays(1, to: cal.startOfDay(now))
        let key = cal.format(tomorrow, "yyyy-MM-dd")
        guard state.pushedRoutineDays.contains(key) == false, cal.minuteOfDay(now) >= 12 * 60 else { return }
        do {
            let calendarID = try await google.findOrCreateOrbitCalendar()
            for r in blocks(on: tomorrow) where r.kind.isMeal || r.kind == .reading {
                let event = CalendarEvent(title: r.title, start: r.start, end: r.end, location: r.location,
                                          notes: "\(Self.googleTag) Routine block from Orbit.", calendarID: calendarID, isBusy: false)
                _ = try await GoogleEventWriter(tokens: session).insert(event, calendarID: calendarID, timeZone: prefs.timeZone)
            }
            update { s in
                s.pushedRoutineDays.insert(key)
                s.pushedRoutineDays = Set(s.pushedRoutineDays.sorted().suffix(30))
            }
        } catch {
            OrbitLog.log("routine", "couldn't write routine to Google: \(error)")
        }
    }

    // MARK: Exam mode

    func examMode() -> ExamMode {
        ExamMode(withinDays: state.examWithinDays, manual: state.examManual, calendar: cal)
    }

    func toggleExamMode(assessments: [Assessment]) {
        let active = examMode().isActive(assessments: assessments, now: Date())
        update { $0.examManual = active ? .off : .on }
        hub?.toast(active ? "Exam mode off" : "Exam mode on")
    }
}

// MARK: - State

struct TypeUpRecord: Codable, Hashable {
    var sessionID: String
    var moduleCode: String
    var week: Int?
    var sessionStart: Date
    var blockStart: Date
    var blockEnd: Date
    var locationHint: String
    var status: TypeUpPlanner.Status
}

/// Application Support/Orbit/Features/routine-state.json. Every field decodes leniently.
struct RoutineState: Codable {
    var routineDone: Set<String> = []
    var typeUps: [String: TypeUpRecord] = [:]
    var shutdownHistory: [ShutdownRecord] = []
    var nudgeSettings = NudgeSettings()
    var nudgeLog: [NudgeLogEntry] = []
    var pushedRoutineDays: Set<String> = []
    // Exam mode
    var examManual: ExamMode.Manual = .auto
    var examWithinDays = 28
    var shakyTopics: Set<String> = []
    /// Past paper id → when it was sat.
    var papersDone: [String: Date] = [:]
    var revisionPlannedExams: Set<String> = []
    // Backups
    var lastBackup: Date?
    var lastBackupFile: String?
    var lastBackupError: String?
    var lastBackupAttempt: Date?
    var backupFolder: String?
    var backupIncludeTypedNotes = true
    var backupIncludeKnowledge = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case routineDone, typeUps, shutdownHistory, nudgeSettings, nudgeLog, pushedRoutineDays, examManual, examWithinDays,
             shakyTopics, papersDone, revisionPlannedExams, lastBackup, lastBackupFile, lastBackupError, lastBackupAttempt, backupFolder,
             backupIncludeTypedNotes, backupIncludeKnowledge
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: key)) ?? fallback }
        routineDone = v(.routineDone, [])
        typeUps = v(.typeUps, [:])
        shutdownHistory = v(.shutdownHistory, [])
        nudgeSettings = v(.nudgeSettings, NudgeSettings())
        nudgeLog = v(.nudgeLog, [])
        pushedRoutineDays = v(.pushedRoutineDays, [])
        examManual = v(.examManual, .auto)
        examWithinDays = v(.examWithinDays, 28)
        shakyTopics = v(.shakyTopics, [])
        papersDone = v(.papersDone, [:])
        revisionPlannedExams = v(.revisionPlannedExams, [])
        lastBackup = v(.lastBackup, nil as Date?)
        lastBackupFile = v(.lastBackupFile, nil as String?)
        lastBackupError = v(.lastBackupError, nil as String?)
        lastBackupAttempt = v(.lastBackupAttempt, nil as Date?)
        backupFolder = v(.backupFolder, nil as String?)
        backupIncludeTypedNotes = v(.backupIncludeTypedNotes, true)
        backupIncludeKnowledge = v(.backupIncludeKnowledge, false)
    }
}

