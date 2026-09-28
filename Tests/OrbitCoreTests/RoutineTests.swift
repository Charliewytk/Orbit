import XCTest
@testable import OrbitCore

private typealias F = SchedFixtures

private func d(_ day: Int, _ h: Int, _ m: Int = 0) -> Date { F.date(2026, 10, day, h, m) }
private func lecture(_ title: String, _ s: Date, _ e: Date, location: String? = "Amory B316") -> CalendarEvent {
    CalendarEvent(id: title, title: title, start: s, end: e, location: location, source: .timetable)
}
private let prefs = UserPrefs()

final class RoutinePlacementTests: XCTestCase {
    let planner = RoutinePlanner(prefs: prefs)

    func testHollandHallDefaults() {
        let r = RoutineSettings.hollandHall
        XCTAssertEqual(r.wakeTime, 7 * 60 + 35)
        XCTAssertEqual(r.shutdownTime, 21 * 60 + 58)
        XCTAssertFalse(r.meals.first { $0.kind == .earlyContinental }!.enabled)
        XCTAssertFalse(r.pushRoutineToGoogle)
    }

    func testBreakfastAfterWakeAndGettingReady() {
        // Monday, nothing on: breakfast 07:55–08:40 (wake 07:35 + 20 min).
        let b = planner.blocks(on: d(5, 0), events: []).first { $0.kind == .breakfast }!
        XCTAssertEqual(b.start, d(5, 7, 55))
        XCTAssertEqual(b.end, d(5, 8, 40))
        XCTAssertEqual(b.window, DateInterval(start: d(5, 7, 30), end: d(5, 9, 30)))
        XCTAssertFalse(b.clashes)
    }

    func testBreakfastFitsBeforeNineOClockLectureWithTravel() {
        // 09:00 campus lecture: must leave the hall by 08:45, so breakfast can't run to 08:50.
        let ev = [lecture("BEE1022 Lecture", d(5, 9), d(5, 10))]
        let b = planner.blocks(on: d(5, 0), events: ev).first { $0.kind == .breakfast }!
        XCTAssertLessThanOrEqual(b.end, d(5, 8, 45))
        XCTAssertGreaterThanOrEqual(b.start, d(5, 7, 55))
    }

    func testBreakfastMovesAfterEarlyLecture() {
        // 08:00–09:00 lecture: no room before, so breakfast goes after it plus travel back (09:15 → 09:30 would be only 15 min).
        // The window closes 09:30, so it's flagged as clashing but placed with the least overlap.
        let ev = [lecture("BEM1011 Lecture", d(5, 8), d(5, 9))]
        let b = planner.blocks(on: d(5, 0), events: ev).first { $0.kind == .breakfast }!
        XCTAssertTrue(b.clashes)
        XCTAssertEqual(b.end, d(5, 9, 30))
    }

    func testDinnerAvoidsLateLectureWithTravel() {
        let ev = [lecture("BEE1024 Lecture", d(5, 17), d(5, 18))]
        let b = planner.blocks(on: d(5, 0), events: ev).first { $0.kind == .dinner }!
        XCTAssertEqual(b.start, d(5, 18, 15))
        XCTAssertEqual(b.end, d(5, 19))
        XCTAssertEqual(b.closesLine(calendar: F.cal), "Dinner closes 19:30")
    }

    func testEventAtHallNeedsNoTravel() {
        let ev = [lecture("Hall meeting", d(5, 17, 30), d(5, 18), location: "Holland Hall common room")]
        let b = planner.blocks(on: d(5, 0), events: ev).first { $0.kind == .dinner }!
        XCTAssertEqual(b.start, d(5, 18))
    }

    func testWeekendBrunchAndNoBreakfast() {
        let sat = planner.blocks(on: d(10, 0), events: [])
        XCTAssertNil(sat.first { $0.kind == .breakfast })
        XCTAssertNil(sat.first { $0.kind == .earlyContinental }) // off by default
        let brunch = sat.first { $0.kind == .brunch }!
        XCTAssertEqual(brunch.start, d(10, 11, 30))
        XCTAssertNotNil(sat.first { $0.kind == .dinner })
    }

    func testReadingShutdownAndSleep() {
        let blocks = planner.blocks(on: d(5, 0), events: [])
        let reading = blocks.first { $0.kind == .reading }!
        XCTAssertEqual(reading.start, d(5, 22))
        XCTAssertEqual(reading.minutes, 20)
        XCTAssertEqual(reading.title, "Read (book)")
        XCTAssertEqual(blocks.first { $0.kind == .shutdown }!.start, d(5, 21, 58))
        let sleep = blocks.first { $0.kind == .sleep }!
        XCTAssertEqual(sleep.start, d(5, 22, 30))
        XCTAssertEqual(sleep.end, d(6, 7, 35))
        XCTAssertTrue(planner.isSleeping(at: d(6, 3)))
        XCTAssertFalse(planner.isSleeping(at: d(6, 8)))
    }

