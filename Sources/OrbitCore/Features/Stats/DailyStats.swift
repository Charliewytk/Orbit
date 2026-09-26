import Foundation

// Daily momentum: study minutes, to-dos done and flashcard reviews per day, the
// goals behind the three rings on the Home dashboard, the streak and the
// GitHub-style heatmap. Pure; the Mac app gathers the numbers (focus log,
// completed to-dos and blocks, reviews) and stores what it can't recompute.

/// The three daily goals (the rings).
public struct DailyGoals: Codable, Hashable, Sendable {
    public var studyMinutes: Int
    public var tasks: Int
    public var reviews: Int

    public init(studyMinutes: Int = 120, tasks: Int = 5, reviews: Int = 20) {
        self.studyMinutes = studyMinutes; self.tasks = tasks; self.reviews = reviews
    }

    enum CodingKeys: String, CodingKey { case studyMinutes, tasks, reviews }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DailyGoals()
        studyMinutes = max(1, (try? c.decode(Int.self, forKey: .studyMinutes)) ?? d.studyMinutes)
        tasks = max(1, (try? c.decode(Int.self, forKey: .tasks)) ?? d.tasks)
        reviews = max(1, (try? c.decode(Int.self, forKey: .reviews)) ?? d.reviews)
    }
}

/// One day's numbers. `day` is "yyyy-MM-dd" in the student's time zone.
public struct DayStats: Codable, Hashable, Sendable, Identifiable {
    public var day: String
    public var studyMinutes: Int
    public var tasksDone: Int
    public var reviews: Int
    /// The evening shutdown ritual was completed (counts towards the streak).
    public var shutdown: Bool

    public var id: String { day }

    public init(day: String, studyMinutes: Int = 0, tasksDone: Int = 0, reviews: Int = 0, shutdown: Bool = false) {
        self.day = day; self.studyMinutes = studyMinutes; self.tasksDone = tasksDone; self.reviews = reviews
        self.shutdown = shutdown
    }

    enum CodingKeys: String, CodingKey { case day, studyMinutes, tasksDone, reviews, shutdown }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        studyMinutes = (try? c.decode(Int.self, forKey: .studyMinutes)) ?? 0
        tasksDone = (try? c.decode(Int.self, forKey: .tasksDone)) ?? 0
        reviews = (try? c.decode(Int.self, forKey: .reviews)) ?? 0
        shutdown = (try? c.decode(Bool.self, forKey: .shutdown)) ?? false
    }

    /// Anything done at all (keeps the streak alive).
    public var isActive: Bool { studyMinutes >= 10 || tasksDone > 0 || reviews >= 5 || shutdown }

    public func studyProgress(_ goals: DailyGoals) -> Double { Double(studyMinutes) / Double(max(1, goals.studyMinutes)) }
    public func taskProgress(_ goals: DailyGoals) -> Double { Double(tasksDone) / Double(max(1, goals.tasks)) }
    public func reviewProgress(_ goals: DailyGoals) -> Double { Double(reviews) / Double(max(1, goals.reviews)) }

    /// 0–1: the average of the three rings, each capped at 1.
    public func score(_ goals: DailyGoals) -> Double {
        (min(1, studyProgress(goals)) + min(1, taskProgress(goals)) + min(1, reviewProgress(goals))) / 3
    }

    /// All three rings closed.
    public func allGoalsMet(_ goals: DailyGoals) -> Bool {
        studyProgress(goals) >= 1 && taskProgress(goals) >= 1 && reviewProgress(goals) >= 1
    }
}

/// Day keys ("2026-09-26") in a given time zone.
public struct DayKeys: Sendable {
    public let calendar: Calendar

    public init(timeZone: TimeZone) {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.firstWeekday = 2
        calendar = c
    }

    public func key(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }

    public func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    public func key(daysBefore n: Int, _ date: Date) -> String {
        key(calendar.date(byAdding: .day, value: -n, to: date) ?? date)
    }
}

/// The streak and the heatmap.
public struct Momentum: Sendable {
    public var days: [String: DayStats]
    public var goals: DailyGoals
    public var keys: DayKeys

    public init(days: [DayStats], goals: DailyGoals, timeZone: TimeZone) {
        var map: [String: DayStats] = [:]
        for d in days { map[d.day] = d }
        self.days = map
        self.goals = goals
        self.keys = DayKeys(timeZone: timeZone)
    }

