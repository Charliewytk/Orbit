import XCTest
@testable import OrbitCore

final class RevisionPlannerTests: XCTestCase {
    let prefs = UserPrefs(timeZoneID: "Europe/London")
    let now = ISO8601.parse("2027-04-20T09:00:00Z")!

    func testSpacedReviewsCountDownToExam() throws {
        let examStart = ISO8601.parse("2027-05-12T09:00:00Z")!
        let exam = Assessment(id: "ex", moduleCode: "BEM2031", title: "BEM2031 Exam", kind: .exam, weightPercent: 60, due: examStart)
        let topics = ["Regression", "Forecasting", "Clustering"]
        let tasks = RevisionPlanner(prefs: prefs).plan(exams: [.init(assessment: exam, topics: topics)], now: now)

        XCTAssertEqual(tasks.filter { $0.title.contains("Learn:") }.count, 3)
        XCTAssertEqual(tasks.filter { $0.title.contains("Review:") }.count, 12) // 3 topics × 4 reviews
        XCTAssertEqual(tasks.filter { $0.title.contains("Past paper") }.count, 2)
        for t in tasks {
            let deadline = try XCTUnwrap(t.deadline)
            XCTAssertLessThan(deadline, examStart)
            XCTAssertGreaterThan(deadline, now)
            XCTAssertLessThan(try XCTUnwrap(t.earliestStart), deadline)
            XCTAssertEqual(t.assessmentID, "ex")
        }
        // Each topic is learnt before its first review, and reviewed the day before.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = prefs.timeZone
        let dayBefore = examStart.addingTimeInterval(-86400)
        for topic in topics {
            let learn = try XCTUnwrap(tasks.first { $0.title.hasSuffix("Learn: \(topic)") })
            let reviews = tasks.filter { $0.title.contains("Review: \(topic) ") }
            XCTAssertEqual(reviews.count, 4)
            XCTAssertTrue(reviews.allSatisfy { $0.deadline! > learn.deadline! })
            XCTAssertTrue(reviews.contains { cal.isDate($0.deadline!, inSameDayAs: dayBefore) })
        }
        // Alternate topics are staggered so reviews don't all land on one day.
        let fortnight = tasks.filter { $0.title.contains("(14d before)") || $0.title.contains("(15d before)") }.compactMap(\.deadline)
        XCTAssertEqual(Set(fortnight.map { cal.startOfDay(for: $0) }).count, 2)
        // Output is ordered by deadline for the scheduler.
        XCTAssertEqual(tasks.compactMap(\.deadline), tasks.compactMap(\.deadline).sorted())
    }

    func testShortRunUpDropsReviewsThatHavePassed() {
        let exam = Assessment(id: "ex", moduleCode: "M", title: "Exam", kind: .exam, due: now.addingTimeInterval(5 * 86400))
        let tasks = RevisionPlanner(prefs: prefs).plan(exams: [.init(assessment: exam, topics: ["A", "B"])], now: now)
        XCTAssertEqual(tasks.filter { $0.title.contains("Learn:") }.count, 2)
        XCTAssertFalse(tasks.contains { $0.title.contains("14d") || $0.title.contains("7d") })
        XCTAssertTrue(tasks.allSatisfy { $0.deadline! > now && $0.deadline! < exam.due! })
    }

    func testCoachDelegatesExamsWithTopics() {
        let exam = Assessment(id: "ex", moduleCode: "M", title: "Exam", kind: .exam, due: now.addingTimeInterval(30 * 86400))
        let tasks = StudyCoach(prefs: prefs).planAssessment(exam, now: now, topics: ["A"])
        XCTAssertTrue(tasks.contains { $0.title.contains("Learn: A") })
    }

    func testTopicsFromSectionsAndNotes() {
        XCTAssertEqual(RevisionPlanner.topics(fromSections: ["General", "Week 1: Regression", "Assessment information", "Week 2: Forecasting", "week 1: regression"]),
                       ["Week 1: Regression", "Week 2: Forecasting"])
        let notes = [LectureNote(id: "2", title: "Forecasting", moduleCode: "M", created: now),
                     LectureNote(id: "1", title: "Regression", moduleCode: "M", created: now.addingTimeInterval(-86400)),
                     LectureNote(id: "3", title: "Other", moduleCode: "X", created: now)]
        XCTAssertEqual(RevisionPlanner.topics(fromNotes: notes, moduleCode: "M"), ["Regression", "Forecasting"])
    }
}
