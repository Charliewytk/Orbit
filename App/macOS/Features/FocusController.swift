import Foundation
import Observation
import SwiftData
import OrbitCore

/// Focus sessions: a timer on a to-do or planned block, Do Not Disturb on while it
/// runs (via two Shortcuts the student creates), and the minutes logged to the task.
@MainActor
@Observable
final class FocusController {
    @ObservationIgnored weak var hub: FeatureHub?

    private(set) var session: FocusSession?
    private(set) var dndActive = false
    var lastMessage: String?
    @ObservationIgnored private var notifiedOvertime = false

    var isActive: Bool { session != nil }

    func restore(_ saved: FocusSession?) {
        // A session left running when the Mac shut down: keep it paused so no time is invented.
        guard var s = saved, !s.isFinished else { return }
        if s.isRunning { s.pause(at: Date()) }
        session = s
    }

    // MARK: Start / pause / finish

    /// Starts on a task (and optionally one of its planned blocks). Ends any running session first.
    func start(task: StoredTask?, block: StoredBlock? = nil, title: String? = nil, minutes: Int? = nil) {
        if session != nil { finish(markTaskDone: false) }
        let now = Date()
        let planned = minutes ?? block.map { max(5, Int($0.end.timeIntervalSince($0.start) / 60)) }
            ?? task.map { min(90, max(15, $0.remainingMinutes)) }
        let name = title ?? task?.title ?? block?.title ?? "Focus"
        let kind = TaskKind.classify(title: name, notes: task?.notes ?? "")
        session = FocusSession(taskID: task.map { StoreCoding.uuid($0.id) } ?? block.map { StoreCoding.uuid($0.taskID) },
                               blockID: block.map { StoreCoding.uuid($0.id) }, title: name,
                               moduleCode: task?.moduleCode ?? block?.moduleCode, kind: kind, plannedMinutes: planned, startedAt: now)
        if let block {
            block.startedAt = now
            block.locked = true
            hub?.context?.saveQuietly()
        }
        notifiedOvertime = false
        persist()
        setDoNotDisturb(true)
        OrbitLog.log("focus", "started “\(name)” (\(planned.map { "\($0) min" } ?? "open"))")
    }

    func pause() {
        session?.pause(at: Date())
        persist()
        setDoNotDisturb(false)
    }

    func resume() {
        session?.resume(at: Date())
        persist()
        setDoNotDisturb(true)
    }

    /// Ends the session, logs the minutes to the task (and its block), and optionally ticks the task off.
    func finish(markTaskDone: Bool) {
        guard var s = session, let hub else { session = nil; return }
        let now = Date()
        let entry = s.finish(at: now)
        session = nil
        setDoNotDisturb(false)
        hub.state.activeFocus = nil
        guard let entry else {
            lastMessage = "Session under a minute; nothing logged."
            hub.save()
            return
        }
        hub.state.focusLog.append(entry)
        if hub.state.focusLog.count > 3000 { hub.state.focusLog.removeFirst(hub.state.focusLog.count - 3000) }
        if let context = hub.context {
            if let taskID = entry.taskID, let task = context.record(StoredTask.self, id: taskID.uuidString) {
                task.minutesDone += entry.minutes
                if markTaskDone || task.minutesDone >= task.estimateMinutes { task.completedAt = task.completedAt ?? now }
                task.updatedAt = now
            }
            if let blockID = entry.blockID, let block = context.record(StoredBlock.self, id: blockID.uuidString),
               entry.minutes * 2 >= block.minutes {
                block.completed = true
                block.locked = true
            }
            context.saveQuietly()
        }
        hub.save()
        hub.learnFromCompletedTasks()
        hub.tasksChanged()
        lastMessage = "Logged \(Fmt.duration(entry.minutes)) on “\(entry.title)”."
        hub.toast(lastMessage!)
        OrbitLog.log("focus", "finished “\(entry.title)”: \(entry.minutes) min")
    }

    func cancel() {
        session = nil
        hub?.state.activeFocus = nil
        hub?.save()
        setDoNotDisturb(false)
    }

    /// Every minute: tells the student when the planned time is up (once).
    func tick(now: Date) {
        guard let s = session, s.isRunning, let remaining = s.remaining(at: now), remaining <= 0, !notifiedOvertime else { return }
        notifiedOvertime = true
        hub?.notify(id: "focus-done-\(s.id.uuidString)", title: "Focus block done",
                    body: "\(s.plannedMinutes ?? 0) minutes on “\(s.title)”. Finish, or keep going.", category: "schedule", onMac: true)
    }

    func appWillTerminate() {
        persist()
        if dndActive { FocusShortcuts.runSync(on: false) }
    }

    private func persist() {
        hub?.state.activeFocus = session
        hub?.save()
    }

    // MARK: Do Not Disturb

    private func setDoNotDisturb(_ on: Bool) {
        guard FeatureSettings.bool(FeatureSettings.focusUseShortcuts, default: true) else { return }
        guard on != dndActive else { return }
        dndActive = on
        Task {
            let result = await FocusShortcuts.run(on: on)
            if case .failure(let message) = result {
                OrbitLog.log("focus", message)
                if on { self.dndActive = false }
            }
        }
    }

