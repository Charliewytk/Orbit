import AppKit
import Foundation
import Observation
import SwiftData
import UserNotifications
import OrbitCore

/// Proactive nudges: every 5 minutes asks `NudgeEngine` what's worth saying, posts the top
/// one as a macOS notification with Start focus / Snooze 30m / Not now, and keeps the
/// current top nudge for the glass banner on Home. Actions come back through
/// `MacAppDelegate` → `handle(action:nudgeID:)`.
@MainActor
@Observable
final class NudgeService {
    @ObservationIgnored weak var hub: FeatureHub?
    /// Shown as the banner on Home (nil = nothing worth saying).
    private(set) var banner: Nudge?
    @ObservationIgnored private var lastRun: Date?
    /// Nudges posted recently, so an action can find what it was about.
    @ObservationIgnored private var recent: [String: Nudge] = [:]

    nonisolated static let category = "orbit.nudge"
    nonisolated static let shutdownCategory = "orbit.shutdown"
    nonisolated static let nudgeIDKey = "nudgeID"

    private var routine: RoutineService? { hub?.routine }
    var settings: NudgeSettings {
        get { routine?.state.nudgeSettings ?? NudgeSettings() }
        set { routine?.update { $0.nudgeSettings = newValue } }
    }

    // MARK: Setup

