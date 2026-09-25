import XCTest
@testable import OrbitCore

final class BriefMorningTests: XCTestCase {
    typealias F = SchedFixtures
    let now = SchedFixtures.date(2026, 10, 5, 7, 30) // Monday morning

    func email(_ id: String, _ cat: EmailCategory, _ importance: Double, hoursAgo: Double = 1) -> EmailDigest {
        EmailDigest(id: id, account: .exeter, from: "\(id)@exeter.ac.uk", subject: "Subject \(id)",
                    date: now.addingTimeInterval(-hoursAgo * 3600), category: cat, summary: "Summary \(id)",
                    importance: importance)
    }

    func makeBrief() -> MorningBrief {
        let events = [
            F.event("Seminar", F.date(2026, 10, 5, 14), F.date(2026, 10, 5, 15)),
            F.event("Lecture", F.date(2026, 10, 5, 9), F.date(2026, 10, 5, 11)),
            F.event("Tomorrow thing", F.date(2026, 10, 6, 9), F.date(2026, 10, 6, 10)),
            F.event("Essay block copy", F.date(2026, 10, 5, 12), F.date(2026, 10, 5, 13), source: .orbit),
            F.event("Reading week", F.date(2026, 10, 5), F.date(2026, 10, 10), allDay: true),
        ]
        let t1 = F.task("Essay plan", minutes: 120, deadline: F.date(2026, 10, 8, 17), index: 1)
        let t2 = F.task("Far away", deadline: F.date(2026, 10, 20), index: 2)
        let t3 = F.task("Overdue form", deadline: F.date(2026, 10, 3), index: 3)
        var t4 = F.task("Finished", deadline: F.date(2026, 10, 6), index: 4)
        t4.completedAt = F.date(2026, 10, 4)
        let blocks = [
            ScheduledBlock(taskID: t1.id, title: "Essay plan", start: F.date(2026, 10, 5, 11, 15), end: F.date(2026, 10, 5, 12, 15)),
            ScheduledBlock(taskID: t1.id, title: "Essay plan", start: F.date(2026, 10, 6, 11), end: F.date(2026, 10, 6, 12)),
        ]
        let assessments = [
            Assessment(id: "a1", moduleCode: "BEM2031", title: "Essay 1", kind: .essay, weightPercent: 40, due: F.date(2026, 10, 9, 12)),
            Assessment(id: "a2", moduleCode: "BEM2031", title: "Exam", kind: .exam, weightPercent: 60, due: F.date(2027, 1, 15)),
            Assessment(id: "a3", moduleCode: "BEM2031", title: "Done", weightPercent: 10, due: F.date(2026, 10, 7), submitted: true),
        ]
        let emails = [email("low", .other, 0.9), email("ignore", .ignore, 1.0), email("urgent", .urgent, 0.5),
                      email("reply", .needsReply, 0.8), email("uni", .uni, 0.7)]
        let cards = [Flashcard(front: "a", back: "b", due: F.date(2026, 10, 5, 20)),
                     Flashcard(front: "c", back: "d", due: F.date(2026, 10, 4)),
                     Flashcard(front: "e", back: "f", due: F.date(2026, 10, 6, 1))]
        return MorningBriefBuilder(prefs: UserPrefs(), maxEmails: 3)
            .build(now: now, events: events, blocks: blocks, tasks: [t1, t2, t3, t4], assessments: assessments,
                   emails: emails, flashcards: cards)
    }

    func testStructuredData() {
        let b = makeBrief()
        XCTAssertEqual(b.date, F.date(2026, 10, 5))
        XCTAssertEqual(b.events.map(\.title), ["Lecture", "Seminar"])
        XCTAssertEqual(b.allDayEvents.map(\.title), ["Reading week"])
        XCTAssertEqual(b.blocks.count, 1)
        XCTAssertEqual(b.plannedMinutes, 60)
        XCTAssertEqual(b.busyMinutes, 180)
        XCTAssertEqual(b.firstStart, F.date(2026, 10, 5, 9))
        XCTAssertEqual(b.dueSoon.map(\.title), ["Overdue form", "Essay plan", "Essay 1"])
        XCTAssertTrue(b.dueSoon[0].isOverdue)
        XCTAssertEqual(b.dueSoon[0].daysLeft, -2)
        XCTAssertEqual(b.dueSoon[1].daysLeft, 3)
        XCTAssertEqual(b.dueSoon[1].remainingMinutes, 120)
        XCTAssertEqual(b.dueSoon[2].kind, .assessment)
        XCTAssertEqual(b.dueSoon[2].weightPercent, 40)
        XCTAssertEqual(b.topEmails.map(\.id), ["urgent", "reply", "uni"])
        XCTAssertEqual(b.flashcardsDue, 2)
        XCTAssertNil(b.narrative)
    }

