import Foundation

/// Unfinished work Orbit suggests carrying forward.
public struct RolloverSuggestion: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID { taskID }
    public var taskID: UUID
    public var title: String
    public var minutes: Int
    public var reason: String
    /// Next working day.
    public var suggestedDay: Date?
}

/// Consecutive productive days. Rest days don't break a streak.
public struct StreakState: Codable, Hashable, Sendable {
    public var count: Int
    public var best: Int
    public var lastActiveDay: Date?

    public init(count: Int = 0, best: Int = 0, lastActiveDay: Date? = nil) {
        self.count = count; self.best = best; self.lastActiveDay = lastActiveDay
    }
}

/// End-of-day review: what got done, what slipped, and a look at tomorrow.
public struct EveningReview: Codable, Hashable, Sendable {
    public var date: Date
    public var generatedAt: Date
    public var timeZoneID: String
    public var done: [ScheduledBlock]
    public var missed: [ScheduledBlock]
    /// Blocks later today that haven't finished yet.
    public var remaining: [ScheduledBlock]
    public var completedTasks: [OrbitTask]
    public var minutesDone: Int
    public var minutesPlanned: Int
    /// done ÷ (done + missed) minutes; nil when nothing was due to finish yet.
    public var completionRate: Double?
    public var rollovers: [RolloverSuggestion]
    public var tomorrowEvents: [CalendarEvent]
    public var tomorrowBlocks: [ScheduledBlock]
    public var tomorrowFirstStart: Date?
    public var dueTomorrow: [DueItem]
    public var wasProductive: Bool
    /// The streak after today.
    public var streak: StreakState
    public var narrative: String?

    public var calendar: DayCalendar { DayCalendar(timeZone: TimeZone(identifier: timeZoneID) ?? .current) }

    public func plainSummary() -> String {
        let cal = calendar
        var lines = ["Date: \(cal.format(date, "EEEE d MMMM yyyy"))"]
        lines.append("Planned today: \(BriefText.duration(minutesPlanned)); done: \(BriefText.duration(minutesDone))"
            + (completionRate.map { " (\(Int(($0 * 100).rounded()))%)" } ?? "") + ".")
        if !done.isEmpty { lines.append("Done: " + done.map(\.title).joined(separator: "; ") + ".") }
        if !missed.isEmpty {
            lines.append("Missed: " + missed.map { "\($0.title) at \(cal.time($0.start))" }.joined(separator: "; ") + ".")
        }
        if !completedTasks.isEmpty {
            lines.append("Tasks finished: " + completedTasks.map(\.title).joined(separator: "; ") + ".")
        }
        if !rollovers.isEmpty {
            lines.append("Rolling over: " + rollovers.map { r in
                "\(r.title) (\(BriefText.duration(r.minutes)), \(r.reason.lowercased()))"
                    + (r.suggestedDay.map { " → \(cal.shortDay($0))" } ?? "")
            }.joined(separator: "; ") + ".")
        }
        if tomorrowEvents.isEmpty && tomorrowBlocks.isEmpty {
            lines.append("Tomorrow: nothing scheduled yet.")
        } else {
            var t: [String] = tomorrowEvents.map { "\(BriefText.range($0.start, $0.end, cal)) \($0.title)" }
            t += tomorrowBlocks.map { "\(BriefText.range($0.start, $0.end, cal)) \($0.title) (study)" }
            lines.append("Tomorrow: " + t.joined(separator: "; ") + ".")
        }
        if !dueTomorrow.isEmpty {
            lines.append("Due tomorrow: " + dueTomorrow.map(\.title).joined(separator: "; ") + ".")
        }
        lines.append("Streak: \(streak.count) day\(streak.count == 1 ? "" : "s") (best \(streak.best)).")
        return lines.joined(separator: "\n")
    }

    /// A friendly 3–5 sentence wrap-up in UK English.
    public func narrate(using router: LLMRouter) async throws -> String {
        try await BriefText.narrate(facts: plainSummary(), kind: "evening review", router: router)
    }

    public func narrated(using router: LLMRouter) async -> EveningReview {
        var copy = self
        copy.narrative = try? await narrate(using: router)
        return copy
    }
}

public struct EveningReviewBuilder: Sendable {
    public var prefs: UserPrefs

    public init(prefs: UserPrefs = UserPrefs()) { self.prefs = prefs }

