import XCTest
@testable import OrbitCore

final class ELEWebAssessmentTests: XCTestCase {
    let london = TimeZone(identifier: "Europe/London")!
    let ctx = ELEAssessmentExtractor.Context(moduleCode: "BEE1032", academicYear: 2026,
                                             sectionURL: "https://ele.exeter.ac.uk/course/section.php?id=701")

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = london
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    func testTableRows() {
        let rows = ELEAssessmentExtractor.tableRows(ELEWebFixtures.assessmentTable)
        XCTAssertEqual(rows.count, 9)
        XCTAssertEqual(rows[0], ["", "Assessment 1", "Assessment 2"])
        XCTAssertEqual(rows[7], ["Word Count/Time", "1500 words + 10%", "1½ hours"])
    }

    func testExtractFromTableAndBrief() {
        let out = ELEAssessmentExtractor.extract(sectionHTML: ELEWebFixtures.assessmentTable,
                                                 briefs: [ELEWebFixtures.briefText], context: ctx)
        XCTAssertEqual(out.count, 2)
        let essay = out[0]
        XCTAssertEqual(essay.assessment.id, "eleweb-BEE1032-a1")
        XCTAssertEqual(essay.assessment.title, "Essay")
        XCTAssertEqual(essay.assessment.kind, .essay)
        XCTAssertEqual(essay.assessment.weightPercent, 20)
        XCTAssertEqual(essay.assessment.wordCount, 1500)
        XCTAssertEqual(essay.assessment.due, date(2026, 11, 16, 15, 0))
        XCTAssertNil(essay.note)
        XCTAssertEqual(essay.aiStatus, "AI-assisted (declare use)")
        XCTAssertEqual(essay.format, "Word or PDF file via ELE")
        XCTAssertFalse(essay.formative)

        let exam = out[1]
        XCTAssertEqual(exam.assessment.kind, .exam)
        XCTAssertEqual(exam.assessment.weightPercent, 80)
        XCTAssertNil(exam.assessment.due)
        XCTAssertEqual(exam.durationMinutes, 90)
        XCTAssertNil(exam.assessment.wordCount)
        XCTAssertEqual(exam.note, "Due date TBA: week 1 of term2")
        XCTAssertTrue(exam.details.contains("1½ hours"))
    }

    func testWithoutBriefDefaultsToNoon() {
        let out = ELEAssessmentExtractor.extract(sectionHTML: ELEWebFixtures.assessmentTable, context: ctx)
        XCTAssertEqual(out[0].assessment.due, date(2026, 11, 16, 12, 0))
        XCTAssertNotNil(out[0].note)
    }

    func testSpringDeadlineGoesToNextYear() {
        let html = "<table><tr><td></td><td>Assessment 1</td></tr><tr><td>Deadline</td><td>12pm, 3rd March</td></tr><tr><td>Value</td><td>50%</td></tr><tr><td>Title</td><td>Report</td></tr></table>"
        let out = ELEAssessmentExtractor.extract(sectionHTML: html, context: ctx)
        XCTAssertEqual(out.first?.assessment.due, date(2027, 3, 3, 12, 0))
        XCTAssertEqual(out.first?.assessment.kind, .report)
    }

    func testFormativeHasNoWeight() {
        let html = "<table><tr><th></th><th>A1</th></tr><tr><td>Deadline</td><td>20 October</td></tr><tr><td>Title</td><td>practice essay plan</td></tr><tr><td>Formative/Summative</td><td>Formative</td></tr><tr><td>Value</td><td>0%</td></tr></table>"
        let out = ELEAssessmentExtractor.extract(sectionHTML: html, context: ctx)
        XCTAssertEqual(out.first?.formative, true)
        XCTAssertEqual(out.first?.assessment.weightPercent, 0)
    }

    func testNoTable() {
        XCTAssertTrue(ELEAssessmentExtractor.extract(sectionHTML: "<p>Assessment details to follow</p>", context: ctx).isEmpty)
    }

    func testTimeParsing() {
        XCTAssertEqual(ELEAssessmentExtractor.time(in: "3pm")?.hour, 15)
        XCTAssertEqual(ELEAssessmentExtractor.time(in: "by 12 noon")?.hour, 12)
        XCTAssertEqual(ELEAssessmentExtractor.time(in: "at 14:30")?.minute, 30)
        XCTAssertEqual(ELEAssessmentExtractor.time(in: "12am")?.hour, 0)
        XCTAssertEqual(ELEAssessmentExtractor.durationMinutes("2 hours"), 120)
        XCTAssertEqual(ELEAssessmentExtractor.durationMinutes("90 minutes"), 90)
        XCTAssertEqual(ELEAssessmentExtractor.dayMonth(in: "November 16th")?.day, 16)
    }

