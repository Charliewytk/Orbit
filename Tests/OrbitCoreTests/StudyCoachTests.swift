import XCTest
@testable import OrbitCore

final class StudyCoachTests: XCTestCase {
    let coach = StudyCoach(prefs: UserPrefs(targetGrade: 70, timeZoneID: "Europe/London"))
    let now = ISO8601.parse("2026-10-05T09:00:00Z")!
    func days(_ n: Double) -> Date { now.addingTimeInterval(n * 86400) }

    // MARK: Standing

    func testModuleStandingMaths() {
        let m = Module(code: "BEM2031", name: "Analytics", credits: 15)
        let a = [
            Assessment(id: "a", moduleCode: "BEM2031", title: "Essay", kind: .essay, weightPercent: 40, mark: 65),
            Assessment(id: "b", moduleCode: "BEM2031", title: "Exam", kind: .exam, weightPercent: 60),
        ]
        let s = coach.moduleStanding(m, assessments: a)
        XCTAssertEqual(s.currentAverage, 65)
        XCTAssertEqual(s.markedWeight, 40)
        XCTAssertEqual(s.remainingWeight, 60)
        XCTAssertEqual(s.securedPoints, 26, accuracy: 1e-9)
        XCTAssertEqual(s.requiredAverageOnRemaining ?? 0, 73.333, accuracy: 0.001)
        XCTAssertEqual(s.outlook, .stretch)
    }

    func testOutlooks() {
        let m = Module(code: "X", name: "X")
        func outlook(_ marks: [(Double, Double?)]) -> ModuleStanding.Outlook {
            coach.moduleStanding(m, assessments: marks.enumerated().map {
                Assessment(id: "\($0.offset)", moduleCode: "X", title: "Essay \($0.offset)", kind: .essay, weightPercent: $0.element.0, mark: $0.element.1)
            }).outlook
        }
        XCTAssertEqual(outlook([(50, 75), (50, nil)]), .onTrack)
        XCTAssertEqual(outlook([(80, 90), (20, nil)]), .secured)
        XCTAssertEqual(outlook([(70, 30), (30, nil)]), .outOfReach)
        XCTAssertEqual(outlook([(100, 65)]), .missed)
        XCTAssertEqual(outlook([(100, nil)]), .onTrack)
    }

    func testUnstatedWeightsShareTheRemainder() {
        let a = [
            Assessment(id: "a", moduleCode: "X", title: "Essay (40%)", kind: .essay, weightPercent: 40),
            Assessment(id: "b", moduleCode: "X", title: "Exam", kind: .exam),
            Assessment(id: "c", moduleCode: "X", title: "Formative quiz", kind: .quiz),
        ]
        let w = coach.effectiveWeights(a)
        XCTAssertEqual(w["b"], 60)
        XCTAssertEqual(w["c"], 0)
        let over = coach.effectiveWeights([Assessment(id: "x", moduleCode: "X", title: "A", weightPercent: 80),
                                           Assessment(id: "y", moduleCode: "X", title: "B", weightPercent: 80)])
        XCTAssertEqual(over["x"], 50)
    }

    func testYearStandingWeightedByCredits() {
        let modules = [Module(code: "M1", name: "One", credits: 15), Module(code: "M2", name: "Two", credits: 30)]
        let a = [
            Assessment(id: "a", moduleCode: "M1", title: "Essay", kind: .essay, weightPercent: 40, mark: 65),
            Assessment(id: "b", moduleCode: "M1", title: "Exam", kind: .exam, weightPercent: 60),
            Assessment(id: "c", moduleCode: "M2", title: "Report", kind: .report, weightPercent: 50, mark: 80),
            Assessment(id: "d", moduleCode: "M2", title: "Exam", kind: .exam, weightPercent: 50),
        ]
        let y = coach.yearStanding(modules: modules, assessments: a)
        XCTAssertEqual(y.currentAverage ?? 0, 75, accuracy: 1e-9)
        // (70·45 − (15·26 + 30·40)) / (15·0.6 + 30·0.5) = 1560 / 24
        XCTAssertEqual(y.requiredAverageOnRemaining ?? 0, 65, accuracy: 1e-9)
    }

    // MARK: Priorities

    func testImpactRanksHeavyWorkAboveSmallUrgentWork() {
        let modules = [Module(code: "BIG", name: "Big", credits: 30), Module(code: "SMALL", name: "Small", credits: 15)]
        let essay = Assessment(id: "e", moduleCode: "BIG", title: "Essay", kind: .essay, weightPercent: 50, due: days(7))
        let quiz = Assessment(id: "q", moduleCode: "SMALL", title: "Quiz", kind: .quiz, weightPercent: 10, due: days(1))
        let done = Assessment(id: "d", moduleCode: "BIG", title: "Old", weightPercent: 50, due: days(2), submitted: true)
        XCTAssertEqual(coach.impactScore(essay, modules: modules, now: now), 50 * 30 / 45.0, accuracy: 1e-9)
        XCTAssertEqual(coach.impactScore(done, modules: modules, now: now), 0)
        XCTAssertEqual(coach.rank([quiz, essay, done], modules: modules, now: now).map(\.assessment.id), ["e", "q"])
        XCTAssertGreaterThan(coach.urgency(due: days(1), now: now), coach.urgency(due: days(20), now: now))
    }

