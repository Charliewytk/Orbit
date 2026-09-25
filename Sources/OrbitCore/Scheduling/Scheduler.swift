import Foundation

/// A task (or part of one) the scheduler couldn't place.
public struct UnscheduledTask: Codable, Hashable, Sendable {
    public var task: OrbitTask
    public var reason: String
    public var minutesMissing: Int

    public init(task: OrbitTask, reason: String, minutesMissing: Int) {
        self.task = task; self.reason = reason; self.minutesMissing = minutesMissing
    }
}

/// The scheduler's output: every block on the Orbit calendar (kept + new).
public struct SchedulePlan: Codable, Hashable, Sendable {
    public var blocks: [ScheduledBlock]
    public var unscheduled: [UnscheduledTask]
    public var warnings: [String]
    /// Past blocks that were missed. Their minutes are planned again.
    public var missedBlockIDs: [UUID]

    public init(blocks: [ScheduledBlock] = [], unscheduled: [UnscheduledTask] = [], warnings: [String] = [],
                missedBlockIDs: [UUID] = []) {
        self.blocks = blocks; self.unscheduled = unscheduled; self.warnings = warnings
        self.missedBlockIDs = missedBlockIDs
    }

    public func blocks(for taskID: UUID) -> [ScheduledBlock] { blocks.filter { $0.taskID == taskID } }

    public func blocks(on day: Date, calendar: DayCalendar) -> [ScheduledBlock] {
        blocks.filter { calendar.isSameDay($0.start, day) }
    }

    public func minutes(for taskID: UUID) -> Int { blocks(for: taskID).reduce(0) { $0 + $1.minutes } }

    public var totalMinutes: Int { blocks.reduce(0) { $0 + $1.minutes } }
}

/// Deterministic planner that places task blocks into free time.
///
/// 1. Keeps locked blocks and anything already started; flags missed blocks.
/// 2. Finds free time (see `FreeSlotFinder`) over the horizon.
/// 3. Places tasks greedily, most urgent first (`TaskScorer`). Small tasks go
///    in as soon as possible; large ones are spread evenly across the days
///    before the deadline. Blocks respect min/max length, the daily focus cap,
///    buffers between blocks, and prefer matching energy windows.
/// 4. A light local pass swaps same-length blocks on the same day when that
///    improves the energy match.
/// No randomness: the same input always gives the same plan (and block IDs).
public struct Scheduler: Sendable {
    public var prefs: UserPrefs
    public var scorer: TaskScorer
    public var horizonDays: Int
    /// Focus-minute caps for specific days (keyed by local midnight), overriding
    /// `prefs.maxFocusMinutesPerDay`. Used by "lighten my day".
    public var dailyCapOverrides: [Date: Int]
    /// Missed blocks older than this don't produce warnings any more.
    public var missedLookbackHours: Double
    public var improvementPasses: Int

    public init(prefs: UserPrefs = UserPrefs(), scorer: TaskScorer = TaskScorer(), horizonDays: Int = 14,
                dailyCapOverrides: [Date: Int] = [:], missedLookbackHours: Double = 48, improvementPasses: Int = 3) {
        self.prefs = prefs; self.scorer = scorer; self.horizonDays = horizonDays
        self.dailyCapOverrides = dailyCapOverrides; self.missedLookbackHours = missedLookbackHours
        self.improvementPasses = improvementPasses
    }

    public var calendar: DayCalendar { DayCalendar(timeZone: prefs.timeZone) }

    /// Stable block ID for a task starting at a given time.
    public static func blockID(taskID: UUID, start: Date) -> UUID {
        StableUUID.make("orbit-block|\(taskID.uuidString)|\(Int(start.timeIntervalSince1970))")
    }

    // MARK: - Planning

    struct DayState {
        var day: Date
        var free: [DateInterval]
        var focusUsed: Int
        var cap: Int
        var isWorkDay: Bool
        var focusLeft: Int { max(0, cap - focusUsed) }
    }

    struct Job {
        var task: OrbitTask
        var need: Int
        var score: Double
    }

