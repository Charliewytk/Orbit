import XCTest
@testable import OrbitCore

final class DeferralAdvisorTests: XCTestCase {
    typealias F = SchedFixtures
    let advisor = DeferralAdvisor(prefs: UserPrefs())

    /// Monday 5 Oct 2026, 10:00.
    var now: Date { F.date(2026, 10, 5, 10) }

    func item(minutes: Int = 60, remaining: Int = 60, deadline: Date? = nil, origin: TaskOrigin = .yours,
              moved: Int = 0) -> DeferralItem {
        let history = (0..<moved).map { i in
            DeferralRecord(movedAt: F.date(2026, 10, 1 + i, 9), from: nil, to: F.date(2026, 10, 2 + i, 9))
        }
        return DeferralItem(title: "Essay plan", blockMinutes: minutes, remainingMinutes: remaining,
                            deadline: deadline, origin: origin, currentStart: now, history: history)
    }

    func testSimpleMoveIsFine() {
        let a = advisor.assess(item(), to: F.date(2026, 10, 6, 10), now: now, events: [])
        XCTAssertEqual(a.level, .ok)
        XCTAssertTrue(a.messages.isEmpty)
        XCTAssertNil(a.suggestion)
    }

    func testOptionsOfferHourEveningTomorrow() {
        let options = advisor.options(for: item(), now: now, events: [])
        let kinds = options.map(\.kind)
        XCTAssertEqual(Array(kinds.prefix(3)), [.inAnHour, .thisEvening, .tomorrow])
        XCTAssertEqual(options[0].start, F.date(2026, 10, 5, 11))
        XCTAssertEqual(options[1].start, F.date(2026, 10, 5, 19, 15))
        XCTAssertEqual(options[2].start, F.date(2026, 10, 6, 8))
        XCTAssertEqual(options[2].label, "Tomorrow 08:00")
    }

    func testMovedThreeTimesWarns() {
        let a = advisor.assess(item(moved: 3), to: F.date(2026, 10, 6, 10), now: now, events: [])
        XCTAssertEqual(a.level, .caution)
        XCTAssertEqual(a.headline, "You've moved this 3 times")
    }

    func testRequiredPushesBackHarderAfterTwoMoves() {
        let a = advisor.assess(item(origin: .required, moved: 2), to: F.date(2026, 10, 6, 10), now: now, events: [])
        XCTAssertEqual(a.level, .resist)
        XCTAssertEqual(a.headline, "You've moved this 2 times")
        let mine = advisor.assess(item(moved: 2), to: F.date(2026, 10, 6, 10), now: now, events: [])
        XCTAssertEqual(mine.level, .ok)
    }

    func testDeadlineTightExplainsWorkLeft() throws {
        // Due tomorrow 17:00, 2h of work left, moving to tomorrow 15:00.
        let a = advisor.assess(item(minutes: 60, remaining: 120, deadline: F.date(2026, 10, 6, 17)),
                               to: F.date(2026, 10, 6, 15), now: now, events: [])
        XCTAssertEqual(a.level, .caution)
        XCTAssertTrue(try XCTUnwrap(a.headline).hasPrefix("Due tomorrow, 2h left of work"), a.headline ?? "")
        let better = try XCTUnwrap(a.suggestion)
        XCTAssertLessThan(better, F.date(2026, 10, 6, 15), "suggests earlier, from now")
        XCTAssertGreaterThanOrEqual(better, now)
    }

    func testRequiredDeadlineWorkResists() {
        let a = advisor.assess(item(minutes: 60, remaining: 120, deadline: F.date(2026, 10, 6, 17), origin: .required),
                               to: F.date(2026, 10, 6, 15), now: now, events: [])
        XCTAssertEqual(a.level, .resist)
    }

    func testAfterDeadlineResists() {
        let a = advisor.assess(item(deadline: F.date(2026, 10, 6, 9)), to: F.date(2026, 10, 7, 10), now: now, events: [])
        XCTAssertEqual(a.level, .resist)
        XCTAssertTrue(a.reasons.contains(.pastDeadline(deadline: F.date(2026, 10, 6, 9))))
    }

    func testFullDayWarnsAndSuggestsAnotherDay() throws {
        let tue = F.date(2026, 10, 6)
        let events = [F.event("Lectures", F.date(2026, 10, 6, 9), F.date(2026, 10, 6, 12, 30)),
                      F.event("Labs", F.date(2026, 10, 6, 13, 15), F.date(2026, 10, 6, 16)),
                      F.event("Society", F.date(2026, 10, 6, 16), F.date(2026, 10, 6, 17, 45))]
        let a = advisor.assess(item(minutes: 90), to: F.date(2026, 10, 6, 10), now: now, events: events)
        XCTAssertEqual(a.level, .caution)
        XCTAssertEqual(a.headline, "Tomorrow is full: 8h booked")
        let s = try XCTUnwrap(a.suggestion)
        XCTAssertFalse(F.cal.isSameDay(s, tue))
        XCTAssertEqual(advisor.bookedMinutes(on: tue, events: events), 8 * 60)
    }

    func testBusySlotWarns() {
        let events = [F.event("Seminar", F.date(2026, 10, 6, 10), F.date(2026, 10, 6, 11))]
        let a = advisor.assess(item(), to: F.date(2026, 10, 6, 10), now: now, events: events)
        XCTAssertEqual(a.level, .caution)
        XCTAssertEqual(a.headline, "You're busy at 10:00")
        XCTAssertNotNil(a.suggestion)
    }

    func testRecordTracksOverride() {
        let a = advisor.assess(item(moved: 3), to: F.date(2026, 10, 6, 10), now: now, events: [])
        let h = DeferralAdvisor.record([], from: now, to: a.target, now: now, assessment: a)
        XCTAssertEqual(h.count, 1)
        XCTAssertTrue(h[0].overrodeWarning)
    }
}