    // MARK: Planning

    func testEssayPlanPhasesSumToEstimateAndPrecedeDeadline() throws {
        let essay = Assessment(id: "ele-assign-11", moduleCode: "BEM2031", title: "Essay", kind: .essay,
                               weightPercent: 50, due: days(30), wordCount: 2000)
        let estimate = coach.estimateMinutes(essay)
        XCTAssertEqual(estimate, 20 * 60) // 1h per 100 words at 50% weight

        let tasks = coach.planAssessment(essay, now: now)
        XCTAssertEqual(tasks.count, 6)
        XCTAssertEqual(tasks.reduce(0) { $0 + $1.estimateMinutes }, estimate)
        XCTAssertEqual(tasks.map { $0.title.components(separatedBy: " · ").last! },
                       ["Understand brief & gather sources", "Read & take notes", "Outline", "Draft",
                        "Edit & reference check", "Final proofread & submit"])
        let due = try XCTUnwrap(essay.due)
        var last = now
        for t in tasks {
            let deadline = try XCTUnwrap(t.deadline)
            let start = try XCTUnwrap(t.earliestStart)
            XCTAssertLessThanOrEqual(deadline, due)
            XCTAssertGreaterThanOrEqual(deadline, last, "deadlines are staggered in order")
            XCTAssertLessThan(start, deadline)
            XCTAssertGreaterThanOrEqual(start, now)
            XCTAssertEqual(t.moduleCode, "BEM2031")
            XCTAssertEqual(t.assessmentID, "ele-assign-11")
            XCTAssertEqual(t.source, .ele)
            last = deadline
        }
        XCTAssertEqual(tasks[3].energy, .high) // drafting
        XCTAssertEqual(tasks[1].estimateMinutes, 360) // 30% reading
        // Outline due around 40% of the way to the deadline.
        let outlineFraction = tasks[2].deadline!.timeIntervalSince(now) / due.timeIntervalSince(now)
        XCTAssertEqual(outlineFraction, 0.42, accuracy: 0.05)
        // Later phases don't start straight away.
        XCTAssertGreaterThan(tasks[3].earliestStart!, days(8))
    }

    func testOtherKindsPlanWithinWindow() throws {
        for kind in [AssessmentKind.exam, .presentation, .quiz, .groupwork, .coursework] {
            let a = Assessment(id: "x", moduleCode: "M", title: "Thing", kind: kind, weightPercent: 30, due: days(21))
            let tasks = coach.planAssessment(a, now: now)
            XCTAssertFalse(tasks.isEmpty)
            XCTAssertEqual(tasks.reduce(0) { $0 + $1.estimateMinutes }, coach.estimateMinutes(a), "\(kind)")
            for t in tasks {
                XCTAssertLessThanOrEqual(try XCTUnwrap(t.deadline), a.due!, "\(kind)")
                XCTAssertGreaterThan(t.estimateMinutes, 0)
            }
        }
        let exam = coach.planAssessment(Assessment(id: "x", moduleCode: "M", title: "Exam", kind: .exam, weightPercent: 60, due: days(60)), now: now)
        XCTAssertTrue(exam.contains { $0.title.contains("Past paper") })
        XCTAssertTrue(exam.filter { $0.title.contains("Revision session") }.allSatisfy { $0.energy == .high })
        // Sessions bunch up towards the exam.
        let sessionDeadlines = exam.filter { $0.title.contains("Revision session") }.compactMap(\.deadline)
        let firstGap = sessionDeadlines[1].timeIntervalSince(sessionDeadlines[0])
        let lastGap = sessionDeadlines[sessionDeadlines.count - 1].timeIntervalSince(sessionDeadlines[sessionDeadlines.count - 2])
        XCTAssertGreaterThan(firstGap, lastGap)
    }

    func testPlanEdgeCases() {
        let submitted = Assessment(id: "s", moduleCode: "M", title: "Done", due: days(3), submitted: true)
        XCTAssertTrue(coach.planAssessment(submitted, now: now).isEmpty)
        let overdue = Assessment(id: "o", moduleCode: "M", title: "Late", kind: .essay, due: days(-1))
        let late = coach.planAssessment(overdue, now: now)
        XCTAssertEqual(late.count, 1)
        XCTAssertEqual(late.first?.priority, .critical)
        let undated = coach.planAssessment(Assessment(id: "u", moduleCode: "M", title: "Portfolio", kind: .coursework), now: now)
        XCTAssertTrue(undated.allSatisfy { $0.deadline == nil })
        let tight = coach.planAssessment(Assessment(id: "t", moduleCode: "M", title: "Essay", kind: .essay, weightPercent: 20, due: days(1.5)), now: now)
        XCTAssertTrue(tight.allSatisfy { $0.deadline! <= days(1.5) && $0.priority == .critical })
    }

