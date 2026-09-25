import XCTest
@testable import OrbitCore

final class SchedReplannerTests: XCTestCase {
    typealias F = SchedFixtures
    let prefs = UserPrefs()
    let now = SchedFixtures.date(2026, 10, 5, 8)

    var tasks: [OrbitTask] {
        [F.task("Essay", minutes: 240, deadline: F.date(2026, 10, 12), energy: .high, index: 1),
         F.task("Reading", minutes: 60, deadline: F.date(2026, 10, 7), index: 2)]
    }

    func withExternalIDs(_ blocks: [ScheduledBlock]) -> [ScheduledBlock] {
        blocks.enumerated().map { i, b in var b = b; b.externalEventID = "evt\(i)"; return b }
    }

    func testReplanWithNoChangesIsEmpty() {
        let r = Replanner(prefs: prefs)
        let first = r.replan(tasks: tasks, events: [], current: [], now: now)
        XCTAssertEqual(first.changes.create.count, first.plan.blocks.count)
        let current = withExternalIDs(first.plan.blocks)
        let second = r.replan(tasks: tasks, events: [], current: current, now: now)
        XCTAssertTrue(second.changes.isEmpty)
        XCTAssertEqual(second.plan.blocks.map(\.id), current.map(\.id))
        XCTAssertEqual(second.plan.blocks.map(\.externalEventID), current.map(\.externalEventID))
    }

    func testCompletedTaskBlocksAreDeleted() {
        let r = Replanner(prefs: prefs)
        let current = withExternalIDs(r.replan(tasks: tasks, events: [], current: [], now: now).plan.blocks)
        var updated = tasks
        updated[1].completedAt = now
        let res = r.replan(tasks: updated, events: [], current: current, now: now)
        XCTAssertFalse(res.changes.delete.isEmpty)
        XCTAssertTrue(res.changes.delete.allSatisfy { $0.taskID == updated[1].id })
        XCTAssertTrue(res.changes.create.isEmpty)
        XCTAssertFalse(res.plan.blocks.contains { $0.taskID == updated[1].id })
    }

    func testMovedBlockKeepsIDAndExternalEvent() {
        let r = Replanner(prefs: prefs)
        let current = withExternalIDs(r.replan(tasks: tasks, events: [], current: [], now: now).plan.blocks)
        // A new lecture lands on top of the Reading block.
        let reading = current.first { $0.taskID == tasks[1].id }!
        let clash = F.event("New lecture", reading.start, reading.end)
        let res = r.replan(tasks: tasks, events: [clash], current: current, now: now)
        let moved = res.plan.blocks.first { $0.taskID == tasks[1].id }!
        XCTAssertEqual(moved.id, reading.id)
        XCTAssertEqual(moved.externalEventID, reading.externalEventID)
        XCTAssertNotEqual(moved.start, reading.start)
        XCTAssertTrue(res.changes.update.contains { $0.id == reading.id })
        XCTAssertTrue(res.changes.create.isEmpty)
        XCTAssertTrue(res.changes.delete.isEmpty)
    }

    func testLockedAndPastBlocksAreNeverTouched() {
        let t = tasks
        let past = ScheduledBlock(taskID: t[0].id, title: "Essay", start: F.date(2026, 10, 4, 10),
                                  end: F.date(2026, 10, 4, 11), externalEventID: "past")
        let locked = ScheduledBlock(taskID: t[0].id, title: "Essay", start: F.date(2026, 10, 8, 10),
                                    end: F.date(2026, 10, 8, 11), externalEventID: "locked", locked: true)
        var done = t
        done[0].completedAt = now // even when the task is finished
        let res = Replanner(prefs: prefs).replan(tasks: done, events: [], current: [past, locked],
                                                 completedBlockIDs: [past.id], now: now)
        XCTAssertTrue(res.changes.delete.isEmpty)
        XCTAssertTrue(res.changes.unchanged.contains(past))
        XCTAssertTrue(res.changes.unchanged.contains(locked))
        XCTAssertTrue(res.plan.blocks.contains(past) && res.plan.blocks.contains(locked))
    }

    func testDiffCreatesUpdatesDeletes() {
        let a = F.uuid(1), b = F.uuid(2), c = F.uuid(3)
        let old = [
            ScheduledBlock(id: F.uuid(10), taskID: a, title: "A", start: F.date(2026, 10, 5, 9), end: F.date(2026, 10, 5, 10), externalEventID: "e1"),
            ScheduledBlock(id: F.uuid(11), taskID: b, title: "B", start: F.date(2026, 10, 5, 11), end: F.date(2026, 10, 5, 12), externalEventID: "e2"),
        ]
        let new = [
            ScheduledBlock(id: F.uuid(20), taskID: a, title: "A", start: F.date(2026, 10, 5, 9), end: F.date(2026, 10, 5, 10)),
            ScheduledBlock(id: F.uuid(21), taskID: c, title: "C", start: F.date(2026, 10, 5, 11), end: F.date(2026, 10, 5, 12)),
        ]
        let (blocks, changes) = Replanner.diff(old: old, new: new, now: now)
        XCTAssertEqual(changes.unchanged.map(\.id), [F.uuid(10)])
        XCTAssertEqual(changes.create.map(\.taskID), [c])
        XCTAssertEqual(changes.delete.map(\.id), [F.uuid(11)])
        XCTAssertEqual(blocks.first { $0.taskID == a }?.externalEventID, "e1")
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count)
    }

    func testLightenPushesWorkToLaterDays() {
        let t = [F.task("Essay", minutes: 480, deadline: F.date(2026, 10, 9, 17), index: 1),
                 F.task("Stats", minutes: 240, deadline: F.date(2026, 10, 9, 17), index: 2)]
        let r = Replanner(prefs: prefs)
        let current = withExternalIDs(r.replan(tasks: t, events: [], current: [], now: now).plan.blocks)
        let tuesday = F.date(2026, 10, 6)
        let before = current.filter { F.cal.isSameDay($0.start, tuesday) }.reduce(0) { $0 + $1.minutes }
        XCTAssertGreaterThan(before, 0)

        let res = r.lighten(day: tuesday, by: 0.5, tasks: t, events: [], current: current, now: now)
        let after = res.plan.blocks.filter { F.cal.isSameDay($0.start, tuesday) }.reduce(0) { $0 + $1.minutes }
        XCTAssertLessThanOrEqual(after, before / 2)
        XCTAssertEqual(res.plan.totalMinutes, current.reduce(0) { $0 + $1.minutes }, "work moved, not dropped")
        // Monday is untouched.
        let mondayBefore = current.filter { F.cal.isSameDay($0.start, now) }
        let mondayAfter = res.plan.blocks.filter { F.cal.isSameDay($0.start, now) }
        XCTAssertEqual(mondayBefore, mondayAfter)
        // Moved work lands later in the week.
        let laterBefore = current.filter { $0.start >= F.date(2026, 10, 7) }.reduce(0) { $0 + $1.minutes }
        let laterAfter = res.plan.blocks.filter { $0.start >= F.date(2026, 10, 7) }.reduce(0) { $0 + $1.minutes }
        XCTAssertEqual(laterAfter - laterBefore, before - after)
        XCTAssertTrue(res.plan.warnings.contains { $0.contains("Lightened") })
        XCTAssertFalse(res.plan.blocks.contains { $0.locked })
        XCTAssertFalse(res.changes.isEmpty)
    }
}