    public func stats(_ key: String) -> DayStats { days[key] ?? DayStats(day: key) }

    /// Consecutive active days ending today. Today not being active yet doesn't
    /// break it: the streak runs to yesterday until today ends.
    public func streak(now: Date) -> Int {
        var count = 0
        var offset = stats(keys.key(now)).isActive ? 0 : 1
        while offset < 3660 {
            guard stats(keys.key(daysBefore: offset, now)).isActive else { break }
            count += 1
            offset += 1
        }
        return count
    }

    /// Whether today already counts towards the streak.
    public func todayCounts(now: Date) -> Bool { stats(keys.key(now)).isActive }

    /// The longest run of active days in the history.
    public func bestStreak() -> Int {
        let active = days.values.filter(\.isActive).compactMap { keys.date($0.day) }.sorted()
        var best = 0, run = 0
        var previous: Date?
        for d in active {
            if let p = previous, keys.calendar.dateComponents([.day], from: p, to: d).day == 1 { run += 1 } else { run = 1 }
            best = max(best, run)
            previous = d
        }
        return best
    }

    /// Heatmap cells: `weeks` columns (oldest first) of 7 days (Monday first).
    /// Level 0 = nothing, 1–4 = a quarter of the goals each; future days are nil.
    public func heatmap(weeks: Int, now: Date) -> [[HeatCell?]] {
        let cal = keys.calendar
        let today = cal.startOfDay(for: now)
        let weekday = (cal.component(.weekday, from: today) + 5) % 7 // Monday = 0
        guard let thisMonday = cal.date(byAdding: .day, value: -weekday, to: today) else { return [] }
        return (0..<weeks).map { w in
            let monday = cal.date(byAdding: .day, value: -7 * (weeks - 1 - w), to: thisMonday) ?? thisMonday
            return (0..<7).map { d -> HeatCell? in
                guard let date = cal.date(byAdding: .day, value: d, to: monday), date <= today else { return nil }
                let key = keys.key(date)
                let s = stats(key)
                return HeatCell(day: key, date: date, level: Self.level(s, goals), stats: s)
            }
        }
    }

    public static func level(_ s: DayStats, _ goals: DailyGoals) -> Int {
        let score = s.score(goals)
        if score <= 0 && !s.isActive { return 0 }
        if score < 0.25 { return 1 }
        if score < 0.5 { return 2 }
        if score < 0.85 { return 3 }
        return 4
    }

    /// Totals for the last 7 days (including today).
    public func lastWeek(now: Date) -> DayStats {
        var total = DayStats(day: "week")
        for i in 0..<7 {
            let s = stats(keys.key(daysBefore: i, now))
            total.studyMinutes += s.studyMinutes
            total.tasksDone += s.tasksDone
            total.reviews += s.reviews
        }
        return total
    }
}

public struct HeatCell: Hashable, Sendable, Identifiable {
    public var day: String
    public var date: Date
    public var level: Int
    public var stats: DayStats
    public var id: String { day }
}

/// Builds per-day stats from raw records.
public enum DailyStatsBuilder {
    /// - focus: (start, minutes) of logged focus sessions.
    /// - completedBlocks: (start, minutes) of planned blocks ticked off without a focus session.
    /// - completedTasks: completion times of to-dos.
    /// - reviews: day key → reviews, as recorded.
    public static func build(focus: [(Date, Int)], completedBlocks: [(Date, Int)], completedTasks: [Date],
                             reviews: [String: Int], timeZone: TimeZone, shutdownDays: Set<String> = []) -> [DayStats] {
        let keys = DayKeys(timeZone: timeZone)
        var map: [String: DayStats] = [:]
        func touch(_ key: String, _ change: (inout DayStats) -> Void) {
            var s = map[key] ?? DayStats(day: key)
            change(&s)
            map[key] = s
        }
        for (date, minutes) in focus { touch(keys.key(date)) { $0.studyMinutes += max(0, minutes) } }
        for (date, minutes) in completedBlocks { touch(keys.key(date)) { $0.studyMinutes += max(0, minutes) } }
        for date in completedTasks { touch(keys.key(date)) { $0.tasksDone += 1 } }
        for (key, n) in reviews { touch(key) { $0.reviews += max(0, n) } }
        for key in shutdownDays { touch(key) { $0.shutdown = true } }
        return map.values.sorted { $0.day < $1.day }
    }
}
