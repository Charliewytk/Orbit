import XCTest
@testable import OrbitCore

final class GamificationTests: XCTestCase {
    private let tz = TimeZone(identifier: "Europe/London")!
    private let goals = DailyGoals(studyMinutes: 60, tasks: 2, reviews: 10)

    private func now() -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 15))!
    }

    func testXPRules() {
        let d = DayStats(day: "2026-09-26", studyMinutes: 65, tasksDone: 2, reviews: 10, shutdown: true)
        // 2 tasks (20) + 6 × 10 min (30) + 10 reviews (10) + shutdown (15) + all rings (50)
        XCTAssertEqual(XPRules.xp(for: d, goals: goals), 125)
        let capped = DayStats(day: "x", reviews: 500)
        XCTAssertEqual(XPRules.xp(for: capped, goals: DailyGoals(studyMinutes: 60, tasks: 2, reviews: 1000)), 100)
    }

    func testLevels() {
        XCTAssertEqual(Levels.info(totalXP: 0).level, 1)
        XCTAssertEqual(Levels.info(totalXP: 99).level, 1)
        XCTAssertEqual(Levels.info(totalXP: 100).level, 2)
        let l = Levels.info(totalXP: 175)
        XCTAssertEqual(l.level, 2)
        XCTAssertEqual(l.xpIntoLevel, 75)
        XCTAssertEqual(l.xpForLevel, 150)
        XCTAssertEqual(l.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(Levels.info(totalXP: 250).level, 3)
        XCTAssertEqual(Levels.info(totalXP: -5).level, 1)
    }

    func testBadgesAndStreak() {
        let keys = DayKeys(timeZone: tz)
        let n = now()
        let days = (0..<7).map { i in
            DayStats(day: keys.key(daysBefore: i, n), studyMinutes: 70, tasksDone: 2, reviews: 20)
        }
        let m = Momentum(days: days, goals: goals, timeZone: tz)
        let s = Gamification.summary(momentum: m, typeUps: 1, now: n)
        XCTAssertEqual(s.streak, 7)
        for b in [Badge.firstTask, .firstTypeUp, .firstFocusHour, .streak3, .streak7, .allRings, .allRings5] {
            XCTAssertTrue(s.earned.contains(b), "missing \(b)")
        }
        XCTAssertFalse(s.earned.contains(.streak30))
        XCTAssertGreaterThan(s.todayXP, 0)
        XCTAssertEqual(s.earned.count + s.locked.count, Badge.allCases.count)
    }

    func testEmptyHistory() {
        let m = Momentum(days: [], goals: goals, timeZone: tz)
        let s = Gamification.summary(momentum: m, now: now())
        XCTAssertEqual(s.level.level, 1)
        XCTAssertTrue(s.earned.isEmpty)
        XCTAssertEqual(s.streak, 0)
    }

    func testNewlyEarned() {
        let new = Gamification.newlyEarned(before: ["firstTask"], now: [.firstTask, .streak3])
        XCTAssertEqual(new, [.streak3])
    }
}