    /// - Parameters:
    ///   - blocks: all known blocks (today, tomorrow and earlier ones for progress accounting).
    ///   - completedBlockIDs: blocks you ticked off.
    ///   - previousStreak: the streak as of the last review.
    public func build(now: Date, blocks: [ScheduledBlock], completedBlockIDs: Set<UUID> = [], tasks: [OrbitTask],
                      events: [CalendarEvent] = [], assessments: [Assessment] = [],
                      previousStreak: StreakState = StreakState()) -> EveningReview {
        let cal = DayCalendar(timeZone: prefs.timeZone)
        let finder = FreeSlotFinder(prefs: prefs)
        let day = cal.startOfDay(now), dayEnd = cal.endOfDay(now)
        let tomorrow = dayEnd, tomorrowEnd = cal.endOfDay(dayEnd)
        let taskByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let isToday: (ScheduledBlock) -> Bool = { $0.start >= day && $0.start < dayEnd }
        let missed = MissedBlockDetector.missedBlocks(blocks, tasks: tasks, completedBlockIDs: completedBlockIDs, now: now)
            .filter(isToday)
        let done = MissedBlockDetector.doneBlocks(blocks, tasks: tasks, completedBlockIDs: completedBlockIDs, now: now)
            .filter(isToday)
        let todays = blocks.filter(isToday).sorted { $0.start < $1.start }
        let remaining = todays.filter { $0.end > now }
        let completed = tasks.filter { t in t.completedAt.map { $0 >= day && $0 < dayEnd } ?? false }
            .sorted { ($0.completedAt ?? now) < ($1.completedAt ?? now) }

        let doneMinutes = done.reduce(0) { $0 + $1.minutes }
        let missedMinutes = missed.reduce(0) { $0 + $1.minutes }
        let rate: Double? = doneMinutes + missedMinutes > 0 ? Double(doneMinutes) / Double(doneMinutes + missedMinutes) : nil

        // Next working day for rollovers.
        var nextWorkDay: Date? = nil
        var d = tomorrow
        for _ in 0..<7 {
            if !finder.isRestDay(d) { nextWorkDay = d; break }
            d = cal.addingDays(1, to: d)
        }

        var rollovers: [RolloverSuggestion] = []
        var seen = Set<UUID>()
        for b in missed {
            guard let t = taskByID[b.taskID], !t.isDone, !seen.contains(t.id) else { continue }
            seen.insert(t.id)
            let minutes = missed.filter { $0.taskID == t.id }.reduce(0) { $0 + $1.minutes }
            rollovers.append(RolloverSuggestion(taskID: t.id, title: t.title, minutes: min(minutes, max(t.remainingMinutes, 5)),
                                                reason: "Missed today's block", suggestedDay: nextWorkDay))
        }
        for t in tasks where !t.isDone && !seen.contains(t.id) {
            guard let dl = t.deadline, dl < dayEnd, t.remainingMinutes > 0 else { continue }
            seen.insert(t.id)
            rollovers.append(RolloverSuggestion(taskID: t.id, title: t.title, minutes: t.remainingMinutes,
                                                reason: dl < day ? "Overdue" : "Was due today", suggestedDay: nextWorkDay))
        }

        let tomorrowEvents = events.filter { $0.source != .orbit && $0.start < tomorrowEnd && $0.end > tomorrow }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
        let tomorrowBlocks = blocks.filter { $0.start >= tomorrow && $0.start < tomorrowEnd }.sorted { $0.start < $1.start }
        let dueTomorrow = BriefText.dueItems(now: now, days: 1, tasks: tasks, assessments: assessments, cal: cal)
            .filter { $0.due >= tomorrow && $0.due < tomorrowEnd }

        let productive = doneMinutes > 0 || !completed.isEmpty
        let streak = Self.updateStreak(previousStreak, day: day, productive: productive, cal: cal, finder: finder)

        return EveningReview(
            date: day, generatedAt: now, timeZoneID: prefs.timeZoneID, done: done, missed: missed,
            remaining: remaining, completedTasks: completed, minutesDone: doneMinutes,
            minutesPlanned: todays.reduce(0) { $0 + $1.minutes }, completionRate: rate, rollovers: rollovers,
            tomorrowEvents: tomorrowEvents, tomorrowBlocks: tomorrowBlocks,
            tomorrowFirstStart: (tomorrowEvents.filter { !$0.isAllDay }.map(\.start) + tomorrowBlocks.map(\.start)).min(),
            dueTomorrow: dueTomorrow, wasProductive: productive, streak: streak, narrative: nil)
    }

    /// Extends the streak if today was productive and the last active day was the
    /// previous working day (rest days in between are skipped). An unproductive
    /// working day resets it.
    static func updateStreak(_ s: StreakState, day: Date, productive: Bool, cal: DayCalendar,
                             finder: FreeSlotFinder) -> StreakState {
        var out = s
        if let last = s.lastActiveDay, cal.isSameDay(last, day) { return out }
        if productive {
            var continues = false
            if let last = s.lastActiveDay, last < day, s.count > 0 {
                continues = true
                var d = cal.addingDays(1, to: cal.startOfDay(last))
                while d < day {
                    if !finder.isRestDay(d) { continues = false; break }
                    d = cal.addingDays(1, to: d)
                }
            }
            out.count = continues ? s.count + 1 : 1
            out.lastActiveDay = day
            out.best = max(out.best, out.count)
        } else if !finder.isRestDay(day) {
            out.count = 0
        }
        return out
    }
}