    func testAdjustedPrefsStopWorkAtShutdownAndStartAfterWake() {
        let p = RoutineSettings.hollandHall.adjusted(UserPrefs(dayStart: 7 * 60, workCutoff: 23 * 60))
        XCTAssertEqual(p.workCutoff, 21 * 60 + 58)
        XCTAssertEqual(p.dayStart, 7 * 60 + 55)
        XCTAssertNil(p.dinner)
    }

    func testSchedulerKeepsRoutineFree() {
        var p = UserPrefs()
        p.routine = .hollandHall
        let now = d(5, 7)
        var sched = Scheduler(prefs: p.effectiveRoutine.adjusted(p), horizonDays: 1)
        sched.extraBusy = RoutinePlanner(prefs: p).busyIntervals(from: now, to: d(6, 0), events: [])
        let task = F.task("Essay", minutes: 600, deadline: d(5, 23), maxBlock: 120)
        let plan = sched.plan(tasks: [task], events: [], now: now)
        let routine = RoutinePlanner(prefs: p).blocks(on: d(5, 0), events: [])
        for b in plan.blocks {
            for r in routine { XCTAssertFalse(b.start < r.end && b.end > r.start, "\(b.start) overlaps \(r.title)") }
            XCTAssertLessThanOrEqual(b.end, d(5, 21, 58))
        }
    }