    // MARK: Weekly review

    func testWeeklyReviewFlagsGapsAndSuggestsActions() async throws {
        let modules = [Module(code: "BEM2031", name: "Business Analytics", credits: 15)]
        let essay = Assessment(id: "e", moduleCode: "BEM2031", title: "Essay", kind: .essay, weightPercent: 40, due: days(10), wordCount: 2000)
        let readings = [
            ReadingItem(id: "r1", moduleCode: "BEM2031", title: "Core text ch.1", essential: true, week: 1, done: true),
            ReadingItem(id: "r2", moduleCode: "BEM2031", title: "Core text ch.2", essential: true, week: 2),
            ReadingItem(id: "r3", moduleCode: "BEM2031", title: "Optional paper", essential: false, week: 2),
        ]
        let lectures = [
            CalendarEvent(title: "BEM2031 Lecture", start: days(-4), end: days(-4).addingTimeInterval(3600), source: .timetable),
            CalendarEvent(title: "BEM2031 Lecture", start: days(-2), end: days(-2).addingTimeInterval(3600), source: .timetable),
            CalendarEvent(title: "BEM2031 Seminar", start: days(-1), end: days(-1).addingTimeInterval(3600), source: .timetable),
        ]
        let notes = [LectureNote(id: "n1", title: "Regression", moduleCode: "BEM2031", created: days(-4).addingTimeInterval(1800),
                                 segments: [NoteSegment(kind: .handwriting, text: "…")])]
        let review = coach.weeklyReview(modules: modules, assessments: [essay], readings: readings, notes: notes,
                                        lectures: lectures, now: now)
        let m = try XCTUnwrap(review.modules.first)
        XCTAssertEqual(m.readingsDone, 1)
        XCTAssertEqual(m.readingsTotal, 3)
        XCTAssertEqual(m.essentialOutstanding, ["Core text ch.2"])
        XCTAssertEqual(m.lectures.count, 2) // seminar excluded
        XCTAssertEqual(m.lecturesWithNotes, 1)
        XCTAssertFalse(m.lectures[0].hasTypedSummary)
        XCTAssertEqual(m.upcomingDeadlines.map(\.id), ["e"])
        XCTAssertEqual(m.hoursPlanned, 0)
        XCTAssertGreaterThan(m.hoursNeeded, 10)
        XCTAssertEqual(m.status, .amber)
        XCTAssertTrue(m.reasons.contains { $0.contains("No plan yet") })
        XCTAssertEqual(review.topActions.count, 3)
        XCTAssertTrue(review.topActions[0].hasPrefix("Plan and start Essay"), review.topActions[0])
        XCTAssertTrue(review.topActions.contains { $0.contains("Write up notes") })
        XCTAssertTrue(review.plainSummary.contains("BEM2031"))

        // With a plan in place and blocks scheduled, the plan gap goes away.
        let tasks = coach.planAssessment(essay, now: now)
        let blocks = tasks.map { ScheduledBlock(taskID: $0.id, title: $0.title, start: days(1),
                                                end: days(1).addingTimeInterval(Double($0.estimateMinutes) * 60), moduleCode: "BEM2031") }
        let planned = coach.weeklyReview(modules: modules, assessments: [essay], readings: readings, notes: notes,
                                         lectures: lectures, tasks: tasks, blocks: blocks, now: now)
        XCTAssertFalse(planned.modules[0].reasons.contains { $0.contains("No plan yet") || $0.contains("planned of") })

        // Narration goes through the router with the review data.
        let provider = MockLLMProvider { req in
            XCTAssertTrue(req.messages[0].text.contains("UK English"))
            XCTAssertTrue(req.messages[1].text.contains("BEM2031"))
            return "You're nearly there."
        }
        let text = try await review.narrate(using: LLMRouter(providers: [provider]))
        XCTAssertEqual(text, "You're nearly there.")
    }

    func testRedWhenFirstNeedsTooMuch() {
        let modules = [Module(code: "M", name: "M")]
        let a = [Assessment(id: "a", moduleCode: "M", title: "Essay", kind: .essay, weightPercent: 50, mark: 55),
                 Assessment(id: "b", moduleCode: "M", title: "Exam", kind: .exam, weightPercent: 50, due: days(60))]
        let review = coach.weeklyReview(modules: modules, assessments: a, readings: [], notes: [], lectures: [], now: now)
        XCTAssertEqual(review.status, .red)
        XCTAssertTrue(review.modules[0].reasons.contains { $0.contains("85%") })
    }
}
