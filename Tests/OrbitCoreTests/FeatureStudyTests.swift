import XCTest
@testable import OrbitCore

final class FeatureStudyTests: XCTestCase {
    let tz = TimeZone(identifier: "Europe/London")!
    var cal: DayCalendar { DayCalendar(timeZone: tz) }
    func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 0, _ mi: Int = 0) -> Date { cal.date(year: y, month: m, day: day, hour: h, minute: mi)! }

    // MARK: Reading chunking

    func testReadingEstimates() {
        XCTAssertEqual(ReadingEstimator.pages(in: "Mankiw ch. 3, pp. 45–67")?.pages, 23)
        XCTAssertEqual(ReadingEstimator.pages(in: "Mankiw ch. 3, pp. 45–67")?.range, 45...67)
        XCTAssertEqual(ReadingEstimator.pages(in: "Varian Chapter 5")?.pages, 30)
        XCTAssertEqual(ReadingEstimator.pages(in: "Varian chapters 5-6")?.pages, 60)
        XCTAssertEqual(ReadingEstimator.pages(in: "Article (18 pages)")?.pages, 18)
        XCTAssertNil(ReadingEstimator.pages(in: "Friedman (1953) The methodology of positive economics"))

        let base = ReadingAssignment(id: "r", moduleCode: "BEE1022", title: "Friedman (1953)", neededBy: d(2026, 10, 12, 9))
        XCTAssertEqual(ReadingEstimator.estimate(base).minutes, 40) // default 20 pages ≈ 40 min
        var chapter = base; chapter.title = "Varian Chapter 5"
        XCTAssertEqual(ReadingEstimator.estimate(chapter).minutes, 60)
        var guide = base; guide.isGuide = true
        XCTAssertEqual(ReadingEstimator.estimate(guide).minutes, 10)
    }

    func testReadingSplitsIntoDailyChunksBeforeTheLecture() {
        let prefs = UserPrefs()
        let planner = ReadingPlanner(prefs: prefs)
        let now = d(2026, 10, 5, 8) // Monday
        let lecture = d(2026, 10, 9, 10) // Friday 10:00
        let readings = [
            ReadingAssignment(id: "ch", moduleCode: "BEE1022", title: "Varian chapters 5-6", neededBy: lecture), // 120 min
            ReadingAssignment(id: "pp", moduleCode: "BEE1022", title: "Mankiw pp. 1–20", neededBy: lecture),     // 40 min
            ReadingAssignment(id: "done", moduleCode: "BEE1022", title: "Old", neededBy: lecture, done: true),
        ]
        let chunks = planner.plan(readings, now: now)
        XCTAssertFalse(chunks.contains { $0.readingID == "done" })
        let ch = chunks.filter { $0.readingID == "ch" }
        XCTAssertEqual(ch.count, 3)
        XCTAssertEqual(ch.reduce(0) { $0 + $1.minutes }, 120)
        XCTAssertTrue(chunks.allSatisfy { $0.minutes <= 45 })
        // One chunk of a reading per day, in order, all before the lecture.
        XCTAssertEqual(Set(ch.map(\.day)).count, 3)
        XCTAssertEqual(ch.map(\.day), ch.map(\.day).sorted())
        XCTAssertTrue(chunks.allSatisfy { $0.deadline <= lecture && $0.day < cal.startOfDay(lecture) })
        XCTAssertTrue(chunks.allSatisfy { $0.earliestStart < $0.deadline })
        // Load is balanced: no day has more than 45 + 40 minutes.
        let perDay = Dictionary(grouping: chunks, by: \.day).mapValues { $0.reduce(0) { $0 + $1.minutes } }
        XCTAssertLessThanOrEqual(perDay.values.max()!, 85)
        // Page ranges for the "pp." reading.
        let pp = chunks.first { $0.readingID == "pp" }!
        XCTAssertEqual(pp.pageRange, 1...20)
        XCTAssertTrue(pp.title.contains("pp. 1–20"), pp.title)
        // Tasks are medium energy with fixed block length and stable ids.
        let task = ch[0].task()
        XCTAssertEqual(task.energy, .medium)
        XCTAssertEqual(task.minBlockMinutes, task.estimateMinutes)
        XCTAssertEqual(task.id, ReadingPlanner.chunkID(readingID: "ch", index: 0))
        XCTAssertEqual(planner.plan(readings, now: now), chunks) // deterministic
    }

    func testReadingRebalancesAfterProgress() {
        let planner = ReadingPlanner(prefs: UserPrefs())
        let lecture = d(2026, 10, 9, 10)
        let readings = [ReadingAssignment(id: "ch", moduleCode: "BEE1022", title: "Varian chapters 5-6", neededBy: lecture)]
        // Thursday, one chunk (45 min) done: 75 minutes left, only Thursday before the lecture.
        let chunks = planner.plan(readings, minutesDone: ["ch": 45], now: d(2026, 10, 8, 9))
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.minutes }, 75)
        XCTAssertEqual(Set(chunks.map(\.day)), [d(2026, 10, 8)])
        XCTAssertEqual(chunks.first?.index, 1) // numbering continues after the finished chunk
        // Lecture already started today: plan what's left today.
        let late = planner.plan(readings, now: d(2026, 10, 9, 11))
        XCTAssertEqual(Set(late.map(\.day)), [d(2026, 10, 9)])
    }

    func testNeededByFindsFirstModuleSession() {
        let week = d(2026, 10, 5)
        let events = [
            CalendarEvent(id: "1", title: "BEE1022 Tutorial", start: d(2026, 10, 7, 14), end: d(2026, 10, 7, 15), source: .timetable),
            CalendarEvent(id: "2", title: "BEE1022 Lecture", start: d(2026, 10, 6, 9), end: d(2026, 10, 6, 10), source: .timetable),
            CalendarEvent(id: "3", title: "BEM1015 Lecture", start: d(2026, 10, 5, 9), end: d(2026, 10, 5, 10), source: .timetable),
        ]
        XCTAssertEqual(ReadingPlanner.neededBy(moduleCode: "BEE1022", weekStart: week, events: events, timeZone: tz), d(2026, 10, 6, 9))
        XCTAssertEqual(ReadingPlanner.neededBy(moduleCode: "XYZ1000", weekStart: week, events: events, timeZone: tz), d(2026, 10, 5, 9))
    }

    // MARK: Deadline alerts

    func testDeadlineAlertSchedule() {
        let planner = DeadlineAlertPlanner(quietHours: QuietHours(start: 23 * 60, end: 8 * 60), timeZone: tz)
        let item = DeadlineItem(id: "a1", kind: .assessment, title: "Essay", moduleCode: "BEE1022", due: d(2026, 10, 16, 12),
                                nextStep: "Proofread the conclusion")
        let alerts = planner.schedule([item])
        XCTAssertEqual(alerts.map(\.level), [.h72, .h24, .h3, .h1])
        XCTAssertEqual(alerts.map(\.fireAt), [d(2026, 10, 13, 12), d(2026, 10, 15, 12), d(2026, 10, 16, 9), d(2026, 10, 16, 11)])
        XCTAssertTrue(alerts[0].title.hasPrefix("Coming up"))
        XCTAssertTrue(alerts[3].title.hasPrefix("1 hour left"))
        XCTAssertTrue(alerts[0].body.contains("Next step: Proofread the conclusion."), alerts[0].body)
        XCTAssertTrue(alerts[3].body.contains("Submit on ELE"))
        // Done items get nothing.
        var done = item; done.done = true
        XCTAssertTrue(planner.schedule([done]).isEmpty)
    }

    func testDeadlineAlertsRespectQuietHours() {
        let planner = DeadlineAlertPlanner(quietHours: QuietHours(start: 23 * 60, end: 8 * 60), timeZone: tz)
        // Due 09:00: the 3 h alert (06:00) moves to 08:00; the 1 h (08:00) is fine.
        XCTAssertEqual(planner.fireTime(for: d(2026, 10, 16, 9), level: .h3), d(2026, 10, 16, 8))
        // Due 07:30: 3 h alert (04:30) can't wait until 08:00, so it goes just before 23:00 the night before.
        XCTAssertEqual(planner.fireTime(for: d(2026, 10, 16, 7, 30), level: .h3), d(2026, 10, 15, 22, 59))
        // Due 00:30: the 1 h alert at 23:30 moves to 22:59.
        XCTAssertEqual(planner.fireTime(for: d(2026, 10, 17, 0, 30), level: .h1), d(2026, 10, 16, 22, 59))
        // Nothing fires during quiet hours.
        let item = DeadlineItem(id: "x", kind: .task, title: "T", due: d(2026, 10, 16, 9))
        XCTAssertTrue(planner.due([item], now: d(2026, 10, 16, 2), sent: []).alerts.isEmpty)
    }

    func testDeadlineAlertsDeDuplicateAndSkipStale() {
        let planner = DeadlineAlertPlanner(quietHours: QuietHours(enabled: false), timeZone: tz)
        let item = DeadlineItem(id: "h", kind: .homework, title: "Problem set 2", due: d(2026, 10, 16, 12))
        // Added 10 hours before: only the 24 h alert fires; the 72 h one is marked as sent.
        var sent = Set<String>()
        let first = planner.due([item], now: d(2026, 10, 16, 2), sent: sent)
        XCTAssertEqual(first.alerts.map(\.level), [.h24])
        XCTAssertEqual(first.alsoMarkSent, [DeadlineAlertPlanner.key(item, .h72)])
        sent.formUnion(first.alerts.map(\.id)); sent.formUnion(first.alsoMarkSent)
        XCTAssertTrue(planner.due([item], now: d(2026, 10, 16, 3), sent: sent).alerts.isEmpty)
        let third = planner.due([item], now: d(2026, 10, 16, 9, 5), sent: sent)
        XCTAssertEqual(third.alerts.map(\.level), [.h3])
        sent.formUnion(third.alerts.map(\.id))
        XCTAssertEqual(planner.due([item], now: d(2026, 10, 16, 11, 1), sent: sent).alerts.map(\.level), [.h1])
        // A moved deadline alerts again (new key).
        var moved = item; moved.due = d(2026, 10, 20, 12)
        XCTAssertEqual(planner.due([moved], now: d(2026, 10, 17, 13), sent: sent).alerts.map(\.level), [.h72])
        // Past the deadline: nothing.
        XCTAssertTrue(planner.due([item], now: d(2026, 10, 16, 13), sent: []).alerts.isEmpty)
    }

    // MARK: Focus

    func testFocusSessionTiming() {
        let t0 = d(2026, 10, 5, 10)
        var s = FocusSession(title: "Read Varian chapter 5", plannedMinutes: 25, startedAt: t0)
        XCTAssertEqual(s.kind, .reading)
        s.pause(at: t0.addingTimeInterval(600))
        XCTAssertTrue(s.isPaused)
        XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(900)), 600)
        s.resume(at: t0.addingTimeInterval(1200))
        XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(1800)), 1200)
        XCTAssertEqual(s.clock(at: t0.addingTimeInterval(1800)), "05:00") // 25 min − 20 min
        XCTAssertEqual(s.clock(at: t0.addingTimeInterval(3000)), "+15:00")
        let entry = s.finish(at: t0.addingTimeInterval(2400))
        XCTAssertEqual(entry?.minutes, 30)
        XCTAssertNil(s.finish(at: t0.addingTimeInterval(3000))) // only once
        var short = FocusSession(title: "x", startedAt: t0)
        XCTAssertNil(short.finish(at: t0.addingTimeInterval(20)))
    }

    func testTaskKindClassification() {
        XCTAssertEqual(TaskKind.classify(title: "Read Mankiw ch 3"), .reading)
        XCTAssertEqual(TaskKind.classify(title: "BEE1022 problem set 3"), .problemSet)
        XCTAssertEqual(TaskKind.classify(title: "Essay · Draft"), .writing)
        XCTAssertEqual(TaskKind.classify(title: "Revision session 2 of 6"), .revision)
        XCTAssertEqual(TaskKind.classify(title: "Type up lecture notes"), .notes)
        XCTAssertEqual(TaskKind.classify(title: "Email tutor"), .admin)
        XCTAssertEqual(TaskKind.classify(title: "Gym"), .other)
    }

    func testDurationLearning() {
        var l = DurationLearner()
        XCTAssertEqual(l.multiplier(for: .reading), 1)
        l.record(kind: .reading, estimateMinutes: 40, actualMinutes: 60) // 1.5
        XCTAssertEqual(l.multiplier(for: .reading), 1) // needs 2 samples
        l.record(kind: .reading, estimateMinutes: 40, actualMinutes: 60)
        let m = l.multiplier(for: .reading)
        XCTAssertEqual(m, 1 + 0.5 * (2.0 / 5.0), accuracy: 1e-9) // blended towards 1
        XCTAssertEqual(l.adjustedEstimate(40, kind: .reading), 50)
        // Other kinds untouched.
        XCTAssertEqual(l.adjustedEstimate(40, kind: .writing), 40)
        // Outliers are clamped.
        var o = DurationLearner()
        for _ in 0..<10 { o.record(kind: .admin, estimateMinutes: 10, actualMinutes: 500) }
        XCTAssertEqual(o.multiplier(for: .admin), 2)
        // Estimates already scaled at creation don't compound.
        var c = DurationLearner()
        c.record(kind: .reading, estimateMinutes: 60, actualMinutes: 60, appliedMultiplier: 1.5) // raw 40 → ratio 1.5
        c.record(kind: .reading, estimateMinutes: 60, actualMinutes: 60, appliedMultiplier: 1.5)
        XCTAssertEqual(c.stats[.reading]!.meanRatio, 1.5, accuracy: 1e-9)
        let (task, applied) = c.adjusted(OrbitTask(title: "Read chapter 2", estimateMinutes: 40))
        XCTAssertEqual(task.estimateMinutes, 50)
        XCTAssertGreaterThan(applied, 1)
    }

    // MARK: Feedback themes

    func testFeedbackHeuristics() {
        let text = """
        A well-structured essay with clear signposting. However, the discussion is too descriptive and needs more critical analysis \
        of the model's assumptions. Referencing was inconsistent in places. Good use of evidence from the literature, but the argument \
        could be clearer about your own position.
        """
        let points = FeedbackThemeExtractor.heuristic(text)
        let byID = Dictionary(uniqueKeysWithValues: points.map { ($0.themeID, $0) })
        XCTAssertEqual(byID["critical-analysis"]?.needsWork, true)
        XCTAssertEqual(byID["referencing"]?.needsWork, true)
        XCTAssertEqual(byID["structure"]?.needsWork, false)
        XCTAssertEqual(byID["evidence"]?.needsWork, false)
        XCTAssertEqual(byID["argument"]?.needsWork, true)
    }

    func testFeedbackLedgerAndReminders() async {
        var ledger = FeedbackLedger()
        let f1 = AssessmentFeedback(moduleCode: "BEE1022", assessmentTitle: "Essay 1", mark: 62,
                                    comments: "Needs more critical analysis. Referencing needs work.", receivedAt: d(2026, 11, 1))
        let f2 = AssessmentFeedback(moduleCode: "BEM1015", assessmentTitle: "Report", mark: 66,
                                    comments: "Still lacks critical evaluation of the evidence base.", receivedAt: d(2026, 12, 1))
        let p1 = await FeedbackThemeExtractor.extract(f1, router: nil)
        ledger.ingest(f1, points: p1)
        XCTAssertFalse(ledger.isNew(f1))
        ledger.ingest(f1, points: p1) // idempotent
        ledger.ingest(f2, points: FeedbackThemeExtractor.heuristic(f2.comments))
        let critical = ledger.themes.first { $0.themeID == "critical-analysis" }!
        XCTAssertEqual(critical.needsWorkCount, 2)
        XCTAssertTrue(critical.isRecurring)
        XCTAssertEqual(Set(critical.modules), ["BEE1022", "BEM1015"])
        XCTAssertEqual(ledger.toWorkOn.first?.themeID, "critical-analysis")

        let next = Assessment(id: "a", moduleCode: "BEE1022", title: "Essay 2", kind: .essay)
        let reminders = ledger.reminders(for: next)
        XCTAssertTrue(reminders.first!.hasPrefix("Last time: needed more critical analysis (raised 2 times)"), reminders.first!)
        XCTAssertTrue(reminders.first!.contains("evaluation paragraph"))
        XCTAssertTrue(reminders.contains { $0.contains("referencing") })
        // Another module only sees recurring themes.
        let other = Assessment(id: "b", moduleCode: "BEM2000", title: "Exam", kind: .exam)
        XCTAssertEqual(ledger.reminders(for: other).count, 1)
    }

    func testFeedbackFromELEGrade() {
        let g = ELEGrade(id: "g1", moduleCode: "BEE1022", itemName: "Essay 1", percent: 64, feedback: "Clear structure.")
        let f = AssessmentFeedback(grade: g)
        XCTAssertEqual(f?.mark, 64)
        XCTAssertNil(AssessmentFeedback(grade: ELEGrade(id: "g2", moduleCode: "X", itemName: "Y", percent: 50)))
    }

    func testFeedbackAIFallsBackToHeuristicsOnBadJSON() async {
        let router = LLMRouter(providers: [MockLLMProvider { _ in "not json" }])
        let f = AssessmentFeedback(moduleCode: "M", assessmentTitle: "A", comments: "Needs more critical analysis.")
        let points = await FeedbackThemeExtractor.extract(f, router: router)
        XCTAssertEqual(points.map(\.themeID), ["critical-analysis"])

        let good = LLMRouter(providers: [MockLLMProvider { req in
            XCTAssertEqual(req.purpose, .privateData)
            return #"{"points":[{"theme":"critical-analysis","needs_work":true,"quote":"more analysis"},{"theme":"use of diagrams","needs_work":true}]}"#
        }])
        let ai = await FeedbackThemeExtractor.extract(f, router: good)
        XCTAssertEqual(ai.map(\.themeID), ["critical-analysis", "use-of-diagrams"])
    }

    // MARK: Flashcards

    func testFlashcardDedupeAndDailyReview() {
        let existing = [Flashcard(moduleCode: "BEE1022", front: "What is the price elasticity of demand?", back: "…")]
        let new = [
            Flashcard(moduleCode: "BEE1022", front: "Define price elasticity of demand", back: "…"),   // same question
            Flashcard(moduleCode: "BEE1022", front: "What is consumer surplus?", back: "…"),
            Flashcard(moduleCode: "BEE1022", front: "what is consumer surplus", back: "…"),              // duplicate within batch
            Flashcard(moduleCode: "BEM1015", front: "What is the price elasticity of demand?", back: "…"), // other module
        ]
        let kept = FlashcardDeck.dedupe(new, against: existing)
        XCTAssertEqual(kept.map(\.front), ["What is consumer surplus?", "What is the price elasticity of demand?"])

        let now = d(2026, 10, 5, 8)
        var cards: [Flashcard] = []
        for i in 0..<30 { cards.append(Flashcard(moduleCode: i % 3 == 0 ? "A" : "B", front: "q\(i)", back: "a", due: now.addingTimeInterval(Double(-i) * 3600))) }
        cards.append(Flashcard(front: "future", back: "a", due: d(2026, 10, 7)))
        let plan = FlashcardDeck.dailyReview(cards, now: now, endOfDay: cal.endOfDay(now))
        XCTAssertEqual(plan.dueCount, 30)
        XCTAssertEqual(plan.sessionCards.count, 20) // 10 minutes at 30 s a card
        XCTAssertEqual(plan.estimatedMinutes, 10)
        XCTAssertEqual(plan.byModule["A"], 10)
        XCTAssertTrue(plan.briefLine!.hasPrefix("10-minute review: 20 flashcards"))
        // Interleaved: both modules in the first two picks.
        let firstTwo = plan.sessionCards.prefix(2).compactMap { id in cards.first { $0.id == id }?.moduleCode }
        XCTAssertEqual(Set(firstTwo), ["A", "B"])
    }

    func testReviewAnswersMapToSM2() {
        let now = d(2026, 10, 5, 8)
        let card = Flashcard(front: "q", back: "a", due: now)
        XCTAssertEqual(FlashcardDeck.review(card, answer: .again, now: now).due, now.addingTimeInterval(600))
        XCTAssertEqual(FlashcardDeck.intervalLabel(card, answer: .again, now: now), "10m")
        XCTAssertEqual(FlashcardDeck.intervalLabel(card, answer: .good, now: now), "1d")
        var learned = card; learned.repetitions = 1; learned.intervalDays = 1
        XCTAssertEqual(FlashcardDeck.intervalLabel(learned, answer: .good, now: now), "6d")
        XCTAssertEqual(ReviewAnswer.allCases.map(\.grade), [1, 3, 4, 5])
    }

    func testFlashcardGeneratorUsesLocalAIAndDedupes() async throws {
        let router = LLMRouter(providers: [MockLLMProvider { req in
            XCTAssertEqual(req.purpose, .privateData)
            XCTAssertTrue(req.messages[0].text.contains("lecture slides"))
            return #"{"cards":[{"front":"What shifts the demand curve?","back":"Income, prices of related goods, tastes."},{"front":"What shifts the demand curve","back":"dup"},{"front":" ","back":"x"}]}"#
        }])
        let material = StudyMaterial(id: "slides:1", moduleCode: "BEE1022", week: 2, title: "Lecture 2 slides",
                                     text: String(repeating: "Demand and supply. ", count: 10), kind: .slides)
        let cards = try await FlashcardGenerator.cards(from: material, router: router)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].noteID, "slides:1")
        XCTAssertEqual(FlashcardGenerator.pending([material], processed: [material.id: material.fingerprint]), [])
        XCTAssertEqual(FlashcardGenerator.pending([material], processed: [:]).count, 1)
    }

    // MARK: Quick capture

    func testQuickCapturePrefixes() {
        let p = QuickCaptureParser(now: d(2026, 10, 5, 10), timeZone: tz) // Monday
        guard case .task(let t)? = p.parse("essay plan BEE1022 2h before Friday") else { return XCTFail() }
        XCTAssertEqual(t.moduleCode, "BEE1022")
        XCTAssertEqual(t.estimateMinutes, 120)
        guard case .event(let e)? = p.parse("e: dinner with Sam Friday 7pm @ Côte") else { return XCTFail() }
        XCTAssertEqual(e.title, "Dinner with Sam")
        XCTAssertEqual(e.start, d(2026, 10, 9, 19))
        XCTAssertEqual(e.end, d(2026, 10, 9, 20))
        XCTAssertEqual(e.location, "Côte")
        XCTAssertTrue(e.hasTime)
        guard case .event(let e2)? = p.parse("event: football tomorrow 3pm for 2h") else { return XCTFail() }
        XCTAssertEqual(e2.start, d(2026, 10, 6, 15))
        XCTAssertEqual(e2.end, d(2026, 10, 6, 17))
        XCTAssertEqual(e2.title, "Football")
        guard case .note(let n)? = p.parse("n: BEE1022 ask about elasticity in tutorial") else { return XCTFail() }
        XCTAssertEqual(n.moduleCode, "BEE1022")
        XCTAssertEqual(n.body, "BEE1022 ask about elasticity in tutorial")
        XCTAssertNil(p.parse("   "))
        XCTAssertNil(p.parse("e:"))
    }

    // MARK: Weekly report

    func testWeeklyReportMetrics() {
        let now = d(2026, 10, 18, 18) // Sunday of teaching week 5
        let modules = [Module(code: "BEE1022", name: "Micro"), Module(code: "BEM1015", name: "Accounting")]
        let assessments = [
            Assessment(id: "q1", moduleCode: "BEE1022", title: "Quiz 1", kind: .quiz, weightPercent: 20, due: d(2026, 10, 1), mark: 58, submitted: true),
            Assessment(id: "e1", moduleCode: "BEE1022", title: "Essay", kind: .essay, weightPercent: 80, due: d(2026, 10, 23, 12)),
            Assessment(id: "r1", moduleCode: "BEM1015", title: "Report", kind: .report, weightPercent: 100, due: d(2026, 12, 1)),
        ]
        let readings = [
            ReadingItem(id: "1", moduleCode: "BEE1022", title: "a", essential: true, week: 2, done: true),
            ReadingItem(id: "2", moduleCode: "BEE1022", title: "b", essential: true, week: 3, done: false),
            ReadingItem(id: "3", moduleCode: "BEE1022", title: "c", essential: true, week: 4, done: false),
            ReadingItem(id: "4", moduleCode: "BEE1022", title: "future", essential: true, week: 9, done: false),
            ReadingItem(id: "5", moduleCode: "BEM1015", title: "x", essential: true, week: 3, done: true),
        ]
        var lectures: [CalendarEvent] = []
        for day in [6, 13] {
            lectures.append(CalendarEvent(id: "L\(day)", title: "BEE1022 Lecture", start: d(2026, 10, day, 9), end: d(2026, 10, day, 10), source: .timetable))
            lectures.append(CalendarEvent(id: "M\(day)", title: "BEM1015 Lecture", start: d(2026, 10, day, 11), end: d(2026, 10, day, 12), source: .timetable))
        }
        let notes = [LectureNote(id: "n1", title: "L", moduleCode: "BEE1022", created: d(2026, 10, 6, 12)),
                     LectureNote(id: "n2", title: "L", moduleCode: "BEM1015", created: d(2026, 10, 6, 13)),
                     LectureNote(id: "n3", title: "L", moduleCode: "BEM1015", created: d(2026, 10, 14, 13))]
        let homework = [HomeworkStatus(id: "h1", moduleCode: "BEE1022", title: "Problem set 3", due: d(2026, 10, 16), done: false),
                        HomeworkStatus(id: "h2", moduleCode: "BEM1015", title: "Sheet 2", due: d(2026, 10, 16), done: true)]
        let essayTask = OrbitTask(title: "Essay · Draft", estimateMinutes: 600, moduleCode: "BEE1022", assessmentID: "e1", minutesDone: 60)
        let blocks = [ScheduledBlock(taskID: essayTask.id, title: "Essay", start: d(2026, 10, 14, 9), end: d(2026, 10, 14, 12), moduleCode: "BEE1022"),
                      ScheduledBlock(taskID: UUID(), title: "Report", start: d(2026, 10, 15, 9), end: d(2026, 10, 15, 11), moduleCode: "BEM1015")]
        let focus = [FocusLogEntry(taskID: essayTask.id, title: "Essay", moduleCode: "BEE1022", kind: .writing,
                                   start: d(2026, 10, 14, 9), end: d(2026, 10, 14, 9, 45), minutes: 45),
                     FocusLogEntry(taskID: nil, title: "Report", moduleCode: "BEM1015", kind: .writing,
                                   start: d(2026, 10, 15, 9), end: d(2026, 10, 15, 11), minutes: 110)]
        let report = OnTrackReportBuilder(prefs: UserPrefs()).build(.init(
            modules: modules, assessments: assessments, readings: readings, notes: notes, lectures: lectures, homework: homework,
            tasks: [essayTask], blocks: blocks, focusLog: focus), now: now)

        let bee = report.modules.first { $0.moduleCode == "BEE1022" }!
        XCTAssertEqual(bee.readingsAssigned, 3) // week 9 isn't assigned yet
        XCTAssertEqual(bee.readingsDone, 1)
        XCTAssertEqual(bee.lecturesHeld, 2)
        XCTAssertEqual(bee.lecturesWithNotes, 1)
        XCTAssertEqual(bee.homeworkOverdue, ["Problem set 3"])
        XCTAssertEqual(bee.assessments.first?.progress ?? -1, 0.1, accuracy: 1e-9)
        XCTAssertEqual(bee.assessments.first?.status, .red) // 5 days left, 10% done
        XCTAssertEqual(bee.minutesPlanned, 180)
        XCTAssertEqual(bee.minutesDone, 45)
        XCTAssertEqual(bee.status, .red)
        XCTAssertEqual(bee.outlook, .stretch) // 58% on 20%: needs 73% on the rest
        XCTAssertEqual(bee.requiredOnRemaining ?? 0, 73, accuracy: 1e-9)
        XCTAssertTrue(bee.reasons.contains { $0.text.contains("1 of 2 lectures have notes") })

        let bem = report.modules.first { $0.moduleCode == "BEM1015" }!
        XCTAssertEqual(bem.lecturesWithNotes, 2)
        XCTAssertEqual(bem.homeworkDone, 1)
        XCTAssertEqual(bem.status, .green, bem.reasons.map(\.text).joined(separator: "; "))
        XCTAssertEqual(report.overall, .red)
        XCTAssertEqual(report.minutesDone, 155)
        XCTAssertFalse(report.topActions.isEmpty)
        XCTAssertTrue(report.plainText.contains("BEE1022 [red]"))
    }
}
