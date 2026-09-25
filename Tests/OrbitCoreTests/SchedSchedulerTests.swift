import XCTest
@testable import OrbitCore

final class SchedSchedulerTests: XCTestCase {
    typealias F = SchedFixtures
    let prefs = UserPrefs()
    let now = SchedFixtures.date(2026, 10, 5, 8) // Monday 08:00

    func newBlocks(_ plan: SchedulePlan, _ existing: [ScheduledBlock] = []) -> [ScheduledBlock] {
        let ids = Set(existing.map(\.id))
        return plan.blocks.filter { !ids.contains($0.id) }
    }

    func assertInvariants(_ plan: SchedulePlan, tasks: [OrbitTask], events: [CalendarEvent] = [],
                          prefs: UserPrefs? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let p = prefs ?? self.prefs
        let blocks = plan.blocks.sorted { $0.start < $1.start }
        for b in blocks {
            XCTAssertGreaterThanOrEqual(b.start, now, "block before now", file: file, line: line)
            XCTAssertEqual(Int(b.start.timeIntervalSince1970) % 300, 0, "start not on 5 min", file: file, line: line)
            let m = F.cal.minuteOfDay(b.start)
            XCTAssertGreaterThanOrEqual(m, p.dayStart, file: file, line: line)
            XCTAssertLessThanOrEqual(F.cal.minuteOfDay(b.end), p.workCutoff, file: file, line: line)
            if let t = tasks.first(where: { $0.id == b.taskID }) {
                XCTAssertLessThanOrEqual(b.minutes, t.maxBlockMinutes, file: file, line: line)
                if let e = t.earliestStart { XCTAssertGreaterThanOrEqual(b.start, e, file: file, line: line) }
            }
            for e in events where e.isBusy && !e.isAllDay {
                let padded = DateInterval(start: e.start.addingTimeInterval(-Double(p.bufferMinutes) * 60),
                                          end: e.end.addingTimeInterval(Double(p.bufferMinutes) * 60))
                XCTAssertFalse(padded.intersects(DateInterval(start: b.start, end: b.end)) &&
                               padded.end != b.start && padded.start != b.end,
                               "block \(b.title) overlaps \(e.title)", file: file, line: line)
            }
        }
        // Buffers between consecutive blocks.
        for (a, b) in zip(blocks, blocks.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.start.timeIntervalSince(a.end), Double(p.bufferMinutes) * 60,
                                        "no break between \(a.title) and \(b.title)", file: file, line: line)
        }
        // Daily focus cap.
        let byDay = Dictionary(grouping: blocks) { F.cal.startOfDay($0.start) }
        for (_, list) in byDay {
            XCTAssertLessThanOrEqual(list.reduce(0) { $0 + $1.minutes }, p.maxFocusMinutesPerDay, file: file, line: line)
        }
    }

    func testSmallTaskGoesInSoonestSlot() {
        let t = F.task("Read ch3", minutes: 60, deadline: F.date(2026, 10, 9, 17))
        let plan = Scheduler(prefs: prefs).plan(tasks: [t], events: [], now: now)
        XCTAssertEqual(plan.blocks.count, 1)
        let b = plan.blocks[0]
        XCTAssertEqual(b.start, F.date(2026, 10, 5, 8))
        XCTAssertEqual(b.minutes, 60)
        XCTAssertEqual(b.id, Scheduler.blockID(taskID: t.id, start: b.start))
        XCTAssertTrue(plan.warnings.isEmpty)
        XCTAssertTrue(plan.unscheduled.isEmpty)
        assertInvariants(plan, tasks: [t])
    }

    func testNeverBeforeNowOrEarliestStart() {
        let later = F.date(2026, 10, 5, 10, 3)
        let t1 = F.task("A", minutes: 30, index: 1)
        let t2 = F.task("B", minutes: 30, earliestStart: F.date(2026, 10, 7, 14), index: 2)
        let plan = Scheduler(prefs: prefs).plan(tasks: [t1, t2], events: [], now: later)
        let a = plan.blocks(for: t1.id)[0], b = plan.blocks(for: t2.id)[0]
        XCTAssertEqual(a.start, F.date(2026, 10, 5, 10, 5))
        XCTAssertGreaterThanOrEqual(b.start, F.date(2026, 10, 7, 14))
    }

    func testAvoidsEventsAndBuffers() {
        let events = [
            F.event("Lecture", F.date(2026, 10, 5, 8), F.date(2026, 10, 5, 12)),
            F.event("Seminar", F.date(2026, 10, 5, 14), F.date(2026, 10, 5, 15)),
        ]
        let tasks = [F.task("A", minutes: 60, deadline: F.date(2026, 10, 6), index: 1),
                     F.task("B", minutes: 60, deadline: F.date(2026, 10, 6), index: 2)]
        let plan = Scheduler(prefs: prefs).plan(tasks: tasks, events: events, now: now)
        XCTAssertEqual(plan.totalMinutes, 120)
        assertInvariants(plan, tasks: tasks, events: events)
        // 12:10–12:30 is too short (min block 25), so the first block starts after lunch.
        XCTAssertEqual(plan.blocks.map(\.start).min(), F.date(2026, 10, 5, 13, 15))
    }

    func testLargeTaskIsSplitAndSpreadAcrossDays() {
        let t = F.task("Essay", minutes: 360, deadline: F.date(2026, 10, 15, 17), minBlock: 30, maxBlock: 90)
        let plan = Scheduler(prefs: prefs).plan(tasks: [t], events: [], now: now)
        XCTAssertEqual(plan.minutes(for: t.id), 360)
        for b in plan.blocks { XCTAssertTrue((30...90).contains(b.minutes)) }
        let days = Set(plan.blocks.map { F.cal.startOfDay($0.start) })
        XCTAssertGreaterThanOrEqual(days.count, 4, "should spread, not cram")
        XCTAssertLessThanOrEqual(plan.blocks.map(\.end).max()!, t.deadline!)
        // Not all piled on the first day or the last day.
        XCTAssertFalse(days.contains(F.cal.startOfDay(t.deadline!)) && days.count == 1)
        assertInvariants(plan, tasks: [t])
    }

    func testRespectsDailyFocusCap() {
        var p = prefs
        p.maxFocusMinutesPerDay = 120
        let tasks = (0..<5).map { F.task("T\($0)", minutes: 120, deadline: F.date(2026, 10, 16), index: $0) }
        let plan = Scheduler(prefs: p).plan(tasks: tasks, events: [], now: now)
        XCTAssertEqual(plan.totalMinutes, 600)
        assertInvariants(plan, tasks: tasks, prefs: p)
    }

    func testHighEnergyTaskUsesHighEnergyWindow() {
        let hard = F.task("Problem sheet", minutes: 90, deadline: F.date(2026, 10, 6), energy: .high, index: 1)
        let easy = F.task("Admin", minutes: 30, deadline: F.date(2026, 10, 6), energy: .low, index: 2)
        let plan = Scheduler(prefs: prefs).plan(tasks: [hard, easy], events: [], now: now)
        let h = plan.blocks(for: hard.id)[0], e = plan.blocks(for: easy.id)[0]
        XCTAssertEqual(prefs.energy(at: F.cal.minuteOfDay(h.start)), .high)
        XCTAssertLessThanOrEqual(F.cal.minuteOfDay(h.end), 12 * 60 + 30)
        XCTAssertEqual(prefs.energy(at: F.cal.minuteOfDay(e.start)), .low)
    }

    func testLocalImprovementSwapsForBetterEnergy() {
        // Urgent low-energy task grabs the morning first; the swap pass gives the
        // high-energy slot to the deep-work task on the same day.
        var p = prefs
        p.energyWindows = [EnergyWindow(start: 8 * 60, end: 10 * 60, energy: .high),
                           EnergyWindow(start: 10 * 60, end: 22 * 60, energy: .low)]
        let restricted = OrbitTask(id: F.uuid(1), title: "Emails", estimateMinutes: 60,
                                   deadline: F.date(2026, 10, 5, 10, 30), priority: .critical, energy: .low,
                                   createdAt: F.date(2026, 9, 1))
        let deep = F.task("Essay", minutes: 60, deadline: F.date(2026, 10, 5, 21), energy: .high, index: 2)
        let plan = Scheduler(prefs: p).plan(tasks: [restricted, deep], events: [], now: now)
        // The deadline pins "Emails" to the morning, so no swap is allowed there.
        XCTAssertLessThanOrEqual(plan.blocks(for: restricted.id)[0].end, restricted.deadline!)
        XCTAssertEqual(plan.totalMinutes, 120)
    }

    func testWontFitBeforeDeadlineStillSchedules() {
        let t = F.task("Report", minutes: 600, deadline: F.date(2026, 10, 5, 17))
        let plan = Scheduler(prefs: prefs).plan(tasks: [t], events: [], now: now)
        XCTAssertEqual(plan.minutes(for: t.id), 600)
        XCTAssertTrue(plan.warnings.contains { $0.contains("won't fit before deadline") })
        XCTAssertTrue(plan.blocks.contains { $0.end > t.deadline! })
        XCTAssertTrue(plan.unscheduled.isEmpty)
    }

    func testDeterministic() {
        let tasks = [F.task("Essay", minutes: 300, deadline: F.date(2026, 10, 14), energy: .high, index: 1),
                     F.task("Reading", minutes: 90, deadline: F.date(2026, 10, 7), index: 2),
                     F.task("Laundry", minutes: 30, energy: .low, index: 3)]
        let events = [F.event("Lecture", F.date(2026, 10, 6, 9), F.date(2026, 10, 6, 11))]
        let s = Scheduler(prefs: prefs)
        let a = s.plan(tasks: tasks, events: events, now: now)
        let b = s.plan(tasks: tasks.reversed(), events: events, now: now)
        XCTAssertEqual(a, b)
        assertInvariants(a, tasks: tasks, events: events)
    }

    func testLockedBlocksKeptAndCountTowardsTask() {
        let t = F.task("Essay", minutes: 120, deadline: F.date(2026, 10, 9))
        let locked = ScheduledBlock(taskID: t.id, title: "Essay", start: F.date(2026, 10, 6, 14),
                                    end: F.date(2026, 10, 6, 15), locked: true)
        let plan = Scheduler(prefs: prefs).plan(tasks: [t], events: [], existingBlocks: [locked], now: now)
        XCTAssertTrue(plan.blocks.contains(locked))
        XCTAssertEqual(newBlocks(plan, [locked]).reduce(0) { $0 + $1.minutes }, 60)
        for b in newBlocks(plan, [locked]) {
            XCTAssertFalse(DateInterval(start: b.start, end: b.end).intersects(DateInterval(start: locked.start, end: locked.end)))
        }
    }

    func testMissedBlockIsRescheduledWithWarning() {
        let t = F.task("Revise stats", minutes: 60, deadline: F.date(2026, 10, 9))
        let missed = ScheduledBlock(taskID: t.id, title: "Revise stats", start: F.date(2026, 10, 4, 10),
                                    end: F.date(2026, 10, 4, 11))
        let plan = Scheduler(prefs: prefs).plan(tasks: [t], events: [], existingBlocks: [missed], now: now)
        XCTAssertEqual(plan.missedBlockIDs, [missed.id])
        XCTAssertTrue(plan.warnings.contains { $0.contains("Rescheduled") })
        XCTAssertEqual(newBlocks(plan, [missed]).reduce(0) { $0 + $1.minutes }, 60)
        XCTAssertTrue(plan.blocks.contains(missed), "past blocks are kept")
    }

    func testCompletedPastBlockIsNotMissed() {
        let t = F.task("Revise stats", minutes: 120, deadline: F.date(2026, 10, 9), done: 60)
        let past = ScheduledBlock(taskID: t.id, title: "Revise stats", start: F.date(2026, 10, 4, 10),
                                  end: F.date(2026, 10, 4, 11))
        let plan = Scheduler(prefs: prefs).plan(tasks: [t], events: [], existingBlocks: [past], now: now)
        XCTAssertTrue(plan.missedBlockIDs.isEmpty)
        XCTAssertFalse(plan.warnings.contains { $0.contains("Rescheduled") })
        XCTAssertEqual(newBlocks(plan, [past]).reduce(0) { $0 + $1.minutes }, 60)

        let ticked = MissedBlockDetector.missedBlocks([past], tasks: [F.task("Revise stats")],
                                                      completedBlockIDs: [past.id], now: now)
        XCTAssertTrue(ticked.isEmpty)
    }

    func testRestDaysAreSkipped() {
        var p = prefs
        p.restDays = [1, 7]
        p.maxFocusMinutesPerDay = 60
        let t = F.task("Project", minutes: 600, deadline: F.date(2026, 10, 19), maxBlock: 60)
        let plan = Scheduler(prefs: p).plan(tasks: [t], events: [], now: now)
        for b in plan.blocks { XCTAssertFalse(p.restDays.contains(F.cal.weekday(b.start))) }
    }

    func testUnschedulableWorkIsReported() {
        let t = F.task("Dissertation", minutes: 3000, deadline: nil)
        let plan = Scheduler(prefs: prefs, horizonDays: 2).plan(tasks: [t], events: [], now: now)
        XCTAssertEqual(plan.unscheduled.count, 1)
        XCTAssertEqual(plan.unscheduled[0].minutesMissing, 3000 - plan.minutes(for: t.id))
        XCTAssertGreaterThan(plan.unscheduled[0].minutesMissing, 0)
    }

    func testOverdueTaskScheduledFirstWithWarning() {
        let overdue = F.task("Late form", minutes: 30, deadline: F.date(2026, 10, 2), index: 1)
        let other = F.task("Reading", minutes: 30, deadline: F.date(2026, 10, 12), index: 2)
        let plan = Scheduler(prefs: prefs).plan(tasks: [other, overdue], events: [], now: now)
        XCTAssertLessThan(plan.blocks(for: overdue.id)[0].start, plan.blocks(for: other.id)[0].start)
        XCTAssertTrue(plan.warnings.contains { $0.contains("overdue") })
    }

    func testHigherPriorityWinsScarceTime() {
        var p = prefs
        p.maxFocusMinutesPerDay = 60
        let low = F.task("Low", minutes: 60, deadline: F.date(2026, 10, 5, 21), priority: .low, index: 1)
        let high = F.task("High", minutes: 60, deadline: F.date(2026, 10, 5, 21), priority: .high, index: 2)
        let plan = Scheduler(prefs: p, horizonDays: 1).plan(tasks: [low, high], events: [], now: now)
        XCTAssertEqual(plan.minutes(for: high.id), 60)
        XCTAssertEqual(plan.minutes(for: low.id), 0)
        XCTAssertEqual(plan.unscheduled.map(\.task.id), [low.id])
    }

    func testDeadlineBeyondHorizonGetsFairShare() {
        let t = F.task("Dissertation", minutes: 2800, deadline: F.date(2026, 12, 14), maxBlock: 120)
        let plan = Scheduler(prefs: prefs, horizonDays: 14).plan(tasks: [t], events: [], now: now)
        let planned = plan.minutes(for: t.id)
        XCTAssertGreaterThan(planned, 0)
        XCTAssertLessThan(planned, 2800 / 2)
        XCTAssertTrue(plan.unscheduled.isEmpty)
    }

    func testDSTWeekPlanStaysOnWallClock() {
        let t = F.task("Essay", minutes: 60, earliestStart: F.date(2026, 10, 25, 8))
        let plan = Scheduler(prefs: prefs).plan(tasks: [t], events: [], now: F.date(2026, 10, 24, 22))
        XCTAssertEqual(plan.blocks[0].start, F.date(2026, 10, 25, 8))
        XCTAssertEqual(F.cal.minuteOfDay(plan.blocks[0].start), 480)
    }

    func testPlanIsCodable() throws {
        let t = F.task("Essay", minutes: 30000, deadline: F.date(2026, 10, 6))
        let plan = Scheduler(prefs: prefs).plan(tasks: [t], events: [], now: now)
        let data = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(SchedulePlan.self, from: data), plan)
    }
}