    func testMorningBriefRoutineLines() {
        let lines = MorningBrief.routineLines(prefs: prefs, events: [], day: d(5, 7))
        XCTAssertTrue(lines.contains { $0.hasPrefix("Hall meals: Breakfast 07:55") && $0.contains("serving until 09:30") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Sleep window tonight: 22:30–07:35") })
        XCTAssertTrue(lines.contains { $0.contains("shutdown 21:58") })
    }

    func testRoutineSettingsDecodeLeniently() throws {
        let json = #"{"enabled":true,"readingStart":1300}"#
        let r = try JSONDecoder().decode(RoutineSettings.self, from: Data(json.utf8))
        XCTAssertEqual(r.readingStart, 1300)
        XCTAssertEqual(r.meals.count, RoutineSettings.hollandHallMeals.count)
        // Old prefs without a routine still decode.
        let prefs = try JSONDecoder().decode(UserPrefs.self, from: JSONEncoder().encode(UserPrefs()))
        XCTAssertNil(prefs.routine)
        XCTAssertEqual(prefs.effectiveRoutine, .hollandHall)
    }
}

final class TravelTests: XCTestCase {
    let planner = RoutinePlanner(prefs: prefs)

    func testPlaces() {
        let t = TravelSettings()
        XCTAssertEqual(t.place(of: lecture("x", d(5, 9), d(5, 10))), .campus)
        XCTAssertEqual(t.place(of: lecture("x", d(5, 9), d(5, 10), location: "Holland Hall")), .home)
        XCTAssertEqual(t.place(of: CalendarEvent(title: "BEE1022 Lecture", start: d(5, 9), end: d(5, 10))), .campus)
        XCTAssertEqual(t.place(of: CalendarEvent(title: "Call mum", start: d(5, 9), end: d(5, 10))), .unknown)
    }

    func testTravelBuffersAroundCampusEventsAndWalkInShortGaps() {
        let ev = [lecture("A Lecture", d(5, 9), d(5, 10)), lecture("B Lecture", d(5, 11), d(5, 12)),
                  lecture("C Lecture", d(5, 16), d(5, 17))]
        let pads = planner.travelIntervals(events: ev)
        // Before A: 15 min travel; A→B gap 60 min ≤ 90: walking only; B→C gap 4 h: travel both ways.
        XCTAssertTrue(pads.contains(DateInterval(start: d(5, 8, 45), end: d(5, 9))))
        XCTAssertTrue(pads.contains(DateInterval(start: d(5, 10), end: d(5, 10, 5))))
        XCTAssertTrue(pads.contains(DateInterval(start: d(5, 10, 55), end: d(5, 11))))
        XCTAssertTrue(pads.contains(DateInterval(start: d(5, 12), end: d(5, 12, 15))))
        XCTAssertTrue(pads.contains(DateInterval(start: d(5, 15, 45), end: d(5, 16))))
    }

    func testLocationHint() {
        let ev = [lecture("A Lecture", d(5, 9), d(5, 10)), lecture("B Lecture", d(5, 11), d(5, 12))]
        XCTAssertEqual(planner.locationHint(for: DateInterval(start: d(5, 10, 10), end: d(5, 10, 35)), events: ev),
                       "Forum library (on campus)")
        XCTAssertEqual(planner.locationHint(for: DateInterval(start: d(5, 14), end: d(5, 15)), events: ev), "Holland Hall")
    }
}

final class TypeUpPlacementTests: XCTestCase {
    let planner = TypeUpPlanner(prefs: prefs)

    private func session(_ id: String, _ module: String, _ kind: TrackedLecture.SessionKind, _ s: Date, _ e: Date,
                         week: Int? = 3, location: String? = "Amory B316") -> TypeUpSession {
        TypeUpSession(id: id, moduleCode: module, kind: kind, week: week, start: s, end: e, location: location)
    }

    func testShortCampusGapTypesUpInLibraryRightAfter() {
        // 09–10 lecture, 11–12 seminar: type up in the library 10:05–10:30, no trip home.
        let s = session("a", "BEE1022", .lecture, d(5, 9), d(5, 10))
        let ev = [lecture("BEE1022 Lecture", d(5, 9), d(5, 10)), lecture("BEE1024 Seminar", d(5, 11), d(5, 12))]
        let b = planner.place(s, events: ev, busy: [], now: d(5, 8))!
        XCTAssertEqual(b.start, d(5, 10, 5))
        XCTAssertEqual(b.end, d(5, 10, 30))
        XCTAssertTrue(b.onCampus)
        XCTAssertEqual(b.locationHint, "Forum library (on campus)")
        XCTAssertEqual(b.title, "Type up BEE1022 Lecture notes")
    }

    func testTooShortGapGoesHomeLater() {
        // 09–10 then 10:20–11:20: no 25-min slot on campus, so after the second one + travel home.
        let s = session("a", "BEE1022", .tutorial, d(5, 9), d(5, 10))
        let ev = [lecture("BEE1022 Tutorial", d(5, 9), d(5, 10)), lecture("BEM1011 Lecture", d(5, 10, 20), d(5, 11, 20))]
        let b = planner.place(s, events: ev, busy: [], now: d(5, 8))!
        XCTAssertFalse(b.onCampus)
        XCTAssertGreaterThanOrEqual(b.start, d(5, 11, 35))
        XCTAssertEqual(b.title, "Type up BEE1022 Tutorial notes")
        XCTAssertEqual(b.locationHint, "Holland Hall")
    }

    func testBusyStudyBlockPushesItLater() {
        let s = session("a", "BEE1022", .lecture, d(5, 9), d(5, 10))
        let ev = [lecture("BEE1022 Lecture", d(5, 9), d(5, 10))]
        let b = planner.place(s, events: ev, busy: [DateInterval(start: d(5, 10), end: d(5, 11))], now: d(5, 8))!
        XCTAssertGreaterThanOrEqual(b.start, d(5, 11))
    }

    func testEveningLectureGoesToNextMorning() {
        // 20:00–21:30 lecture: nothing fits before the 21:58 shutdown, so next morning after breakfast.
        let s = session("late", "BEE1022", .lecture, d(5, 20), d(5, 21, 30))
        let ev = [lecture("BEE1022 Lecture", d(5, 20), d(5, 21, 30))]
        let b = planner.place(s, events: ev, busy: [], now: d(5, 21, 30))!
        XCTAssertTrue(F.cal.isSameDay(b.start, d(6, 0)))
        XCTAssertGreaterThanOrEqual(b.start, d(6, 7, 55))
        // Not inside breakfast.
        let breakfast = RoutinePlanner(prefs: prefs).blocks(on: d(6, 0), events: ev).first { $0.kind == .breakfast }!
        XCTAssertFalse(b.start < breakfast.end && b.end > breakfast.start)
    }

    func testEverySessionKindGetsOneAndStableIDs() {
        let ss = [session("a", "BEE1022", .lecture, d(5, 9), d(5, 10)),
                  session("b", "BEE1024", .tutorial, d(5, 13), d(5, 14)),
                  session("c", "BEM1011", .practical, d(5, 15), d(5, 16))]
        let ev = [lecture("BEE1022 Lecture", d(5, 9), d(5, 10)), lecture("BEE1024 Tutorial", d(5, 13), d(5, 14))]
        let blocks = planner.plan(sessions: ss, alreadyPlanned: [], events: ev, busy: [], now: d(5, 8))
        XCTAssertEqual(blocks.map(\.sessionID), ["a", "b"]) // practicals don't get one
        XCTAssertEqual(blocks[0].taskID, TypeUpPlanner.taskID(sessionID: "a"))
        XCTAssertFalse(blocks[0].interval.intersects(blocks[1].interval))
        XCTAssertTrue(planner.plan(sessions: ss, alreadyPlanned: ["a", "b"], events: ev, busy: [], now: d(5, 8)).isEmpty)
    }

    func testDoneWhenTypedNoteAppearsAndExpiresAfterThreeDays() {
        let s = session("a", "BEE1022", .lecture, d(5, 9), d(5, 10))
        let b = planner.place(s, events: [], busy: [], now: d(5, 8))!
        XCTAssertEqual(planner.status(of: b, sessionStart: s.start, typedNotes: [], now: d(5, 12)), .pending)
        let other = TypedNoteRef(moduleCode: "BEE1024", week: 3, modified: d(5, 11))
        XCTAssertEqual(planner.status(of: b, sessionStart: s.start, typedNotes: [other], now: d(5, 12)), .pending)
        let wrongWeek = TypedNoteRef(moduleCode: "BEE1022", week: 2, modified: d(5, 11))
        XCTAssertEqual(planner.status(of: b, sessionStart: s.start, typedNotes: [wrongWeek], now: d(5, 12)), .pending)
        let stale = TypedNoteRef(moduleCode: "BEE1022", week: 3, modified: d(4, 11))
        XCTAssertEqual(planner.status(of: b, sessionStart: s.start, typedNotes: [stale], now: d(5, 12)), .pending)
        let typed = TypedNoteRef(moduleCode: "bee1022", week: 3, modified: d(5, 11))
        XCTAssertEqual(planner.status(of: b, sessionStart: s.start, typedNotes: [typed], now: d(5, 12)), .done)
        XCTAssertEqual(planner.status(of: b, sessionStart: s.start, typedNotes: [], now: d(8, 12)), .expired)
    }

    func testDisabled() {
        var p = UserPrefs()
        var r = RoutineSettings.hollandHall
        r.typeUpEnabled = false
        p.routine = r
        let s = session("a", "BEE1022", .lecture, d(5, 9), d(5, 10))
        XCTAssertTrue(TypeUpPlanner(prefs: p).plan(sessions: [s], alreadyPlanned: [], events: [], busy: [], now: d(5, 8)).isEmpty)
    }
}

final class NudgeEngineTests: XCTestCase {
    let engine = NudgeEngine(calendar: F.cal)
    let routine = RoutinePlanner(prefs: prefs)

    func testFreeGapWithTaskDueTomorrow() {
        let now = d(5, 13)
        let task = OrbitTask(id: F.uuid(1), title: "Stats homework", estimateMinutes: 90, deadline: d(6, 12))
        let input = NudgeInput(now: now, events: [lecture("L", d(5, 15), d(5, 16))], tasks: [task],
                               routine: routine.blocks(on: now, events: []))
        let top = engine.evaluate(input).first!
        XCTAssertEqual(top.kind, .freeGap)
        XCTAssertEqual(top.body, "You've got 2 hours free and Stats homework is due tomorrow. Start it?")
        XCTAssertEqual(top.taskID, task.id)
        XCTAssertEqual(top.focusMinutes, 90)
    }

    func testNoGapNudgeWhenGapTooShort() {
        let now = d(5, 13)
        let task = OrbitTask(title: "Stats homework", deadline: d(6, 12))
        let input = NudgeInput(now: now, events: [lecture("L", d(5, 13, 30), d(5, 16))], tasks: [task])
        XCTAssertFalse(engine.evaluate(input).contains { $0.kind == .freeGap })
    }

    func testBlockStartingSoonAndTypeUpWithLocation() {
        let now = d(5, 10, 1)
        let blocks = [NudgeBlock(id: F.uuid(2), taskID: F.uuid(3), title: "Type up BEE1022 Lecture notes", start: d(5, 10, 5),
                                 end: d(5, 10, 30), isTypeUp: true, locationHint: "Forum library (on campus)")]
        let n = engine.evaluate(NudgeInput(now: now, blocks: blocks)).first!
        XCTAssertEqual(n.kind, .typeUp)
        XCTAssertTrue(n.body.contains("Forum library"))
        XCTAssertEqual(n.focusMinutes, 25)
    }

    func testDeadlineNoProgress() {
        let now = d(5, 14)
        let t = OrbitTask(id: F.uuid(4), title: "Problem set 3", deadline: d(6, 10))
        let kinds = engine.evaluate(NudgeInput(now: now, tasks: [t])).map(\.kind)
        XCTAssertTrue(kinds.contains(.deadlineNoProgress))
        var started = t
        started.minutesDone = 30
        XCTAssertFalse(engine.evaluate(NudgeInput(now: now, tasks: [started])).map(\.kind).contains(.deadlineNoProgress))
    }

    func testDinnerClosingInterruptsMealButOnlyIfNotTicked() {
        let r = routine.blocks(on: d(5, 0), events: [])
        let dinner = r.first { $0.kind == .dinner }!
        let now = d(5, 19, 5)
        var input = NudgeInput(now: now, routine: r)
        let n = engine.evaluate(input).first { $0.kind == .mealClosing }
        XCTAssertEqual(n?.title, "Dinner closes 19:30")
        input.routineDone = [dinner.id]
        XCTAssertNil(engine.evaluate(input).first { $0.kind == .mealClosing })
    }

    func testSuppressedDuringFocusLecturesMealsAndQuietHours() {
        let t = OrbitTask(title: "Problem set", deadline: d(6, 10))
        XCTAssertTrue(engine.evaluate(NudgeInput(now: d(5, 14), tasks: [t], focusActive: true)).isEmpty)
        XCTAssertTrue(engine.evaluate(NudgeInput(now: d(5, 14), events: [lecture("L", d(5, 13), d(5, 15))], tasks: [t])).isEmpty)
        XCTAssertTrue(engine.evaluate(NudgeInput(now: d(5, 8, 10), tasks: [t], routine: routine.blocks(on: d(5, 0), events: []))).isEmpty)
        XCTAssertTrue(engine.evaluate(NudgeInput(now: d(5, 23), tasks: [t])).isEmpty)
        XCTAssertTrue(engine.evaluate(NudgeInput(now: d(6, 7, 15), tasks: [t])).isEmpty)
        XCTAssertEqual(engine.suppression(NudgeInput(now: d(5, 23))), "quiet hours")
    }

    func testShutdownAndReadingBypassQuietHoursAndCap() {
        let r = routine.blocks(on: d(5, 0), events: [])
        let log = (0..<6).map { NudgeLogEntry(key: "x\($0)", kind: .freeGap, firedAt: d(5, 9 + $0)) }
        let shutdown = engine.evaluate(NudgeInput(now: d(5, 21, 58), routine: r, log: log))
        XCTAssertEqual(shutdown.first?.kind, .shutdown)
        XCTAssertEqual(shutdown.first?.title, "Shutdown time — 2 minutes")
        let reading = engine.evaluate(NudgeInput(now: d(5, 22, 0), routine: r, shutdownDoneToday: true, log: log))
        XCTAssertEqual(reading.first?.kind, .reading)
        XCTAssertTrue(engine.isQuietHours(d(5, 22, 0)))
    }

    func testDailyCapAndDedupeAndCooldownAndSpacing() {
        let now = d(5, 14)
        let t = OrbitTask(id: F.uuid(5), title: "Problem set", deadline: d(6, 10))
        // Cap: 6 already today.
        let full = (0..<6).map { NudgeLogEntry(key: "k\($0)", kind: .flashcardsDue, firedAt: d(5, 8 + $0)) }
        XCTAssertTrue(engine.evaluate(NudgeInput(now: now, tasks: [t], log: full)).isEmpty)
        // De-dup: the same key never twice.
        let key = "deadline:\(t.id.uuidString)"
        XCTAssertFalse(engine.evaluate(NudgeInput(now: now, tasks: [t], log: [NudgeLogEntry(key: key, kind: .deadlineNoProgress, firedAt: d(5, 9))]))
            .contains { $0.id == key })
        // Spacing: nothing within 20 minutes of the last nudge.
        XCTAssertTrue(engine.evaluate(NudgeInput(now: now, tasks: [t], log: [NudgeLogEntry(key: "other", kind: .flashcardsDue, firedAt: d(5, 13, 50))])).isEmpty)
        // Cooldown per kind: a different deadline nudge 1 h ago blocks this one (3 h cooldown).
        let recent = NudgeLogEntry(key: "deadline:other", kind: .deadlineNoProgress, firedAt: d(5, 13))
        XCTAssertFalse(engine.evaluate(NudgeInput(now: now, tasks: [t], log: [recent])).contains { $0.kind == .deadlineNoProgress })
    }

    func testSnoozeBringsItBackAfter30Minutes() {
        let t = OrbitTask(id: F.uuid(6), title: "Problem set", deadline: d(6, 10))
        let key = "deadline:\(t.id.uuidString)"
        let snoozed = NudgeLogEntry(key: key, kind: .deadlineNoProgress, firedAt: d(5, 14), snoozedUntil: d(5, 14, 30), action: .snooze30)
        XCTAssertFalse(engine.evaluate(NudgeInput(now: d(5, 14, 20), tasks: [t], log: [snoozed])).contains { $0.id == key })
        XCTAssertTrue(engine.evaluate(NudgeInput(now: d(5, 14, 35), tasks: [t], log: [snoozed])).contains { $0.id == key })
    }

    func testDisabledKindAndStreakAtRisk() {
        var e = engine
        let input = NudgeInput(now: d(5, 20, 35), streak: 12, todayCounts: false)
        XCTAssertEqual(e.evaluate(input).first?.kind, .streakAtRisk)
        e.settings.disabledKinds = [.streakAtRisk]
        XCTAssertTrue(e.evaluate(input).isEmpty)
        XCTAssertTrue(engine.evaluate(NudgeInput(now: d(5, 20, 35), streak: 12, todayCounts: true)).isEmpty)
    }

    func testPriorityOrder() {
        let now = d(5, 14)
        let t = OrbitTask(id: F.uuid(7), title: "Problem set", deadline: d(6, 10))
        let b = NudgeBlock(id: F.uuid(8), taskID: t.id, title: "Problem set", start: d(5, 14, 4), end: d(5, 15))
        let out = engine.evaluate(NudgeInput(now: now, blocks: [b], tasks: [t], flashcardsDue: 30))
        XCTAssertEqual(out.first?.kind, .blockStarting)
        XCTAssertEqual(out.last?.kind, .flashcardsDue)
    }
}

final class ShutdownTests: XCTestCase {
    let planner = ShutdownPlanner(prefs: prefs)

    func testReviewSplitsDoneAndNotDone() {
        let done = OrbitTask(id: F.uuid(1), title: "Done", completedAt: d(5, 15))
        let planned = OrbitTask(id: F.uuid(2), title: "Planned")
        let dueTonight = OrbitTask(id: F.uuid(3), title: "Due", deadline: d(5, 23))
        let later = OrbitTask(id: F.uuid(4), title: "Later", deadline: d(9, 12))
        let blocks = [ScheduledBlock(taskID: planned.id, title: "Planned", start: d(5, 10), end: d(5, 11))]
        let r = planner.review(tasks: [done, planned, dueTonight, later], blocks: blocks, on: d(5, 21))
        XCTAssertEqual(r.done.map(\.title), ["Done"])
        XCTAssertEqual(Set(r.notDone.map(\.title)), ["Planned", "Due"])
    }

    func testRolloverTomorrowMovesYourDeadlineButNotRequired() {
        let now = d(5, 21, 58)
        let mine = OrbitTask(title: "Call bank", deadline: d(5, 22), source: .manual)
        guard case let .moved(t, warning) = planner.apply(.tomorrow, to: mine, now: now) else { return XCTFail() }
        XCTAssertEqual(t.earliestStart, d(6, 8)) // max(prefs 08:00, wake + prep 07:55)
        XCTAssertEqual(t.deadline, d(6, 21, 0))
        XCTAssertNil(warning)

        let uni = OrbitTask(title: "Quiz", deadline: d(5, 23, 59), source: .ele)
        guard case let .moved(u, w) = planner.apply(.tomorrow, to: uni, now: now) else { return XCTFail() }
        XCTAssertEqual(u.deadline, d(5, 23, 59))
        XCTAssertNil(u.earliestStart)
        XCTAssertNotNil(w)
    }

    func testRolloverPickDayAndDrop() {
        let now = d(5, 21, 58)
        let t = OrbitTask(id: F.uuid(9), title: "Read ch. 4", deadline: d(12, 12))
        guard case let .moved(m, _) = planner.apply(.day(d(8, 15)), to: t, now: now) else { return XCTFail() }
        XCTAssertEqual(m.earliestStart, d(8, 8))
        XCTAssertEqual(m.deadline, d(12, 12))
        // A past day becomes tomorrow.
        guard case let .moved(p, _) = planner.apply(.day(d(1, 9)), to: t, now: now) else { return XCTFail() }
        XCTAssertEqual(p.earliestStart, d(6, 8))
        XCTAssertEqual(planner.apply(.drop, to: t, now: now), .dropped(t.id))
    }

    func testDueAndHistoryAndStreak() {
        XCTAssertFalse(planner.isDue(now: d(5, 21), history: []))
        XCTAssertTrue(planner.isDue(now: d(5, 21, 58), history: []))
        let rec = ShutdownRecord(id: "2026-10-05", completedAt: d(5, 22), doneCount: 3, rolledOver: 1, dropped: 0, journal: "Good day", streakAfter: 4)
        let h = planner.record(rec, into: [])
        XCTAssertFalse(planner.isDue(now: d(5, 22, 10), history: h))
        XCTAssertEqual(planner.record(rec, into: h).count, 1)
        // Shutdown alone keeps the streak.
        let days = DailyStatsBuilder.build(focus: [], completedBlocks: [], completedTasks: [], reviews: [:],
                                           timeZone: F.tz, shutdownDays: ["2026-10-04", "2026-10-05"])
        XCTAssertEqual(Momentum(days: days, goals: DailyGoals(), timeZone: F.tz).streak(now: d(5, 22)), 2)
    }

    func testFirstThingTomorrow() {
        let r = RoutinePlanner(prefs: prefs).blocks(from: d(6, 0), to: d(7, 0), events: [])
        let first = planner.firstThing(tomorrowOf: d(5, 22), events: [lecture("L", d(6, 9), d(6, 10))], blocks: [], routine: r)
        XCTAssertEqual(first?.title, "Breakfast")
        XCTAssertEqual(first?.start, d(6, 7, 55))
    }
}

final class BackupPlannerTests: XCTestCase {
    let planner = BackupPlanner(calendar: F.cal)

    func testNameRoundTrip() {
        let name = planner.fileName(for: d(5, 3))
        XCTAssertEqual(name, "Orbit Backup 2026-10-05 0300.zip")
        XCTAssertEqual(planner.parse(name)?.date, d(5, 3))
        XCTAssertNil(planner.parse("notes.zip"))
    }

    func testDueAtThreeOrOnNextLaunch() {
        XCTAssertTrue(planner.isDue(now: d(5, 3, 1), lastBackup: d(4, 3)))
        XCTAssertFalse(planner.isDue(now: d(5, 2), lastBackup: d(4, 3)))
        // Missed 03:00 (Mac asleep): due at the next launch that morning.
        XCTAssertTrue(planner.isDue(now: d(5, 9), lastBackup: d(4, 3)))
        XCTAssertFalse(planner.isDue(now: d(5, 9), lastBackup: d(5, 8)))
        XCTAssertTrue(planner.isDue(now: d(5, 9), lastBackup: nil))
    }

    func testRetentionKeeps14DailiesAnd8Weeklies() {
        // 120 days of nightly backups, plus an extra same-day one.
        var files = (0..<120).map { i -> BackupFile in
            let day = F.cal.addingDays(-i, to: d(5, 3))
            return BackupFile(name: planner.fileName(for: day), date: day)
        }
        files.append(BackupFile(name: planner.fileName(for: d(5, 12)), date: d(5, 12)))
        let delete = Set(planner.toDelete(files).map(\.name))
        let kept = files.filter { !delete.contains($0.name) }.sorted { $0.date > $1.date }
        XCTAssertEqual(kept.count, 22)
        XCTAssertEqual(kept.first?.date, d(5, 12)) // newest of today
        XCTAssertTrue(delete.contains(planner.fileName(for: d(5, 3))))
        // The 14 newest days are all there.
        let keptDays = Set(kept.map { F.cal.format($0.date, "yyyy-MM-dd") })
        for i in 0..<14 { XCTAssertTrue(keptDays.contains(F.cal.format(F.cal.addingDays(-i, to: d(5, 0)), "yyyy-MM-dd"))) }
        // Weeklies: one per week, each in a different week.
        let weeklies = kept.dropFirst(14)
        XCTAssertEqual(Set(weeklies.map { F.cal.startOfWeek($0.date) }).count, 8)
    }

    func testFewFilesKeepsEverything() {
        let files = (0..<5).map { BackupFile(name: "f\($0)", date: F.cal.addingDays(-$0, to: d(5, 3))) }
        XCTAssertTrue(planner.toDelete(files).isEmpty)
    }

    func testDestination() {
        let home = "/Users/charlie"
        let g = BackupPlanner.destination(home: home, cloudStorage: ["OneDrive-Exeter", "GoogleDrive-c@gmail.com"]) {
            $0 == "/Users/charlie/Library/CloudStorage/GoogleDrive-c@gmail.com/My Drive"
        }
        XCTAssertEqual(g.path, "/Users/charlie/Library/CloudStorage/GoogleDrive-c@gmail.com/My Drive/Orbit Backups")
        XCTAssertEqual(g.label, "Google Drive")
        let o = BackupPlanner.destination(home: home, cloudStorage: ["OneDrive-Exeter"]) { _ in false }
        XCTAssertEqual(o.label, "OneDrive")
        XCTAssertEqual(BackupPlanner.destination(home: home, cloudStorage: []) { _ in false }.path, "/Users/charlie/Documents/Orbit Backups")
    }

    func testManifestCodable() throws {
        let m = BackupManifest(createdAt: d(5, 3), appVersion: "1.0", hostName: "mac", counts: ["tasks": 3],
                               includesTypedNotes: true, includesKnowledgeBase: false)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(BackupManifest.self, from: e.encode(m)), m)
    }
}

final class ExamModeTests: XCTestCase {
    private func exam(_ id: String, due: Date?, kind: AssessmentKind = .exam, mark: Double? = nil) -> Assessment {
        Assessment(id: id, moduleCode: "BEE1022", title: "\(id) exam", kind: kind, weightPercent: 60, due: due, mark: mark)
    }