    func testMergeWithTimeline() {
        let table = ELEAssessmentExtractor.extract(sectionHTML: ELEWebFixtures.assessmentTable,
                                                   briefs: [ELEWebFixtures.briefText], context: ctx)
        let exact = date(2026, 11, 16, 15, 0)
        let events = [
            Assessment(id: "ele-assign-55502", moduleCode: "BEE1032", title: "HET Essay submission", kind: .essay, due: exact,
                       eleURL: "https://ele.exeter.ac.uk/mod/assign/view.php?id=990002"),
            Assessment(id: "ele-assign-55501", moduleCode: "BEE1036", title: "Problem Set 1", due: date(2026, 10, 20, 12)),
        ]
        let merged = ELEAssessmentExtractor.merge(table: table, events: events)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].assessment.id, "eleweb-BEE1032-a1")
        XCTAssertEqual(merged[0].assessment.eleURL, "https://ele.exeter.ac.uk/mod/assign/view.php?id=990002")
        XCTAssertEqual(merged[2].assessment.moduleCode, "BEE1036")
    }

    func testStudyCoachPlansTheEssay() throws {
        let essay = ELEAssessmentExtractor.extract(sectionHTML: ELEWebFixtures.assessmentTable,
                                                   briefs: [ELEWebFixtures.briefText], context: ctx)[0].assessment
        let now = date(2026, 9, 26, 10)
        let tasks = StudyCoach().planAssessment(essay, now: now)
        XCTAssertFalse(tasks.isEmpty)
        let due = try XCTUnwrap(essay.due)
        XCTAssertTrue(tasks.allSatisfy { ($0.deadline ?? .distantFuture) <= due })
        XCTAssertTrue(tasks.allSatisfy { $0.assessmentID == "eleweb-BEE1032-a1" && $0.moduleCode == "BEE1032" })
    }
}

final class ELEWebSnapshotTests: XCTestCase {
    func makeSnapshot(courseHTML: String = ELEWebFixtures.courseHTML) throws -> ELEWebSnapshot {
        let courses = try ELEWebParser.courses(fromAJAX: Data(ELEWebFixtures.coursesJSON.utf8))
        let split = ELEWebSnapshot.split(courses)
        let sections = ELEWebParser.sections(fromCourseHTML: courseHTML, academicYear: 2026)
        let content = ELEWebCourseContent(courseID: 29450, moduleCode: "BEE1032", sections: sections)
        let ctx = ELEAssessmentExtractor.Context(moduleCode: "BEE1032", academicYear: 2026)
        let table = ELEAssessmentExtractor.extract(sectionHTML: sections[1].html ?? "", briefs: [ELEWebFixtures.briefText], context: ctx)
        return ELEWebSnapshot(modules: split.modules, resourceCourses: split.resources, contents: ["BEE1032": content],
                              assessments: table)
    }

    func testConvertsToELESnapshot() throws {
        let snap = try makeSnapshot().eleSnapshot(credits: ["BEE1032": 15])
        XCTAssertEqual(snap.modules.count, 5)
        XCTAssertEqual(snap.modules.first { $0.code == "BEE1032" }?.eleCourseID, 29450)
        XCTAssertEqual(snap.assessments.count, 2)
        XCTAssertEqual(snap.readingItems.count, 2)
        XCTAssertTrue(snap.resources.contains { $0.id == "ele-cm-990101" && $0.kind == .file })
        XCTAssertEqual(snap.readingListURLs["BEE1032"]?.count, 1)
        XCTAssertEqual(snap.sectionTopics["BEE1032"]?.count, 3)
    }

    func testDiff() throws {
        let old = try makeSnapshot()
        var new = old
        XCTAssertTrue(ELEWebChanges.diff(from: old, to: new).isEmpty)
        XCTAssertTrue(ELEWebChanges.diff(from: nil, to: new).isInitial)

        // Week 12 gets slides, the essay moves a day and gains weight.
        let html = ELEWebFixtures.courseHTML.replacingOccurrences(
            of: ELEWebFixtures.section(15, id: 715, "Week 12 W/c 7 December", []),
            with: ELEWebFixtures.section(15, id: 715, "Week 12 W/c 7 December", [ELEWebFixtures.activity(991201, "resource", "Week 12 slides")]))
        new = try makeSnapshot(courseHTML: html)
        new.assessments[0].assessment.due = new.assessments[0].assessment.due?.addingTimeInterval(86400)
        new.assessments[0].assessment.weightPercent = 25
        let changes = ELEWebChanges.diff(from: old, to: new)
        XCTAssertEqual(changes.updatedWeeks.map(\.week), [12])
        XCTAssertEqual(changes.base.newResources.map(\.cmid), [991201])
        XCTAssertEqual(changes.base.changedDeadlines.count, 1)
        XCTAssertEqual(changes.changedAssessments.count, 1)
    }
}
