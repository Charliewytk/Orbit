import XCTest
@testable import OrbitCore

final class NoteActionExtractorTests: XCTestCase {
    /// OCR of a real Notability page (Introduction to Statistics, week 1).
    static let statsPage = """
    Week 1 Monday, 21 September 2026
    ELE mind to statistics chapter 1
    Population → Sample
    Population = everything
    last year exams library…
    DATA INSTITUTIONAL ACCESS → ask guy at end
    homework: read chapter 1 "minds …" consider issues in each case
    get good with excel… week 6 & … find some excel course… ELE or YT → check AI usage for it
    Quiz… once per week
    """

    let cal = AcademicCalendar.exeter
    var monday: Date { cal.date(term: 1, week: 1, weekday: 1, hour: 10)! }

    func note(_ text: String, kind: NoteSegmentKind = .handwriting) -> LectureNote {
        LectureNote(id: "file:Year 1 Economics/Introduction to Statistics/Week 1.pdf", title: "Week 1", notebook: "Notability",
                    section: "Introduction to Statistics", moduleCode: "BEE1022", week: 1, created: monday, modified: monday,
                    segments: [NoteSegment(kind: kind, text: text, confidence: 0.8)])
    }

    func testFindsTheActionsOnTheStatsPage() {
        let actions = NoteActionExtractor(calendar: cal).extract(from: note(Self.statsPage))
        XCTAssertEqual(actions.map(\.kind), [.ask, .homework, .skill, .recurring], actions.map(\.title).description)

        let ask = actions[0]
        XCTAssertEqual(ask.title, "Ask guy at end about data institutional access")
        XCTAssertFalse(ask.autoAdd)

        let hw = actions[1]
        XCTAssertTrue(hw.title.hasPrefix("Read chapter 1"), hw.title)
        XCTAssertTrue(hw.title.contains("consider issues in each case"), hw.title)
        XCTAssertTrue(hw.autoAdd)
        // No date written: due at the start of week 2 (inferred).
        XCTAssertEqual(hw.due, cal.date(term: 1, week: 2, weekday: 1, hour: 9))
        XCTAssertTrue(hw.dueInferred)
        let task = hw.task()
        XCTAssertEqual(task.origin, .required)
        XCTAssertEqual(task.moduleCode, "BEE1022")
        XCTAssertEqual(task.source, .notes)

        let excel = actions[2]
        XCTAssertTrue(excel.title.hasPrefix("Get good with Excel"), excel.title)
        XCTAssertTrue(excel.title.contains("YouTube"), excel.title)
        XCTAssertEqual(excel.due, cal.date(term: 1, week: 6, weekday: 5, hour: 17))
        XCTAssertFalse(excel.dueInferred)
        XCTAssertEqual(excel.task().origin, .recommended)

        let quiz = actions[3]
        XCTAssertEqual(quiz.recurrence, "weekly")
        XCTAssertEqual(quiz.title, "Quiz once per week")
    }

    func testLectureContentIsNotAnAction() {
        let actions = NoteActionExtractor(calendar: cal).extract(from: note(Self.statsPage))
        let titles = actions.map { $0.title.lowercased() }
        XCTAssertFalse(titles.contains { $0.contains("population") })
        XCTAssertFalse(titles.contains { $0.contains("week 1 monday") })
        XCTAssertFalse(titles.contains { $0.contains("library") })
    }

    func testOtherTriggers() {
        let text = """
        HW - problem sheet 2 due Fri 2 Oct
        ☐ print lecture slides
        - [ ] email tutor re extension
        todo: sign up for PASS
        remember to bring calculator
        need to revise log rules
        read ch. 3 before Thursday
        """
        let actions = NoteActionExtractor(calendar: cal).extract(from: note(text))
        XCTAssertEqual(actions.map(\.kind), [.homework, .todo, .todo, .todo, .reminder, .reminder, .reading])
        XCTAssertEqual(actions[0].title, "Problem sheet 2 due Fri 2 Oct")
        XCTAssertFalse(actions[0].dueInferred)
        XCTAssertEqual(DayCalendar(timeZone: cal.timeZone).format(actions[0].due!, "yyyy-MM-dd"), "2026-10-02")
        XCTAssertEqual(actions[1].title, "Print lecture slides")
        XCTAssertEqual(actions[3].title, "Sign up for PASS")
        XCTAssertTrue(actions[6].title.hasPrefix("Read chapter 3"), actions[6].title)
    }