    public func plan(tasks: [OrbitTask], events: [CalendarEvent], existingBlocks: [ScheduledBlock] = [],
                     completedBlockIDs: Set<UUID> = [], now: Date) -> SchedulePlan {
        let cal = calendar
        let start = IntervalMath.roundUp5(now)
        let horizonEnd = cal.addingDays(max(1, horizonDays), to: cal.startOfDay(now))
        var warnings: [String] = []

        // 1. Keep locked blocks and anything that has started.
        let fixed = existingBlocks.filter { $0.locked || $0.start < now }

        let missed = MissedBlockDetector.missedBlocks(existingBlocks, tasks: tasks,
                                                      completedBlockIDs: completedBlockIDs, now: now)
            .filter { now.timeIntervalSince($0.end) <= missedLookbackHours * 3600 }
        for b in missed {
            warnings.append("Rescheduled “\(b.title)”: missed the \(b.minutes)-min block on \(cal.shortDay(b.start)) at \(cal.time(b.start)).")
        }

        // Work already covered by kept blocks that are still ahead.
        var fixedAhead: [UUID: Int] = [:]
        for b in fixed where b.end > now {
            fixedAhead[b.taskID, default: 0] += IntervalMath.minutes(DateInterval(start: max(b.start, now), end: b.end))
        }

        // 2. Free time per day.
        let finder = FreeSlotFinder(prefs: prefs, minimumSlotMinutes: 5)
        let blocked = fixed.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
        var days: [DayState] = finder.freeSlots(from: start, to: horizonEnd, events: events, blocked: blocked).map { ds in
            let used = fixed.filter { cal.isSameDay($0.start, ds.day) }.reduce(0) { $0 + $1.minutes }
            return DayState(day: ds.day, free: ds.slots, focusUsed: used,
                            cap: dailyCapOverrides[ds.day] ?? prefs.maxFocusMinutesPerDay, isWorkDay: ds.isWorkDay)
        }

        // 3. Jobs, most urgent first.
        var jobs: [Job] = []
        for t in tasks where !t.isDone {
            let need = IntervalMath.roundUp5(t.remainingMinutes - (fixedAhead[t.id] ?? 0))
            guard need > 0 else { continue }
            var target = need
            if let d = t.deadline, d > horizonEnd {
                // Only this horizon's fair share of work due later.
                let totalDays = max(1, cal.days(from: now, to: d))
                let share = Double(horizonDays) / Double(totalDays)
                let shareMinutes = IntervalMath.roundUp5(Int((Double(need) * share).rounded(.up)))
                target = min(need, max(min(need, t.minBlockMinutes), shareMinutes))
            }
            jobs.append(Job(task: t, need: target, score: scorer.score(t, now: now).total))
        }
        jobs.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return TaskScorer.tieBreak(a.task, b.task)
        }

        let pad = TimeInterval(prefs.bufferMinutes * 60)
        var newBlocks: [ScheduledBlock] = []
        var unscheduled: [UnscheduledTask] = []

        func energyPenalty(_ s: Date, _ minutes: Int, _ energy: Energy) -> Int {
            let mid = cal.minuteOfDay(s.addingTimeInterval(Double(minutes) * 30))
            return abs(prefs.energy(at: mid).rawValue - energy.rawValue)
        }

        /// Best start and length on a day for up to `size` minutes (at least `minLen`).
        func bestSlot(_ i: Int, size: Int, minLen: Int, window: DateInterval, energy: Energy) -> (Date, Int)? {
            var best: (start: Date, len: Int, penalty: Int, short: Int)?
            for f in days[i].free {
                let a = IntervalMath.roundUp5(max(f.start, window.start))
                let b = min(f.end, window.end)
                guard b > a else { continue }
                var candidates = [a]
                for w in prefs.energyWindows where w.energy == energy {
                    let ws = IntervalMath.roundUp5(cal.date(minute: w.start, of: days[i].day))
                    if ws > a && ws < b { candidates.append(ws) }
                }
                for c in candidates {
                    let avail = IntervalMath.roundDown5(IntervalMath.minutes(DateInterval(start: c, end: b)))
                    let len = min(size, avail)
                    guard len >= max(minLen, 5) else { continue }
                    let penalty = energyPenalty(c, len, energy)
                    let short = len < size ? 1 : 0
                    if let cur = best {
                        if (penalty, short) < (cur.penalty, cur.short)
                            || ((penalty, short) == (cur.penalty, cur.short) && c < cur.start) {
                            best = (c, len, penalty, short)
                        }
                    } else {
                        best = (c, len, penalty, short)
                    }
                }
            }
            return best.map { ($0.start, $0.len) }
        }