    func testActivatesWithin28Days() {
        let mode = ExamMode(calendar: F.cal)
        let now = d(5, 12)
        XCTAssertFalse(mode.isActive(assessments: [exam("a", due: F.date(2026, 11, 10, 9))], now: now))
        XCTAssertTrue(mode.isActive(assessments: [exam("a", due: F.date(2026, 10, 30, 9))], now: now))
        XCTAssertFalse(mode.isActive(assessments: [exam("a", due: F.date(2026, 10, 30, 9), kind: .essay)], now: now))
        XCTAssertFalse(mode.isActive(assessments: [exam("a", due: d(4, 9))], now: now)) // past
        XCTAssertFalse(mode.isActive(assessments: [exam("a", due: F.date(2026, 10, 30, 9), mark: 65)], now: now))
        XCTAssertTrue(ExamMode(manual: .on, calendar: F.cal).isActive(assessments: [], now: now))
        XCTAssertFalse(ExamMode(manual: .off, calendar: F.cal).isActive(assessments: [exam("a", due: d(6, 9))], now: now))
        XCTAssertTrue(ExamMode(withinDays: 50, calendar: F.cal).isActive(assessments: [exam("a", due: F.date(2026, 11, 10, 9))], now: now))
    }

    func testCountdowns() {
        let c = ExamMode(calendar: F.cal).countdowns([exam("b", due: d(20, 9)), exam("a", due: d(8, 14))], now: d(5, 12))
        XCTAssertEqual(c.map(\.id), ["a", "b"])
        XCTAssertEqual(c[0].days, 3)
        XCTAssertEqual(c[0].hours, 74)
    }