    func testWrappedHomeworkLineIsJoined() {
        let text = "homework: read chapter 2\nand do questions 1-4\nMean = sum / n"
        let actions = NoteActionExtractor(calendar: cal).extract(from: note(text))
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].title, "Read chapter 2 and do questions 1-4")
    }

    func testKeysSurviveSmallOCRChanges() {
        let a = NoteActionExtractor(calendar: cal).extract(from: note("homework: read chapter 1 consider issues in each case"))
        let b = NoteActionExtractor(calendar: cal).extract(from: note("Homework - read Chapter 1, consider the issues in each case"))
        XCTAssertEqual(a.count, 1); XCTAssertEqual(b.count, 1)
        XCTAssertTrue(NoteActionExtractor.isSame(a[0], b[0]))
    }

    func testLedgerDeduplicatesAcrossRescans() {
        let ex = NoteActionExtractor(calendar: cal)
        let n = note(Self.statsPage)
        var ledger = NoteActionLedger()
        let first = ledger.record(ex.extract(from: n), noteID: n.id, now: monday)
        XCTAssertEqual(first.toAdd.map(\.kind), [.homework])
        XCTAssertEqual(first.newSuggestions.count, 3)
        XCTAssertEqual(ledger.suggestions.count, 3)

        // Same page again, slightly different OCR: nothing new.
        let rescan = note(Self.statsPage.replacingOccurrences(of: "homework: read chapter 1", with: "Homework: Read chapter 1"))
        let second = ledger.record(ex.extract(from: rescan), noteID: n.id, now: monday.addingTimeInterval(60))
        XCTAssertTrue(second.toAdd.isEmpty)
        XCTAssertTrue(second.newSuggestions.isEmpty)

        // Dismissed stays dismissed.
        let quiz = ledger.suggestions.first { $0.kind == .recurring }!
        ledger.mark(quiz.key, .dismissed)
        _ = ledger.record(ex.extract(from: n), noteID: n.id)
        XCTAssertEqual(ledger.suggestions.count, 2)

        // A suggestion erased from the page disappears.
        let trimmed = note(Self.statsPage.replacingOccurrences(of: "DATA INSTITUTIONAL ACCESS → ask guy at end", with: ""))
        _ = ledger.record(ex.extract(from: trimmed), noteID: n.id)
        XCTAssertEqual(ledger.suggestions.map(\.kind), [.skill])
    }

    func testLocalModelRefinesAndAddsGroundedItems() async {
        let llm = MockLLMProvider(isLocal: true) { req in
            XCTAssertEqual(req.purpose, .privateData)
            return """
            {"items":[
              {"title":"Find last year's exams in the library","kind":"todo","line":"last year exams library…"},
              {"title":"Buy a new laptop","kind":"todo","line":"buy laptop"},
              {"title":"Quiz yourself once a week","kind":"recurring","line":"Quiz… once per week"}
            ]}
            """
        }
        let ex = NoteActionExtractor(calendar: cal)
        let n = note(Self.statsPage)
        let refined = await ex.refine(ex.extract(from: n), note: n, router: LLMRouter(providers: [llm]))
        XCTAssertTrue(refined.contains { $0.title == "Find last year's exams in the library" && $0.source == "ai" && !$0.autoAdd })
        XCTAssertFalse(refined.contains { $0.title.contains("laptop") }, "ungrounded items are dropped")
        XCTAssertEqual(refined.filter { $0.kind == .recurring }.count, 1)
        XCTAssertEqual(refined.first { $0.kind == .recurring }?.title, "Quiz yourself once a week")
    }

    func testLocalModelFailureKeepsRules() async {
        let llm = MockLLMProvider(isLocal: true) { _ in "not json" }
        let ex = NoteActionExtractor(calendar: cal)
        let n = note(Self.statsPage)
        let rules = ex.extract(from: n)
        let refined = await ex.refine(rules, note: n, router: LLMRouter(providers: [llm]))
        XCTAssertEqual(refined, rules)
    }
}

final class PDFTextLayerPolicyTests: XCTestCase {
    func testHeaderOnlyTextStillNeedsOCR() {
        XCTAssertNil(PDFTextLayerPolicy.meaningfulText("Week 1 Monday, 21 September 2026\n3"))
        XCTAssertEqual(PDFTextLayerPolicy.plan(text: "Week 1 Monday, 21 September 2026", inkOutsideText: 0.05), .ocrPage)
        XCTAssertEqual(PDFTextLayerPolicy.plan(text: nil, inkOutsideText: nil), .ocrPage)
    }

    func testTypedPagesSkipOCR() {
        let typed = "Population is everything we care about.\nA sample is the part we measure."
        XCTAssertNotNil(PDFTextLayerPolicy.meaningfulText(typed))
        XCTAssertEqual(PDFTextLayerPolicy.plan(text: typed, inkOutsideText: 0.0005), .textOnly)
        // Typed text box plus handwriting around it: keep the text, OCR the rest.
        XCTAssertEqual(PDFTextLayerPolicy.plan(text: typed, inkOutsideText: 0.03), .textPlusOCR)
        XCTAssertEqual(PDFTextLayerPolicy.plan(text: typed, inkOutsideText: nil), .textPlusOCR)
    }

    func testBrokenFontMappingIsIgnored() {
        XCTAssertNil(PDFTextLayerPolicy.meaningfulText("\u{E001}\u{E002}\u{E003}\u{E004} \u{E005}\u{E006} ab cd"))
    }
}