    func testPlainSummaryAndCodable() throws {
        let b = makeBrief()
        let s = b.plainSummary()
        XCTAssertTrue(s.contains("Monday 5 October 2026"), s)
        XCTAssertTrue(s.contains("09:00–11:00 Lecture"), s)
        XCTAssertTrue(s.contains("Essay 1 (BEM2031, 40%) due Fri 9 Oct (in 4 days)"), s)
        XCTAssertTrue(s.contains("overdue since Sat 3 Oct"), s)
        XCTAssertTrue(s.contains("Flashcards due: 2"), s)
        XCTAssertEqual(try JSONDecoder().decode(MorningBrief.self, from: JSONEncoder().encode(b)), b)
    }

    func testNarrateUsesRouterWithUKEnglishPrompt() async throws {
        let seen = SchedBox<LLMRequest>()
        let provider = MockLLMProvider { req in
            seen.value = req
            return "  \"Morning! You've a lecture at 09:00 and the essay plan is due Thursday.\"  "
        }
        let router = LLMRouter(providers: [provider])
        let b = makeBrief()
        let text = try await b.narrate(using: router)
        XCTAssertEqual(text, "Morning! You've a lecture at 09:00 and the essay plan is due Thursday.")
        let req = try XCTUnwrap(seen.value)
        XCTAssertTrue(req.messages[0].text.contains("UK English"))
        XCTAssertTrue(req.messages[0].text.contains("3 to 5 sentences"))
        XCTAssertTrue(req.messages[1].text.contains("Lecture"))
        let narrated = await b.narrated(using: router)
        XCTAssertNotNil(narrated.narrative)

        let broken = LLMRouter(providers: [MockLLMProvider { _ in throw LLMError.emptyResponse }])
        let fallback = await b.narrated(using: broken)
        XCTAssertNil(fallback.narrative)
    }
}

/// Tiny thread-safe box for capturing values in @Sendable closures.
final class SchedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

final class BriefEveningTests: XCTestCase {
    typealias F = SchedFixtures
    let now = SchedFixtures.date(2026, 10, 5, 21, 30) // Monday evening

    func testDoneMissedRolloverAndTomorrow() throws {
        let essay = F.task("Essay", minutes: 180, deadline: F.date(2026, 10, 9), index: 1)
        let reading = F.task("Reading", minutes: 60, deadline: F.date(2026, 10, 5, 17), index: 2)
        var form = F.task("Form", minutes: 15, index: 3)
        form.completedAt = F.date(2026, 10, 5, 16)
        let b1 = ScheduledBlock(id: F.uuid(11), taskID: essay.id, title: "Essay", start: F.date(2026, 10, 5, 9), end: F.date(2026, 10, 5, 10, 30))
        let b2 = ScheduledBlock(id: F.uuid(12), taskID: essay.id, title: "Essay", start: F.date(2026, 10, 5, 14), end: F.date(2026, 10, 5, 15))
        let b3 = ScheduledBlock(id: F.uuid(13), taskID: reading.id, title: "Reading", start: F.date(2026, 10, 5, 16), end: F.date(2026, 10, 5, 17))
        let late = ScheduledBlock(id: F.uuid(14), taskID: essay.id, title: "Essay", start: F.date(2026, 10, 5, 21, 40), end: F.date(2026, 10, 5, 22))
        let tomorrow = ScheduledBlock(id: F.uuid(15), taskID: essay.id, title: "Essay", start: F.date(2026, 10, 6, 10), end: F.date(2026, 10, 6, 11))
        let events = [F.event("Lecture", F.date(2026, 10, 6, 9), F.date(2026, 10, 6, 10)),
                      F.event("Today thing", F.date(2026, 10, 5, 12), F.date(2026, 10, 5, 13))]

        let r = EveningReviewBuilder(prefs: UserPrefs()).build(
            now: now, blocks: [b1, b2, b3, late, tomorrow], completedBlockIDs: [b1.id],
            tasks: [essay, reading, form], events: events,
            previousStreak: StreakState(count: 3, best: 5, lastActiveDay: F.date(2026, 10, 4)))

        XCTAssertEqual(r.done.map(\.id), [b1.id])
        XCTAssertEqual(r.missed.map(\.id), [b2.id, b3.id])
        XCTAssertEqual(r.remaining.map(\.id), [late.id])
        XCTAssertEqual(r.completedTasks.map(\.title), ["Form"])
        XCTAssertEqual(r.minutesDone, 90)
        XCTAssertEqual(r.minutesPlanned, 90 + 60 + 60 + 20)
        XCTAssertEqual(r.completionRate!, 90.0 / 210.0, accuracy: 0.0001)
        XCTAssertEqual(r.rollovers.map(\.title), ["Essay", "Reading"])
        XCTAssertEqual(r.rollovers[0].minutes, 60)
        XCTAssertEqual(r.rollovers[0].suggestedDay, F.date(2026, 10, 6))
        XCTAssertEqual(r.tomorrowEvents.map(\.title), ["Lecture"])
        XCTAssertEqual(r.tomorrowBlocks.map(\.id), [tomorrow.id])
        XCTAssertEqual(r.tomorrowFirstStart, F.date(2026, 10, 6, 9))
        XCTAssertTrue(r.wasProductive)
        XCTAssertEqual(r.streak, StreakState(count: 4, best: 5, lastActiveDay: F.date(2026, 10, 5)))

        let s = r.plainSummary()
        XCTAssertTrue(s.contains("Missed: Essay at 14:00; Reading at 16:00"), s)
        XCTAssertTrue(s.contains("Streak: 4 days (best 5)"), s)
        XCTAssertEqual(try JSONDecoder().decode(EveningReview.self, from: JSONEncoder().encode(r)), r)
    }