        /// Places as much of `remaining` as fits on day `i` (up to `allowance`). Returns minutes placed.
        @discardableResult
        func fill(_ i: Int, _ t: OrbitTask, remaining: inout Int, allowance: Int, window: DateInterval,
                  minBlock: Int, maxBlock: Int, requireWhole: Bool) -> Int {
            var left = allowance, placed = 0
            while remaining > 0 && left > 0 {
                let size = min(remaining, left, maxBlock, days[i].focusLeft)
                let minNeeded = requireWhole ? min(remaining, left, maxBlock) : min(minBlock, remaining)
                guard size > 0, size >= minNeeded else { break }
                guard let (s, len) = bestSlot(i, size: size, minLen: minNeeded, window: window, energy: t.energy) else { break }
                var length = len
                let tail = remaining - length
                if tail > 0 && tail < minBlock && length - (minBlock - tail) >= max(minNeeded, 5) {
                    length -= minBlock - tail // leave a usable tail rather than a sliver
                }
                let block = ScheduledBlock(id: Self.blockID(taskID: t.id, start: s), taskID: t.id, title: t.title,
                                           start: s, end: s.addingTimeInterval(Double(length) * 60),
                                           moduleCode: t.moduleCode)
                newBlocks.append(block)
                days[i].free = IntervalMath.subtract(days[i].free, [DateInterval(start: s.addingTimeInterval(-pad),
                                                                                 end: block.end.addingTimeInterval(pad))])
                    .filter { IntervalMath.minutes($0) >= 5 }
                days[i].focusUsed += length
                remaining -= length; left -= length; placed += length
            }
            return placed
        }

        for job in jobs {
            let t = job.task
            var remaining = job.need
            let earliest = max(start, t.earliestStart.map(IntervalMath.roundUp5) ?? start)
            let deadline = t.deadline.flatMap { $0 > now ? $0 : nil }
            if let d = t.deadline, d <= now {
                warnings.append("“\(t.title)” is overdue: planned as soon as possible.")
            }
            let minBlock = max(5, min(t.minBlockMinutes, t.maxBlockMinutes))
            let maxBlock = max(minBlock, t.maxBlockMinutes)
            let windowEnd = min(deadline ?? horizonEnd, horizonEnd)

            // Phase 1: before the deadline.
            if earliest < windowEnd {
                let window = DateInterval(start: earliest, end: windowEnd)
                let eligible = days.indices.filter { i in
                    days[i].isWorkDay && days[i].day < windowEnd && cal.endOfDay(days[i].day) > earliest
                        && days[i].focusLeft >= min(minBlock, remaining)
                        && days[i].free.contains { f in
                            let a = max(f.start, window.start), b = min(f.end, window.end)
                            return b > a && IntervalMath.minutes(DateInterval(start: a, end: b)) >= min(minBlock, remaining)
                        }
                }
                if !eligible.isEmpty {
                    var order = eligible
                    var perDayCap = remaining
                    var requireWhole = false
                    if remaining <= maxBlock {
                        requireWhole = true // small task: soonest slot that fits it in one go
                    } else {
                        let k = Int((Double(remaining) / Double(maxBlock)).rounded(.up))
                        if k >= eligible.count {
                            perDayCap = max(minBlock, IntervalMath.roundUp5(Int((Double(remaining) / Double(eligible.count)).rounded(.up))))
                        } else {
                            // Spread k sessions evenly across the days before the deadline.
                            let n = eligible.count
                            var picks: [Int] = []
                            for j in 0..<k {
                                let p = eligible[min(n - 1, Int((Double(j) + 0.5) * Double(n) / Double(k)))]
                                if !picks.contains(p) { picks.append(p) }
                            }
                            order = picks + eligible.filter { !picks.contains($0) }
                            perDayCap = maxBlock
                        }
                    }
                    for i in order where remaining > 0 {
                        fill(i, t, remaining: &remaining, allowance: perDayCap, window: window,
                             minBlock: minBlock, maxBlock: maxBlock, requireWhole: requireWhole)
                    }
                    // Second pass: anything left, earliest first, no per-day spreading.
                    for i in eligible where remaining > 0 {
                        fill(i, t, remaining: &remaining, allowance: .max, window: window,
                             minBlock: minBlock, maxBlock: maxBlock, requireWhole: false)
                    }
                }
            }

            // Phase 2: doesn't fit before the deadline → schedule after it anyway.
            if remaining > 0, let d = deadline, d < horizonEnd {
                let before = remaining
                let window = DateInterval(start: max(earliest, d), end: horizonEnd)
                if window.duration > 0 {
                    for i in days.indices where remaining > 0 && days[i].isWorkDay && cal.endOfDay(days[i].day) > window.start {
                        fill(i, t, remaining: &remaining, allowance: .max, window: window,
                             minBlock: minBlock, maxBlock: maxBlock, requireWhole: false)
                    }
                }
                let late = before - remaining
                let when = "\(cal.shortDay(d)) \(cal.time(d))"
                warnings.append(late > 0
                    ? "“\(t.title)” won't fit before deadline (\(when)): \(late) min planned after it."
                    : "“\(t.title)” won't fit before deadline (\(when)).")
            }

            if remaining > 0 {
                let reason: String
                if earliest >= horizonEnd {
                    reason = "Starts after the \(horizonDays)-day planning window."
                } else {
                    reason = "Not enough free time in the next \(horizonDays) days (\(remaining) min short)."
                }
                unscheduled.append(UnscheduledTask(task: t, reason: reason, minutesMissing: remaining))
            }
        }