    // MARK: Menu bar

    /// "24:13 · Essay draft" for the menu bar title.
    func menuBarTitle(now: Date = Date()) -> String? {
        guard let s = session else { return nil }
        return s.clock(at: now) + (s.isPaused ? " (paused)" : "")
    }
}

/// Runs the "Orbit Focus On" / "Orbit Focus Off" shortcuts with `/usr/bin/shortcuts`.
/// macOS has no public API to switch Focus on, so the student makes two tiny shortcuts
/// (Shortcuts app → New → "Set Focus" → Do Not Disturb On/Off) with these exact names.
enum FocusShortcuts {
    static let onName = "Orbit Focus On"
    static let offName = "Orbit Focus Off"
    static let tool = "/usr/bin/shortcuts"

    enum Result { case ok, failure(String) }

    /// Names of the student's shortcuts (nil if the tool isn't there).
    static func installed() async -> Set<String>? {
        await Task.detached(priority: .utility) { () -> Set<String>? in
            guard let out = run([ "list" ]) , out.status == 0 else { return nil }
            return Set(out.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        }.value
    }

    static func run(on: Bool) async -> Result {
        let name = on ? onName : offName
        return await Task.detached(priority: .userInitiated) { () -> Result in
            guard FileManager.default.isExecutableFile(atPath: tool) else { return .failure("Shortcuts tool not found") }
            guard let list = run(["list"]), list.status == 0 else { return .failure("Couldn't list shortcuts") }
            let names = Set(list.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
            guard names.contains(name) else { return .failure("Shortcut “\(name)” isn't set up; Focus stays as it is.") }
            guard let r = run(["run", name]), r.status == 0 else { return .failure("Shortcut “\(name)” failed") }
            return .ok
        }.value
    }

    /// Blocking version for app termination.
    static func runSync(on: Bool) {
        _ = run(["run", on ? onName : offName])
    }

    /// Runs the tool with a 15-second timeout.
    static func run(_ args: [String]) -> (status: Int32, output: String)? {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(15)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

extension FeatureHub {
    /// Tasks finished since last time that have focus minutes teach the duration learner.
    func learnFromCompletedTasks() {
        guard let context else { return }
        var logged: [UUID: Int] = [:]
        for e in state.focusLog { if let id = e.taskID { logged[id, default: 0] += e.minutes } }
        guard !logged.isEmpty else { return }
        var changed = false
        for (taskID, minutes) in logged where !state.learnedTaskIDs.contains(taskID.uuidString) {
            guard let task = context.record(StoredTask.self, id: taskID.uuidString), task.completedAt != nil else { continue }
            // Only tasks mostly done in focus sessions give a fair sample.
            if minutes * 10 >= task.estimateMinutes * 6 || minutes >= task.minutesDone * 8 / 10 {
                let kind = TaskKind.classify(title: task.title, notes: task.notes)
                state.learner.record(kind: kind, estimateMinutes: task.estimateMinutes, actualMinutes: minutes,
                                     appliedMultiplier: state.appliedMultipliers[task.id] ?? 1)
                OrbitLog.log("focus", "learned \(kind.rawValue): estimate \(task.estimateMinutes), actual \(minutes)")
            }
            state.learnedTaskIDs.insert(taskID.uuidString)
            changed = true
        }
        if changed { save() }
    }

    /// Scales a new task's estimate by what's been learned for its kind, and remembers
    /// the multiplier so learning compares against the raw estimate.
    func applyLearnedEstimate(_ task: OrbitTask) -> OrbitTask {
        let (adjusted, m) = state.learner.adjusted(task)
        if m != 1 { state.appliedMultipliers[task.id.uuidString] = m }
        return adjusted
    }

    /// For the assistant's start_focus tool.
    func startFocus(query: String, minutes: Int?) -> String {
        guard let context else { return "Not available." }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let now = Date()
        let blocks = context.all(StoredBlock.self).filter { !$0.completed && !$0.skipped && $0.end > now }
            .sorted { $0.start < $1.start }
        let open = context.all(StoredTask.self).filter { $0.completedAt == nil }
        var task: StoredTask?
        var block: StoredBlock?
        if q.isEmpty {
            block = blocks.first { $0.start <= now.addingTimeInterval(15 * 60) }
            task = block.flatMap { b in open.first { $0.id == b.taskID } }
        } else {
            task = open.first { $0.title.lowercased() == q } ?? open.first { $0.title.lowercased().contains(q) }
            if let t = task { block = blocks.first { $0.taskID == t.id && $0.start <= now.addingTimeInterval(30 * 60) } }
        }
        guard task != nil || block != nil else {
            return q.isEmpty ? "Nothing is planned right now. Which task should I start?" : "No open task matching “\(query)”."
        }
        focus.start(task: task, block: block, minutes: minutes)
        let s = focus.session
        return "Started a \(s?.plannedMinutes.map { "\($0)-minute " } ?? "")focus session on “\(s?.title ?? "")”."
            + (FeatureSettings.bool(FeatureSettings.focusUseShortcuts, default: true) ? " Do Not Disturb is on if the Orbit Focus shortcuts are set up." : "")
    }
}
