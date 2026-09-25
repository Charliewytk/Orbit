import Foundation

/// What to change on the Orbit calendar to get from the old plan to the new one.
public struct CalendarChangeSet: Codable, Hashable, Sendable {
    /// New blocks to write.
    public var create: [ScheduledBlock]
    /// Existing blocks that moved or changed (same ID and `externalEventID`, new details).
    public var update: [ScheduledBlock]
    /// Old blocks to remove from the calendar.
    public var delete: [ScheduledBlock]
    /// Blocks that stay exactly as they are (including locked and past ones).
    public var unchanged: [ScheduledBlock]

    public init(create: [ScheduledBlock] = [], update: [ScheduledBlock] = [], delete: [ScheduledBlock] = [],
                unchanged: [ScheduledBlock] = []) {
        self.create = create; self.update = update; self.delete = delete; self.unchanged = unchanged
    }

    public var isEmpty: Bool { create.isEmpty && update.isEmpty && delete.isEmpty }
}

public struct ReplanResult: Codable, Hashable, Sendable {
    /// The new plan, with block IDs carried over from the old one where possible.
    public var plan: SchedulePlan
    public var changes: CalendarChangeSet
}

/// Re-runs the scheduler and works out the minimal calendar changes.
///
/// Locked blocks and blocks that have started are never touched. A task that
/// keeps the same slot keeps its block ID; a task whose block moved reuses an
/// old block (so the calendar event is updated rather than deleted and re-created).
public struct Replanner: Sendable {
    public var scheduler: Scheduler

    public init(scheduler: Scheduler) { self.scheduler = scheduler }

    public init(prefs: UserPrefs, scorer: TaskScorer = TaskScorer(), horizonDays: Int = 14) {
        self.init(scheduler: Scheduler(prefs: prefs, scorer: scorer, horizonDays: horizonDays))
    }

    public func replan(tasks: [OrbitTask], events: [CalendarEvent], current: [ScheduledBlock],
                       completedBlockIDs: Set<UUID> = [], now: Date) -> ReplanResult {
        let plan = scheduler.plan(tasks: tasks, events: events, existingBlocks: current,
                                  completedBlockIDs: completedBlockIDs, now: now)
        return Self.result(old: current, plan: plan, now: now)
    }

    /// Reduces the planned (movable) work on `day` by `fraction` (0–1) and pushes it
    /// to later days. Earlier days are left as they are.
    public func lighten(day: Date, by fraction: Double, tasks: [OrbitTask], events: [CalendarEvent],
                        current: [ScheduledBlock], completedBlockIDs: Set<UUID> = [], now: Date) -> ReplanResult {
        let cal = scheduler.calendar
        let dayStart = cal.startOfDay(day), dayEnd = cal.endOfDay(day)
        let onDay = current.filter { $0.start >= dayStart && $0.start < dayEnd }
        let movable = onDay.filter { !$0.locked && $0.start >= now }
        let fixedMinutes = onDay.filter { $0.locked || $0.start < now }.reduce(0) { $0 + $1.minutes }
        let movableMinutes = movable.reduce(0) { $0 + $1.minutes }
        let keep = IntervalMath.roundDown5(Int(Double(movableMinutes) * (1 - min(1, max(0, fraction)))))

        var sched = scheduler
        sched.dailyCapOverrides[dayStart] = fixedMinutes + keep
        // Freeze earlier days: their future blocks stay put and they take no extra work.
        let frozen = Set(current.filter { !$0.locked && $0.start >= now && $0.start < dayStart }.map(\.id))
        for d in cal.dayStarts(from: now, to: dayStart) { sched.dailyCapOverrides[d] = 0 }
        let input = current.map { b -> ScheduledBlock in
            var b = b
            if frozen.contains(b.id) { b.locked = true }
            return b
        }

        var plan = sched.plan(tasks: tasks, events: events, existingBlocks: input,
                              completedBlockIDs: completedBlockIDs, now: now)
        plan.blocks = plan.blocks.map { b in
            var b = b
            if frozen.contains(b.id) { b.locked = false }
            return b
        }
        let after = plan.blocks.filter { $0.start >= dayStart && $0.start < dayEnd && !$0.locked && $0.start >= now }
            .reduce(0) { $0 + $1.minutes }
        let moved = movableMinutes - after
        if moved > 0 {
            plan.warnings.append("Lightened \(cal.shortDay(dayStart)): moved \(moved) min to later days.")
        }
        return Self.result(old: current, plan: plan, now: now)
    }

    static func result(old: [ScheduledBlock], plan: SchedulePlan, now: Date) -> ReplanResult {
        let (blocks, changes) = diff(old: old, new: plan.blocks, now: now)
        var p = plan
        p.blocks = blocks
        return ReplanResult(plan: p, changes: changes)
    }

    /// Diffs two block lists into calendar operations. Returns the new blocks
    /// with stable IDs/external IDs, plus the change set.
    public static func diff(old: [ScheduledBlock], new: [ScheduledBlock], now: Date)
        -> (blocks: [ScheduledBlock], changes: CalendarChangeSet) {
        let kept = old.filter { $0.locked || $0.start < now }
        let keptIDs = Set(kept.map(\.id))
        let movableOld = old.filter { !keptIDs.contains($0.id) }.sorted { $0.start < $1.start }
        let incoming = new.filter { !keptIDs.contains($0.id) }.sorted { $0.start < $1.start }

        var used = Set<Int>()
        var match: [Int: Int] = [:]
        // 1. Same task, same slot.
        for (ni, n) in incoming.enumerated() {
            if let oi = movableOld.indices.first(where: {
                !used.contains($0) && movableOld[$0].taskID == n.taskID
                    && movableOld[$0].start == n.start && movableOld[$0].end == n.end
            }) {
                used.insert(oi); match[ni] = oi
            }
        }
        // 2. Same task, moved: pair up in time order.
        for (ni, n) in incoming.enumerated() where match[ni] == nil {
            if let oi = movableOld.indices.first(where: { !used.contains($0) && movableOld[$0].taskID == n.taskID }) {
                used.insert(oi); match[ni] = oi
            }
        }

        var changes = CalendarChangeSet(unchanged: kept)
        var blocks = kept
        var ids = keptIDs.union(match.values.map { movableOld[$0].id })
        for (ni, n) in incoming.enumerated() {
            var b = n
            if let oi = match[ni] {
                let o = movableOld[oi]
                b.id = o.id
                b.externalEventID = o.externalEventID ?? n.externalEventID
                if b.start == o.start && b.end == o.end && b.title == o.title && b.moduleCode == o.moduleCode
                    && b.locked == o.locked {
                    changes.unchanged.append(b)
                } else {
                    changes.update.append(b)
                }
            } else {
                // A fresh block must not reuse an ID still in use.
                var salt = 0
                while ids.contains(b.id) {
                    salt += 1
                    b.id = StableUUID.make("\(n.id.uuidString)#\(salt)")
                }
                b.externalEventID = nil
                changes.create.append(b)
            }
            ids.insert(b.id)
            blocks.append(b)
        }
        changes.delete = movableOld.indices.filter { !used.contains($0) }.map { movableOld[$0] }
        blocks.sort { $0.start != $1.start ? $0.start < $1.start : $0.taskID.uuidString < $1.taskID.uuidString }
        return (blocks, changes)
    }
}