    /// Registers the notification actions (call once at launch).
    static func registerCategories() {
        let start = UNNotificationAction(identifier: NudgeAction.startFocus.rawValue, title: "Start focus", options: [.foreground])
        let snooze = UNNotificationAction(identifier: NudgeAction.snooze30.rawValue, title: "Snooze 30m", options: [])
        let notNow = UNNotificationAction(identifier: NudgeAction.notNow.rawValue, title: "Not now", options: [.destructive])
        let nudge = UNNotificationCategory(identifier: category, actions: [start, snooze, notNow], intentIdentifiers: [], options: [])
        let begin = UNNotificationAction(identifier: "shutdown.begin", title: "Start shutdown", options: [.foreground])
        let later = UNNotificationAction(identifier: NudgeAction.snooze30.rawValue, title: "In 10 minutes", options: [])
        let shutdown = UNNotificationCategory(identifier: shutdownCategory, actions: [begin, later], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([nudge, shutdown])
    }

    // MARK: Evaluate

    func tick(now: Date) async {
        // Every 5 minutes, plus exactly on time for the shutdown (21:58) and reading.
        var onTheDot = false
        if let r = routine?.settings, let cal = routine?.cal {
            let m = cal.minuteOfDay(now)
            onTheDot = (r.shutdownEnabled && m == r.shutdownTime) || (r.readingEnabled && m == r.readingStart - 1)
        }
        guard onTheDot || now.timeIntervalSince(lastRun ?? .distantPast) >= 5 * 60 - 5 else { return }
        await evaluate(now: now)
    }

    func input(now: Date) -> NudgeInput? {
        guard let hub, let context = hub.context, let routine else { return nil }
        let cal = routine.cal
        let dayStart = cal.startOfDay(now), dayEnd = cal.endOfDay(now)
        let storedEvents = context.all(StoredEvent.self).filter { $0.end > dayStart.addingTimeInterval(-86400) && $0.start < dayEnd.addingTimeInterval(86400) }
        let tasks = context.all(StoredTask.self)
        let blocks = context.all(StoredBlock.self)
        let taskByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let nudgeBlocks = blocks.filter { !$0.skipped && $0.end > dayStart && $0.start < dayEnd }.map { b in
            NudgeBlock(id: b.uuid, taskID: StoreCoding.uuid(b.taskID), title: b.title, start: b.start, end: b.end,
                       completed: b.completed, isTypeUp: taskByID[b.taskID]?.sourceRef?.hasPrefix(RoutineService.typeUpRefPrefix) ?? false,
                       locationHint: b.locationHint)
        }
        let momentum = hub.stats.momentum(tasks: tasks, blocks: blocks)
        let cardsDue = context.all(StoredFlashcard.self).filter { $0.due <= now }.count
        let planner = RoutinePlanner(prefs: routine.prefs)
        let events = storedEvents.map(\.value)
        return NudgeInput(now: now, events: events, blocks: nudgeBlocks,
                          tasks: tasks.filter { $0.completedAt == nil }.map(\.value),
                          routine: planner.blocks(from: dayStart, to: dayEnd, events: events),
                          routineDone: routine.state.routineDone, flashcardsDue: cardsDue,
                          streak: momentum.streak(now: now), todayCounts: momentum.todayCounts(now: now),
                          focusActive: hub.focus.isActive, shutdownDoneToday: routine.shutdownDoneToday,
                          log: routine.state.nudgeLog)
    }

    func evaluate(now: Date = Date()) async {
        lastRun = now
        guard let routine, let input = input(now: now) else { return }
        let engine = NudgeEngine(settings: settings, calendar: routine.cal)
        let ready = engine.evaluate(input)
        if let top = ready.first {
            await post(top, now: now)
        }
        // The banner: the best thing worth saying now, even if it was already sent.
        let dismissed = Set(routine.state.nudgeLog.filter { $0.action == .notNow }.map(\.key))
        banner = engine.candidates(input)
            .filter { settings.isOn($0.kind) && !dismissed.contains($0.id) && $0.kind != .reading }
            .sorted { $0.priority > $1.priority }
            .first
    }

    private func post(_ n: Nudge, now: Date) async {
        recent[n.id] = n
        routine?.update { s in
            s.nudgeLog.append(NudgeLogEntry(key: n.id, kind: n.kind, firedAt: now))
            s.nudgeLog = s.nudgeLog.filter { now.timeIntervalSince($0.firedAt) < 8 * 86400 }
        }
        let category = n.kind == .shutdown ? Self.shutdownCategory : Self.category
        await Notifier.post(id: "nudge-\(n.id)-\(Int(now.timeIntervalSince1970))", title: n.title, body: n.body,
                            category: category, categoryIdentifier: category, userInfo: [Self.nudgeIDKey: n.id])
        OrbitLog.log("nudges", "sent \(n.kind.rawValue): \(n.title)")
    }

    // MARK: Actions

    /// A notification action (or a banner button).
    func handle(action: String, nudgeID: String?) {
        guard let hub, let routine else { return }
        let now = Date()
        let nudge = nudgeID.flatMap { recent[$0] } ?? (nudgeID == banner?.id ? banner : nil) ?? nudgeID.flatMap(Self.rebuild)
        if nudgeID?.hasPrefix("shutdown:") == true || action == "shutdown.begin" {
            if action == NudgeAction.snooze30.rawValue {
                snooze(nudgeID ?? "", kind: .shutdown, minutes: 10)
            } else {
                routine.openShutdown()
            }
            return
        }
        switch action {
        case NudgeAction.startFocus.rawValue, UNNotificationDefaultActionIdentifier:
            NSApp.activate(ignoringOtherApps: true)
            guard action == NudgeAction.startFocus.rawValue || nudge?.focusMinutes != nil else { return }
            startFocus(for: nudge)
            record(nudgeID, action: .startFocus)
        case NudgeAction.snooze30.rawValue:
            snooze(nudgeID ?? "", kind: nudge?.kind ?? .freeGap, minutes: 30)
            // A planned block that's being snoozed moves 30 minutes later.
            if let blockID = nudge?.blockID, let block = hub.context?.record(StoredBlock.self, id: blockID.uuidString), block.start > now {
                block.start = block.start.addingTimeInterval(30 * 60)
                block.end = block.end.addingTimeInterval(30 * 60)
                block.locked = true
                hub.context?.saveQuietly()
                Task { await self.pushBlockChange(block) }
                hub.toast("Moved “\(block.title)” to \(routine.cal.time(block.start))")
            }
        case NudgeAction.notNow.rawValue, UNNotificationDismissActionIdentifier:
            record(nudgeID, action: .notNow)
            if nudgeID == banner?.id { banner = nil }
        default:
            break
        }
    }

    private func startFocus(for nudge: Nudge?) {
        guard let hub else { return }
        let task = nudge?.taskID.flatMap { hub.context?.record(StoredTask.self, id: $0.uuidString) }
        let block = nudge?.blockID.flatMap { hub.context?.record(StoredBlock.self, id: $0.uuidString) }
        hub.focus.start(task: task, block: block, title: nudge?.focusTitle, minutes: nudge?.focusMinutes)
        NotificationCenter.default.post(name: .orbitNavigate, object: Destination.focus)
        if nudge?.kind == .flashcardsDue { NotificationCenter.default.post(name: .orbitNavigate, object: Destination.review) }
    }

    private func snooze(_ id: String, kind: NudgeKind, minutes: Int) {
        let now = Date()
        routine?.update { s in
            s.nudgeLog.append(NudgeLogEntry(key: id, kind: kind, firedAt: now, snoozedUntil: now.addingTimeInterval(Double(minutes) * 60),
                                            action: .snooze30))
        }
        if id == banner?.id { banner = nil }
    }

    private func record(_ id: String?, action: NudgeAction) {
        guard let id else { return }
        routine?.update { s in
            if let i = s.nudgeLog.lastIndex(where: { $0.key == id }) {
                s.nudgeLog[i].action = action
                s.nudgeLog[i].snoozedUntil = nil
            } else {
                s.nudgeLog.append(NudgeLogEntry(key: id, kind: self.banner?.kind ?? .freeGap, firedAt: Date(), action: action))
            }
        }
    }

    /// Mirrors a moved block to Google (locked blocks aren't re-sent by the replanner).
    private func pushBlockChange(_ block: StoredBlock) async {
        guard let brain = hub?.brain, let google = brain.googleCalendarClient(), block.externalEventID != nil else { return }
        do {
            let updated = try await google.updateEvent(for: block.value)
            block.externalEventID = updated.externalEventID
            hub?.context?.saveQuietly()
        } catch {
            OrbitLog.log("nudges", "couldn't move the block on Google: \(error)")
        }
    }

    /// After a relaunch the posted nudge is gone from memory: its key still names the task or block.
    static func rebuild(_ key: String) -> Nudge? {
        let parts = key.split(separator: ":").map(String.init)
        guard parts.count >= 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "gap": return Nudge(id: key, kind: .freeGap, title: "", body: "", priority: 0, taskID: id, focusMinutes: 45)
        case "deadline": return Nudge(id: key, kind: .deadlineNoProgress, title: "", body: "", priority: 0, taskID: id, focusMinutes: 25)
        case "block": return Nudge(id: key, kind: .blockStarting, title: "", body: "", priority: 0, blockID: id)
        case "typeup": return Nudge(id: key, kind: .typeUp, title: "", body: "", priority: 0, blockID: id)
        default: return nil
        }
    }

    /// Banner buttons.
    func startFromBanner() { if let b = banner { handle(action: NudgeAction.startFocus.rawValue, nudgeID: b.id); banner = nil } }
    func snoozeBanner() { if let b = banner { handle(action: NudgeAction.snooze30.rawValue, nudgeID: b.id) } }
    func dismissBanner() { if let b = banner { handle(action: NudgeAction.notNow.rawValue, nudgeID: b.id) } }
}
