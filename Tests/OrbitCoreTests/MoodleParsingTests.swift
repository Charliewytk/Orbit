import XCTest
@testable import OrbitCore

final class MoodleParsingTests: XCTestCase {
    func testWeightParsing() {
        XCTAssertEqual(AssessmentParsing.weightPercent(in: "Individual essay (40%)"), 40)
        XCTAssertEqual(AssessmentParsing.weightPercent(in: "This assignment is worth 30% of the module"), 30)
        XCTAssertEqual(AssessmentParsing.weightPercent(in: "Weighting: 50%"), 50)
        XCTAssertEqual(AssessmentParsing.weightPercent(in: "weighted at 12.5%"), 12.5)
        XCTAssertEqual(AssessmentParsing.weightPercent(in: "It counts for 60% of the module mark."), 60)
        XCTAssertNil(AssessmentParsing.weightPercent(in: "Aim for 100% attendance"))
        XCTAssertEqual(AssessmentParsing.weightFromTitle("Coursework 1 - 25%"), 25)
        XCTAssertNil(AssessmentParsing.weightFromTitle("Reflective log"))
    }

    func testWordCountParsing() {
        XCTAssertEqual(AssessmentParsing.wordCount(in: "Write a 2,000 words essay"), 2000)
        XCTAssertEqual(AssessmentParsing.wordCount(in: "A 2000-word report"), 2000)
        XCTAssertEqual(AssessmentParsing.wordCount(in: "Word limit: 2,500"), 2500)
        XCTAssertEqual(AssessmentParsing.wordCount(in: "between 1500–2000 words"), 2000)
        XCTAssertEqual(AssessmentParsing.wordCount(in: "word count of 3000"), 3000)
        XCTAssertNil(AssessmentParsing.wordCount(in: "Due at 12:00 on 5 words"))
    }

    func testKindGuessing() {
        XCTAssertEqual(AssessmentParsing.kind(title: "Individual Essay (40%)"), .essay)
        XCTAssertEqual(AssessmentParsing.kind(title: "Summer examination"), .exam)
        XCTAssertEqual(AssessmentParsing.kind(title: "Group presentation"), .presentation)
        XCTAssertEqual(AssessmentParsing.kind(title: "Group report"), .report)
        XCTAssertEqual(AssessmentParsing.kind(title: "Week 3 MCQ"), .quiz)
        XCTAssertEqual(AssessmentParsing.kind(title: "Group project work"), .report)
        XCTAssertEqual(AssessmentParsing.kind(title: "Group work"), .groupwork)
        XCTAssertEqual(AssessmentParsing.kind(title: "Assignment 2", brief: "Write a reflective essay"), .essay)
        XCTAssertEqual(AssessmentParsing.kind(title: "Portfolio"), .coursework)
    }

    func testModuleCodesAndNames() {
        XCTAssertEqual(ModuleCode.find(in: "BEM2031 - Business Analytics 2026/7"), "BEM2031")
        XCTAssertEqual(ModuleCode.find(in: "BEM2031_2026"), "BEM2031")
        XCTAssertEqual(ModuleCode.find(in: "BEMM461 Dissertation"), "BEMM461")
        XCTAssertNil(ModuleCode.find(in: "Business School Hub"))
        XCTAssertEqual(ModuleCode.name(from: "BEM2031 - Business Analytics 2026/7", code: "BEM2031"), "Business Analytics")
        XCTAssertEqual(ModuleCode.name(from: "BEM2024: Accounting (2026-27)", code: "BEM2024"), "Accounting")
    }

    func testHTMLToText() {
        XCTAssertEqual(UniHTML.text("<p>Hello&nbsp;<b>world</b> &amp; co</p><ul><li>One</li><li>Two</li></ul>"),
                       "Hello world & co\n• One\n• Two")
        XCTAssertEqual(UniHTML.decodeEntities("&#8220;Hi&#x201D; &pound;5"), "“Hi” £5")
    }

    func testDeadlineTitleCleanup() {
        XCTAssertEqual(ELEMapping.cleanDeadlineTitle("Essay 1 is due"), "Essay 1")
        XCTAssertEqual(ELEMapping.cleanDeadlineTitle("Week 3 quiz closes"), "Week 3 quiz")
        XCTAssertEqual(ELEMapping.cleanDeadlineTitle("Report - deadline"), "Report")
    }
}
