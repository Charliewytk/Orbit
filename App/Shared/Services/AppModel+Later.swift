import Foundation
import SwiftData
import OrbitCore

/// "Move to later" for scheduled blocks and tasks, with Orbit's pushback
/// (`DeferralAdvisor`): repeated moves, deadline pressure, and full days.
extension AppModel {
    var deferralAdvisor: DeferralAdvisor { DeferralAdvisor(prefs: prefs) }

    /// Fixed events plus every other planned block (so a full day reads as full).
    func deferralBusy(excluding blockIDs: Set<String> = []) -> (events: [CalendarEvent], blocked: [DateInterval]) {
        let events = context.all(StoredEvent.self).map(\.value)
        let blocked = context.all(StoredBlock.self)
            .filter { !blockIDs.contains($0.id) && !$0.skipped && !$0.completed && $0.end > $0.start }
            .map { DateInterval(start: $0.start, end: $0.end) }
        return (events, blocked)
    }

    func deferralItem(for block: StoredBlock) -> DeferralItem {
        let task = task(for: block)
        return DeferralItem(title: block.title, blockMinutes: Int(block.end.timeIntervalSince(block.start) / 60),
                            remainingMinutes: task.map { max(0, $0.estimateMinutes - $0.minutesDone) } ?? block.minutes,
                            deadline: task?.deadline, origin: task?.value.origin ?? .yours,
                            currentStart: block.start, history: task?.deferrals ?? [])
    }

    func deferralItem(for task: StoredTask) -> DeferralItem {
        let value = task.value
        return DeferralItem(title: task.title, blockMinutes: min(value.remainingMinutes, value.maxBlockMinutes),
                            remainingMinutes: value.remainingMinutes, deadline: task.deadline, origin: value.origin,
                            currentStart: task.earliestStart, history: task.deferrals)
    }

    func laterOptions(for item: DeferralItem, excluding: Set<String> = []) -> [DeferralOption] {
        let busy = deferralBusy(excluding: excluding)
        return deferralAdvisor.options(for: item, now: Date(), events: busy.events, blocked: busy.blocked)
    }

    func assessLater(_ item: DeferralItem, to target: Date, excluding: Set<String> = []) -> DeferralAssessment {
        let busy = deferralBusy(excluding: excluding)
        return deferralAdvisor.assess(item, to: target, now: Date(), events: busy.events, blocked: busy.blocked)
    }

    /// Moves a block to `target` (locked there) and records the move on its task.
    func moveLater(_ block: StoredBlock, to target: Date, assessment: DeferralAssessment?) {
        let length = block.end.timeIntervalSince(block.start)
        let from = block.start
        let snapshot = (start: block.start, end: block.end, locked: block.locked, started: block.startedAt)
        block.start = target
        block.end = target.addingTimeInterval(length)
        block.locked = true
        block.startedAt = nil
        let task = task(for: block)
        let oldHistory = task?.deferralHistoryData
        if let task {
            task.deferrals = DeferralAdvisor.record(task.deferrals, from: from, to: target, now: Date(), assessment: assessment)
            task.updatedAt = Date()
        }
        context.saveQuietly()
        backend.tasksChanged()
        refreshWidgets()
        show("Moved to \(Fmt.dayTime(target, calendar))", undo: { [weak self] in
            guard let self else { return }
            block.start = snapshot.start; block.end = snapshot.end
            block.locked = snapshot.locked; block.startedAt = snapshot.started
            task?.deferralHistoryData = oldHistory
            self.context.saveQuietly()
            self.backend.tasksChanged()
        })
    }

    /// Moves a whole task: nothing before `target`, future blocks released for replanning.
    func moveLater(_ task: StoredTask, to target: Date, assessment: DeferralAssessment?) {
        let oldStart = task.earliestStart
        let oldHistory = task.deferralHistoryData
        task.deferrals = DeferralAdvisor.record(task.deferrals, from: oldStart, to: target, now: Date(), assessment: assessment)
        task.earliestStart = target
        task.updatedAt = Date()
        for b in context.all(StoredBlock.self) where b.taskID == task.id && !b.completed && b.start < target && b.start > Date() {
            b.locked = false
        }
        context.saveQuietly()
        backend.tasksChanged()
        refreshWidgets()
        show("“\(task.title)” moved to \(Fmt.dayTime(target, calendar))", undo: { [weak self] in
            guard let self else { return }
            task.earliestStart = oldStart
            task.deferralHistoryData = oldHistory
            self.context.saveQuietly()
            self.backend.tasksChanged()
        })
    }
}

extension StoredTask {
    var deferrals: [DeferralRecord] {
        get { deferralHistoryData.flatMap { try? JSONDecoder().decode([DeferralRecord].self, from: $0) } ?? [] }
        set { deferralHistoryData = try? JSONEncoder().encode(newValue) }
    }
}