    func testRolloverForTaskDueTodayWithoutBlocks() {
        let t = F.task("Hand in form", minutes: 20, deadline: F.date(2026, 10, 5, 17), index: 1)
        let r = EveningReviewBuilder().build(now: now, blocks: [], tasks: [t])
        XCTAssertEqual(r.rollovers.map(\.reason), ["Was due today"])
        XCTAssertNil(r.completionRate)
        XCTAssertFalse(r.wasProductive)
    }

    func testStreakRules() {
        let cal = F.cal
        var prefs = UserPrefs()
        prefs.restDays = [1] // Sunday
        let finder = FreeSlotFinder(prefs: prefs)
        let fri = F.date(2026, 10, 2), sat = F.date(2026, 10, 3), mon = F.date(2026, 10, 5)
        let s0 = StreakState(count: 2, best: 2, lastActiveDay: fri)

        // Saturday productive → continues.
        let s1 = EveningReviewBuilder.updateStreak(s0, day: sat, productive: true, cal: cal, finder: finder)
        XCTAssertEqual(s1.count, 3)
        XCTAssertEqual(s1.best, 3)
        // Sunday is a rest day: nothing done doesn't break it; Monday continues.
        let s2 = EveningReviewBuilder.updateStreak(s1, day: F.date(2026, 10, 4), productive: false, cal: cal, finder: finder)
        XCTAssertEqual(s2.count, 3)
        let s3 = EveningReviewBuilder.updateStreak(s2, day: mon, productive: true, cal: cal, finder: finder)
        XCTAssertEqual(s3.count, 4)
        // Running the review twice on the same day doesn't double count.
        XCTAssertEqual(EveningReviewBuilder.updateStreak(s3, day: mon, productive: true, cal: cal, finder: finder), s3)
        // An unproductive working day resets it.
        let s4 = EveningReviewBuilder.updateStreak(s3, day: F.date(2026, 10, 6), productive: false, cal: cal, finder: finder)
        XCTAssertEqual(s4.count, 0)
        XCTAssertEqual(s4.best, 4)
        // A gap of skipped working days restarts at 1.
        let s5 = EveningReviewBuilder.updateStreak(s1, day: F.date(2026, 10, 7), productive: true, cal: cal, finder: finder)
        XCTAssertEqual(s5.count, 1)
    }

    func testNarrate() async throws {
        let router = LLMRouter(providers: [MockLLMProvider { req in
            XCTAssertTrue(req.messages[1].text.contains("evening review"))
            return "Solid day."
        }])
        let r = EveningReviewBuilder().build(now: now, blocks: [], tasks: [])
        let text = try await r.narrate(using: router)
        XCTAssertEqual(text, "Solid day.")
    }
}