        // 4. Local improvement: swap same-length blocks on the same day for a better energy match.
        let taskByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func allowed(_ t: OrbitTask, from original: ScheduledBlock, to slot: ScheduledBlock) -> Bool {
            if let e = t.earliestStart, slot.start < e { return false }
            if let d = t.deadline, d > now, original.end <= d, slot.end > d { return false }
            return true
        }
        for _ in 0..<max(0, improvementPasses) {
            var changed = false
            newBlocks.sort { $0.start < $1.start }
            for i in newBlocks.indices {
                for j in newBlocks.indices where j > i {
                    let a = newBlocks[i], b = newBlocks[j]
                    guard a.taskID != b.taskID, a.minutes == b.minutes, cal.isSameDay(a.start, b.start),
                          let ta = taskByID[a.taskID], let tb = taskByID[b.taskID] else { continue }
                    let before = energyPenalty(a.start, a.minutes, ta.energy) + energyPenalty(b.start, b.minutes, tb.energy)
                    let after = energyPenalty(b.start, a.minutes, ta.energy) + energyPenalty(a.start, b.minutes, tb.energy)
                    guard after < before, allowed(ta, from: a, to: b), allowed(tb, from: b, to: a) else { continue }
                    var na = a, nb = b
                    (na.start, na.end, nb.start, nb.end) = (b.start, b.end, a.start, a.end)
                    na.id = Self.blockID(taskID: na.taskID, start: na.start)
                    nb.id = Self.blockID(taskID: nb.taskID, start: nb.start)
                    newBlocks[i] = na; newBlocks[j] = nb
                    changed = true
                }
            }
            if !changed { break }
        }

        let all = (fixed + newBlocks).sorted {
            $0.start != $1.start ? $0.start < $1.start : $0.taskID.uuidString < $1.taskID.uuidString
        }
        return SchedulePlan(blocks: all, unscheduled: unscheduled, warnings: warnings, missedBlockIDs: missed.map(\.id))
    }
}

/// Finds past blocks whose work wasn't done.
public enum MissedBlockDetector {
    /// Blocks that ended by `now` and aren't covered by progress. A block counts as
    /// done if its ID is in `completedBlockIDs`, its task is complete, or the task's
    /// `minutesDone` covers it (earliest blocks are covered first).
    public static func missedBlocks(_ blocks: [ScheduledBlock], tasks: [OrbitTask],
                                    completedBlockIDs: Set<UUID> = [], now: Date) -> [ScheduledBlock] {
        let tasksByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let past = Dictionary(grouping: blocks.filter { $0.end <= now }, by: \.taskID)
        var out: [ScheduledBlock] = []
        for (taskID, list) in past {
            guard let task = tasksByID[taskID], !task.isDone else { continue }
            var budget = task.minutesDone
            for b in list.sorted(by: { $0.start < $1.start }) {
                if completedBlockIDs.contains(b.id) { budget -= b.minutes; continue }
                if budget >= b.minutes { budget -= b.minutes } else { out.append(b) }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Past blocks that were done (the complement of `missedBlocks` among ended blocks
    /// whose task is known).
    public static func doneBlocks(_ blocks: [ScheduledBlock], tasks: [OrbitTask],
                                  completedBlockIDs: Set<UUID> = [], now: Date) -> [ScheduledBlock] {
        let missed = Set(missedBlocks(blocks, tasks: tasks, completedBlockIDs: completedBlockIDs, now: now).map(\.id))
        let known = Set(tasks.map(\.id))
        return blocks.filter {
            $0.end <= now && !missed.contains($0.id) && (known.contains($0.taskID) || completedBlockIDs.contains($0.id))
        }.sorted { $0.start < $1.start }
    }
}
