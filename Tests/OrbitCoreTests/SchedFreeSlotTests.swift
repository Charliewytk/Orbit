import XCTest
@testable import OrbitCore

final class SchedFreeSlotTests: XCTestCase {
    typealias F = SchedFixtures
    let prefs = UserPrefs() // 08:00–21:00 work, lunch 12:30–13:15, dinner 18:30–19:15, 10 min buffer

    func minutes(_ i: DateInterval) -> (Int, Int) { (F.cal.minuteOfDay(i.start), F.cal.minuteOfDay(i.end)) }

    func testEmptyDayIsWorkingHoursMinusMeals() {
        let slots = FreeSlotFinder(prefs: prefs).freeSlots(on: F.monday, events: [])
        XCTAssertEqual(slots.map(minutes).map { [$0.0, $0.1] },
                       [[480, 750], [795, 1110], [1155, 1260]])
    }

    func testBusyEventsAreRemovedWithBuffer() {
        let lecture = F.event("Lecture", F.date(2026, 10, 5, 10), F.date(2026, 10, 5, 11))
        let slots = FreeSlotFinder(prefs: prefs).freeSlots(on: F.monday, events: [lecture])
        XCTAssertEqual(minutes(slots[0]).1, 9 * 60 + 50)
        XCTAssertEqual(minutes(slots[1]).0, 11 * 60 + 10)
    }

    func testAllDayAndFreeEventsDontBlock() {
        let allDay = F.event("Essay due", F.monday, F.date(2026, 10, 6), allDay: true)
        let free = F.event("Maybe coffee", F.date(2026, 10, 5, 9), F.date(2026, 10, 5, 10), busy: false)
        let slots = FreeSlotFinder(prefs: prefs).freeSlots(on: F.monday, events: [allDay, free])
        XCTAssertEqual(slots.count, 3)
        XCTAssertEqual(minutes(slots[0]).0, 480)
    }

    func testRestDaysHaveNoSlots() {
        var p = prefs
        p.restDays = [1] // Sunday
        let days = FreeSlotFinder(prefs: p).freeSlots(from: F.date(2026, 10, 10), to: F.date(2026, 10, 12), events: [])
        XCTAssertEqual(days.count, 2)
        XCTAssertTrue(days[0].isWorkDay)
        XCTAssertFalse(days[1].isWorkDay)
        XCTAssertTrue(days[1].slots.isEmpty)
    }

    func testClipsToStartAndRoundsToFiveMinutes() {
        let finder = FreeSlotFinder(prefs: prefs)
        let days = finder.freeSlots(from: F.date(2026, 10, 5, 10, 2), to: F.date(2026, 10, 6), events: [])
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(minutes(days[0].slots[0]).0, 10 * 60 + 5)
    }

    func testOverlappingEventsMerge() {
        let a = F.event("A", F.date(2026, 10, 5, 9), F.date(2026, 10, 5, 10))
        let b = F.event("B", F.date(2026, 10, 5, 9, 30), F.date(2026, 10, 5, 11))
        let slots = FreeSlotFinder(prefs: prefs).freeSlots(on: F.monday, events: [a, b])
        XCTAssertEqual(minutes(slots[0]).1, 8 * 60 + 50)
        XCTAssertEqual(minutes(slots[1]).0, 11 * 60 + 10)
    }

    func testDSTAutumnKeepsWallClockHours() {
        // Clocks go back at 02:00 on Sunday 25 October 2026.
        let finder = FreeSlotFinder(prefs: prefs)
        let days = finder.freeSlots(from: F.date(2026, 10, 24), to: F.date(2026, 10, 27), events: [])
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days.map(\.totalMinutes), [days[0].totalMinutes, days[0].totalMinutes, days[0].totalMinutes])
        for d in days { XCTAssertEqual(F.cal.minuteOfDay(d.slots[0].start), 480) }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.hour, from: days[0].slots[0].start), 7) // BST
        XCTAssertEqual(utc.component(.hour, from: days[1].slots[0].start), 8) // GMT
        // The DST day itself is 25 hours long.
        XCTAssertEqual(F.cal.endOfDay(days[1].day).timeIntervalSince(days[1].day), 25 * 3600)
    }

    func testDSTSpring() {
        // Clocks go forward on Sunday 29 March 2026.
        let slots = FreeSlotFinder(prefs: prefs).freeSlots(on: F.date(2026, 3, 29, 12), events: [])
        XCTAssertEqual(minutes(slots[0]).0, 480)
        XCTAssertEqual(slots.reduce(0) { $0 + Int($1.duration / 60) }, 270 + 315 + 105)
    }

    func testWorkCutoffEndsTheDay() {
        var p = prefs
        p.workCutoff = 17 * 60
        let slots = FreeSlotFinder(prefs: p).freeSlots(on: F.monday, events: [])
        XCTAssertEqual(minutes(slots.last!).1, 17 * 60)
    }
}

final class SchedScorerTests: XCTestCase {
    typealias F = SchedFixtures
    let now = SchedFixtures.date(2026, 10, 5, 9)

    func testCloserDeadlineScoresHigher() {
        let s = TaskScorer()
        let soon = s.score(F.task("a", deadline: F.date(2026, 10, 6, 17)), now: now).total
        let later = s.score(F.task("b", deadline: F.date(2026, 10, 20, 17)), now: now).total
        let none = s.score(F.task("c"), now: now).total
        XCTAssertGreaterThan(soon, later)
        XCTAssertGreaterThan(later, none)
    }

    func testMoreRemainingWorkIsMoreUrgent() {
        let s = TaskScorer()
        let small = s.score(F.task("a", minutes: 30, deadline: F.date(2026, 10, 8)), now: now).total
        let big = s.score(F.task("b", minutes: 600, deadline: F.date(2026, 10, 8)), now: now).total
        XCTAssertGreaterThan(big, small)
    }

    func testOverdueBoost() {
        let s = TaskScorer()
        let overdue = s.score(F.task("a", deadline: F.date(2026, 10, 4)), now: now)
        let tomorrow = s.score(F.task("b", minutes: 600, deadline: F.date(2026, 10, 6)), now: now)
        XCTAssertTrue(overdue.isOverdue)
        XCTAssertGreaterThan(overdue.total, tomorrow.total)
    }

    func testAssessmentWeightAndPriority() {
        var weighted = F.task("a", deadline: F.date(2026, 10, 12))
        weighted.assessmentID = "essay1"
        let plain = F.task("b", deadline: F.date(2026, 10, 12))
        let s = TaskScorer(assessmentWeights: ["essay1": 50])
        XCTAssertEqual(s.score(weighted, now: now).weightFactor, 2, accuracy: 0.001)
        XCTAssertGreaterThan(s.score(weighted, now: now).total, s.score(plain, now: now).total)

        let lookup = TaskScorer(weightLookup: { $0 == "essay1" ? 100 : nil })
        XCTAssertEqual(lookup.score(weighted, now: now).weightFactor, 3, accuracy: 0.001)

        let high = s.score(F.task("c", deadline: F.date(2026, 10, 12), priority: .high), now: now).total
        let low = s.score(F.task("d", deadline: F.date(2026, 10, 12), priority: .low), now: now).total
        XCTAssertGreaterThan(high, s.score(plain, now: now).total)
        XCTAssertLessThan(low, s.score(plain, now: now).total)
    }

    func testRankIsDeterministic() {
        let tasks = (0..<5).map { F.task("t\($0)", index: $0) }
        let s = TaskScorer()
        XCTAssertEqual(s.rank(tasks, now: now).map(\.id), s.rank(tasks.reversed(), now: now).map(\.id))
    }
}
