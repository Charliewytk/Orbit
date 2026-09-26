import Foundation

// Calm gamification: XP from the same daily numbers as the rings, levels with a
// gently rising curve, and badges for milestones. Pure: everything is derived
// from DayStats history (plus a few counters), so nothing extra has to be stored
// and the numbers can never drift out of sync with the rings.

/// How much each thing is worth.
public enum XPRules {
    public static let perTask = 10
    /// Per full 10 minutes of study.
    public static let perTenStudyMinutes = 5
    public static let perReview = 1
    /// Closing all three rings in a day.
    public static let allRingsBonus = 50
    public static let shutdown = 15
    public static let perTypeUp = 20
    /// Reviews above this in one day earn nothing more (no grinding).
    public static let reviewCapPerDay = 100
    /// Study minutes above this in one day earn nothing more.
    public static let studyCapPerDay = 8 * 60

    /// XP earned on one day.
    public static func xp(for day: DayStats, goals: DailyGoals) -> Int {
        var xp = day.tasksDone * perTask
        xp += (min(day.studyMinutes, studyCapPerDay) / 10) * perTenStudyMinutes
        xp += min(day.reviews, reviewCapPerDay) * perReview
        if day.shutdown { xp += shutdown }
        if day.allGoalsMet(goals) { xp += allRingsBonus }
        return xp
    }
}

/// Where the student is on the level curve.
public struct LevelInfo: Hashable, Sendable {
    public var level: Int
    /// XP earned inside the current level.
    public var xpIntoLevel: Int
    /// XP the current level needs in total.
    public var xpForLevel: Int
    public var totalXP: Int

    /// 0–1 through the current level.
    public var progress: Double { xpForLevel == 0 ? 0 : Double(xpIntoLevel) / Double(xpForLevel) }
    public var xpToNext: Int { max(0, xpForLevel - xpIntoLevel) }

    /// A friendly name for the level.
    public var title: String {
        switch level {
        case ..<3: "Getting started"
        case 3..<6: "Finding a rhythm"
        case 6..<10: "Steady"
        case 10..<15: "In orbit"
        case 15..<25: "High flyer"
        default: "Stellar"
        }
    }
}

public enum Levels {
    /// XP needed to go from `level` to `level + 1`: 100, 150, 200, … (capped at 1000).
    public static func cost(ofLevel level: Int) -> Int { min(1000, 100 + max(0, level - 1) * 50) }

    public static func info(totalXP: Int) -> LevelInfo {
        var level = 1
        var remaining = max(0, totalXP)
        while remaining >= cost(ofLevel: level) {
            remaining -= cost(ofLevel: level)
            level += 1
        }
        return LevelInfo(level: level, xpIntoLevel: remaining, xpForLevel: cost(ofLevel: level), totalXP: max(0, totalXP))
    }
}

/// Milestones. Stable raw values (they're remembered to celebrate new ones once).
public enum Badge: String, CaseIterable, Identifiable, Sendable, Codable {
    case firstTask, firstTypeUp, firstFocusHour, streak3, streak7, streak30, allRings, allRings5, reviews100, tasks50, level5, level10

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .firstTask: "First tick"
        case .firstTypeUp: "First type-up"
        case .firstFocusHour: "Deep hour"
        case .streak3: "3-day streak"
        case .streak7: "7-day streak"
        case .streak30: "30-day streak"
        case .allRings: "Rings closed"
        case .allRings5: "Five perfect days"
        case .reviews100: "100 reviews"
        case .tasks50: "50 to-dos"
        case .level5: "Level 5"
        case .level10: "Level 10"
        }
    }

    public var detail: String {
        switch self {
        case .firstTask: "Ticked off your first to-do."
        case .firstTypeUp: "Typed up a lecture's notes."
        case .firstFocusHour: "An hour of study in one day."
        case .streak3: "Three days in a row."
        case .streak7: "A full week in a row."
        case .streak30: "A month without a gap."
        case .allRings: "Closed all three rings in a day."
        case .allRings5: "Closed every ring on five days."
        case .reviews100: "Reviewed 100 flashcards."
        case .tasks50: "Ticked off 50 to-dos."
        case .level5: "Reached level 5."
        case .level10: "Reached level 10."
        }
    }

    /// SF Symbol.
    public var symbol: String {
        switch self {
        case .firstTask: "checkmark.circle.fill"
        case .firstTypeUp: "keyboard.fill"
        case .firstFocusHour: "hourglass"
        case .streak3: "flame"
        case .streak7: "flame.fill"
        case .streak30: "flame.circle.fill"
        case .allRings: "circle.circle.fill"
        case .allRings5: "rosette"
        case .reviews100: "rectangle.stack.fill"
        case .tasks50: "list.bullet.clipboard.fill"
        case .level5: "star.fill"
        case .level10: "star.circle.fill"
        }
    }
}

/// Everything the Home header and the badges sheet show.
public struct ProgressSummary: Sendable {
    public var level: LevelInfo
    public var todayXP: Int
    public var streak: Int
    public var bestStreak: Int
    public var earned: [Badge]

    public var locked: [Badge] { Badge.allCases.filter { !earned.contains($0) } }
}

public enum Gamification {
    /// - typeUps: type-ups done so far (routine type-up blocks ticked off).
    public static func summary(momentum: Momentum, typeUps: Int = 0, now: Date) -> ProgressSummary {
        let goals = momentum.goals
        let days = momentum.days.values
        var total = typeUps * XPRules.perTypeUp
        var tasks = 0, reviews = 0, perfect = 0, bestStudy = 0
        for d in days {
            total += XPRules.xp(for: d, goals: goals)
            tasks += d.tasksDone
            reviews += d.reviews
            bestStudy = max(bestStudy, d.studyMinutes)
            if d.allGoalsMet(goals) { perfect += 1 }
        }
        let today = XPRules.xp(for: momentum.stats(momentum.keys.key(now)), goals: goals)
        let level = Levels.info(totalXP: total)
        let streak = momentum.streak(now: now)
        let best = max(streak, momentum.bestStreak())

        var earned: [Badge] = []
        if tasks >= 1 { earned.append(.firstTask) }
        if typeUps >= 1 { earned.append(.firstTypeUp) }
        if bestStudy >= 60 { earned.append(.firstFocusHour) }
        if best >= 3 { earned.append(.streak3) }
        if best >= 7 { earned.append(.streak7) }
        if best >= 30 { earned.append(.streak30) }
        if perfect >= 1 { earned.append(.allRings) }
        if perfect >= 5 { earned.append(.allRings5) }
        if reviews >= 100 { earned.append(.reviews100) }
        if tasks >= 50 { earned.append(.tasks50) }
        if level.level >= 5 { earned.append(.level5) }
        if level.level >= 10 { earned.append(.level10) }
        return ProgressSummary(level: level, todayXP: today, streak: streak, bestStreak: best, earned: earned)
    }

    /// Badges in `now` that weren't in `before` (to celebrate once).
    public static func newlyEarned(before: Set<String>, now: [Badge]) -> [Badge] {
        now.filter { !before.contains($0.rawValue) }
    }
}