    func testPastPapersAndDurations() {
        XCTAssertEqual(ExamMode.duration(in: "BEE1022 Past paper 2024 (1½ hours)"), 90)
        XCTAssertEqual(ExamMode.duration(in: "Exam paper 2 hours"), 120)
        XCTAssertEqual(ExamMode.duration(in: "Mock exam – 45 minutes"), 45)
        XCTAssertNil(ExamMode.duration(in: "Past paper 2023"))
        let docs = [
            CourseDocumentInfo(id: "1", moduleCode: "BEE1022", kind: .pastPaper, title: "Past paper 2023", characters: 10),
            CourseDocumentInfo(id: "2", moduleCode: "BEE1022", kind: .other, title: "Exam paper 2024 (1.5 hours)", characters: 10),
            CourseDocumentInfo(id: "3", moduleCode: "BEE1022", kind: .slides, title: "Lecture 3", characters: 10),
        ]
        let papers = ExamMode.pastPapers(docs)
        XCTAssertEqual(papers.map(\.id), ["2", "1"])
        XCTAssertEqual(papers[0].minutes, 90)
        XCTAssertEqual(papers[1].minutes, 90)
    }

    func testWeakTopics() {
        let weak = ExamMode.weakTopics(
            flashcardEase: ["Elasticity": ("BEE1022", 1.7, 3), "Supply": ("BEE1022", 2.6, 0)],
            missed: [("Game theory", "BEE1024")], lowConfidence: [("Elasticity", "BEE1022")], shaky: ["Oligopoly"])
        XCTAssertEqual(weak.first?.topic, "Elasticity")
        XCTAssertEqual(Set(weak.first!.reasons), ["low flashcard ease", "low confidence"])
        XCTAssertFalse(weak.contains { $0.topic == "Supply" })
        XCTAssertTrue(weak.contains { $0.topic == "Oligopoly" && $0.reasons == ["marked shaky"] })
    }

    func testDailyTarget() {
        XCTAssertEqual(ExamMode.dailyTarget(remainingMinutes: 1200, daysLeft: 10), 120)
        XCTAssertEqual(ExamMode.dailyTarget(remainingMinutes: 100, daysLeft: 10), 60)
        XCTAssertEqual(ExamMode.dailyTarget(remainingMinutes: 6000, daysLeft: 2), 300)
    }
}
