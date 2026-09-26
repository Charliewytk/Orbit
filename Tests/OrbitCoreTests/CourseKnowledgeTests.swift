import XCTest
@testable import OrbitCore

/// Shared fixtures: an Intro to Statistics (BEE1022) course page with a homework sheet
/// "due end of week 2", lecture slides, and a timetable.
enum AcademicFixtures {
    static var london: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }

    static func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        london.date(from: DateComponents(year: y, month: m, day: day, hour: h, minute: min))!
    }

    static let slidesWeek2 = SlideDeckText(slides: [
        SlideText(number: 1, title: "BEE1022 Introduction to Statistics", lines: ["Lecture 2"]),
        SlideText(number: 2, title: "Outline", lines: ["Probability", "Random variables"]),
        SlideText(number: 3, title: "Probability rules", lines: ["Addition rule for events", "Multiplication rule for independent events"]),
        SlideText(number: 4, title: "Random variables", lines: ["Discrete random variables", "Expected value and variance"]),
        SlideText(number: 5, title: "Sampling distributions", lines: ["Sample mean has its own distribution", "Standard error of the sample mean"]),
        SlideText(number: 6, title: "Sampling distributions (cont.)", lines: ["Standard error shrinks with sample size"]),
        SlideText(number: 7, title: "Central limit theorem", lines: ["Sample mean approximately normal for large n"]),
    ])

    static func content() -> ELEWebCourseContent {
        let week1 = ELEWebSection(id: 101, number: 1, title: "Week 1 W/c 21 September: Describing data", kind: .week, week: 1,
                                  weekCommencing: d(2026, 9, 21), url: "https://ele.exeter.ac.uk/course/section.php?id=101",
                                  summary: "Lectures on Tuesday and Thursday.", items: [
                                      ELEWebItem(cmid: 5000, name: "Lecture 1 slides", kind: .resource, role: .slides,
                                                 url: "https://ele.exeter.ac.uk/mod/resource/view.php?id=5000"),
                                      ELEWebItem(cmid: 5010, name: "Homework", kind: .label, text: "HW stats sheet – due end of week 2. Submit on paper in the tutorial."),
                                      ELEWebItem(cmid: 5001, name: "HW stats sheet", kind: .resource, role: .handout,
                                                 url: "https://ele.exeter.ac.uk/mod/resource/view.php?id=5001"),
                                      ELEWebItem(cmid: 5002, name: "HW stats sheet solutions", kind: .resource, role: .handout,
                                                 url: "https://ele.exeter.ac.uk/mod/resource/view.php?id=5002"),
                                  ])
        let week2 = ELEWebSection(id: 102, number: 2, title: "Week 2 W/c 28 September: Probability", kind: .week, week: 2,
                                  weekCommencing: d(2026, 9, 28), items: [
                                      ELEWebItem(cmid: 5003, name: "Lecture 2 slides", kind: .resource, role: .slides,
                                                 url: "https://ele.exeter.ac.uk/mod/resource/view.php?id=5003"),
                                      ELEWebItem(cmid: 5004, name: "Week 2 practice quiz", kind: .quiz,
                                                 url: "https://ele.exeter.ac.uk/mod/quiz/view.php?id=5004"),
                                      ELEWebItem(cmid: 5011, name: "Prep", kind: .label,
                                                 text: "Please read chapter 3 of Newbold before the week 3 lecture."),
                                  ])
        let assessment = ELEWebSection(id: 100, number: 0, title: "Assessment", kind: .assessment, items: [
            ELEWebItem(cmid: 5020, name: "Coursework brief", kind: .resource, role: .assessmentBrief),
        ])
        return ELEWebCourseContent(courseID: 9001, moduleCode: "BEE1022", sections: [assessment, week1, week2])
    }

    static func snapshot() -> ELEWebSnapshot {
        var snap = ELEWebSnapshot(fetchedAt: d(2026, 9, 26, 12))
        snap.modules = [ELEWebCourse(id: 9001, fullName: "Introduction to Statistics (BEE1022_A_1_202627)",
                                     shortName: "BEE1022_A_1_202627", viewURL: "https://ele.exeter.ac.uk/course/view.php?id=9001")]
        snap.contents["BEE1022"] = content()
        snap.assessments = [ELEWebAssessment(assessment: Assessment(id: "eleweb-BEE1022-a1", moduleCode: "BEE1022", title: "Data project",
                                                                    kind: .report, weightPercent: 30, due: d(2026, 10, 8, 12)))]
        return snap
    }

    static let sheetText = """
    BEE1022 Homework 1
    Question 1. Compute the mean and median of the data below.
    Question 2. Draw a histogram and comment on its shape.
    Question 3. Find the sample variance.
    """

    static func knowledge() -> CourseKnowledgeBase {
        var kb = CourseKnowledgeBase()
        let snap = snapshot()
        kb.update(from: snap)
        kb.upsert(CourseDocument(id: "ele-cm-5003", moduleCode: "BEE1022", term: 1, week: 2, kind: .slides, title: "Lecture 2 slides",
                                 cmid: 5003, text: slidesWeek2.text))
        kb.upsert(CourseDocument(id: "ele-cm-5001", moduleCode: "BEE1022", term: 1, week: 1, kind: .homework, title: "HW stats sheet",
                                 cmid: 5001, text: sheetText))
        kb.homework = HomeworkDetector(calendar: .exeter, now: d(2026, 9, 26, 12))
            .detect(snapshot: snap, texts: [5001: sheetText])
        kb.timetable = [
            CalendarEvent(id: "lec1", title: "BEE1022 Introduction to Statistics - Lecture", start: d(2026, 9, 22, 10), end: d(2026, 9, 22, 11), source: .timetable),
            CalendarEvent(id: "lec1", title: "BEE1022 Introduction to Statistics - Lecture", start: d(2026, 9, 29, 10), end: d(2026, 9, 29, 11), source: .timetable),
            CalendarEvent(id: "tut1", title: "BEE1022 Tutorial", start: d(2026, 10, 1, 14), end: d(2026, 10, 1, 15), source: .timetable),
        ]
        return kb
    }
}

final class OfficeTextTests: XCTestCase {
    func testPPTXSlidesAndNotes() {
        let slide = """
        <p:sld><p:cSld><p:spTree>
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>Sampling </a:t></a:r><a:r><a:t>distributions</a:t></a:r></a:p></p:txBody></p:sp>
        <p:sp><p:nvSpPr><p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:pPr lvl="0"/><a:r><a:t>Mean &amp; variance</a:t></a:r></a:p><a:p><a:r><a:t>Standard</a:t></a:r><a:br/><a:r><a:t>error</a:t></a:r></a:p><a:p></a:p></p:txBody></p:sp>
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="sldNum"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>12</a:t></a:r></a:p></p:txBody></p:sp>
        </p:spTree></p:cSld></p:sld>
        """
        let second = "<p:sld><p:sp><p:txBody><a:p><a:r><a:t>Summary slide</a:t></a:r></a:p><a:p><a:r><a:t>Point one</a:t></a:r></a:p></p:txBody></p:sp></p:sld>"
        let notes = """
        <p:notes><p:sp><p:nvSpPr><p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr></p:sp>
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>Stress the CLT link.</a:t></a:r></a:p></p:txBody></p:sp></p:notes>
        """
        let deck = PPTXText.extract(slideXMLs: [slide, second], notesXMLs: [notes, nil])
        XCTAssertEqual(deck.slides.count, 2)
        XCTAssertEqual(deck.slides[0].title, "Sampling distributions")
        XCTAssertEqual(deck.slides[0].lines, ["Mean & variance", "Standard error"])
        XCTAssertEqual(deck.slides[0].notes, "Stress the CLT link.")
        XCTAssertEqual(deck.slides[1].title, "Summary slide")
        XCTAssertEqual(deck.slides[1].lines, ["Point one"])
        XCTAssertTrue(deck.text.hasPrefix("# Slide 1: Sampling distributions\nMean & variance"))
        // Round trip through the indexed text format.
        XCTAssertEqual(SlideDeckText.parse(deck.text), deck)
    }

    func testSlideOrder() {
        let paths = ["ppt/slides/slide10.xml", "ppt/slides/slide2.xml", "ppt/slides/_rels/slide1.xml.rels", "ppt/slides/slide1.xml", "ppt/slideLayouts/slideLayout1.xml"]
        XCTAssertEqual(PPTXText.orderedSlidePaths(paths), ["ppt/slides/slide1.xml", "ppt/slides/slide2.xml", "ppt/slides/slide10.xml"])
        XCTAssertEqual(PPTXText.orderedSlidePaths(["ppt/notesSlides/notesSlide3.xml"], folder: "ppt/notesSlides/", prefix: "notesSlide"),
                       ["ppt/notesSlides/notesSlide3.xml"])
    }

    func testXLSX() {
        let shared = "<sst><si><t>Name</t></si><si><r><t>Mark</t></r></si><si><t>Ann</t></si></sst>"
        let sheet = """
        <worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" s="1"/><c r="C2"><v>67</v></c></row></sheetData></worksheet>
        """
        XCTAssertEqual(XLSXText.extract(sharedStringsXML: shared, sheetXMLs: [sheet]), "# Sheet 1\nName | Mark\nAnn | 67")
    }

    func testPDFPagesAsSlides() {
        let deck = SlideDeckText.fromPages(["Central limit theorem\nFor large n…", "", "Summary\nDone"])
        XCTAssertEqual(deck.slides.map(\.title), ["Central limit theorem", "Summary"])
        XCTAssertEqual(deck.slides.map(\.number), [1, 3])
    }
}

final class HomeworkDetectorTests: XCTestCase {
    typealias F = AcademicFixtures

    func testStatsSheetDueEndOfWeek2() {
        let items = HomeworkDetector(calendar: .exeter, now: F.d(2026, 9, 26, 12))
            .detect(content: F.content(), texts: [5001: F.sheetText])
        let sheet = items.first { $0.title.lowercased().contains("stats sheet") }
        XCTAssertNotNil(sheet)
        XCTAssertEqual(sheet?.cmid, 5001, "the label and the file are one piece of work")
        XCTAssertEqual(sheet?.due, F.d(2026, 10, 2, 23, 59))
        XCTAssertEqual(sheet?.dueSource, .academicWeek)
        XCTAssertEqual(sheet?.questionCount, 3)
        XCTAssertEqual(sheet?.estimateMinutes, 45)
        XCTAssertEqual(sheet?.kind, .homework)
        XCTAssertEqual(items.filter { $0.title.lowercased().contains("stats sheet") }.count, 1)
        XCTAssertFalse(items.contains { $0.title.lowercased().contains("solutions") })
        // Quiz in week 2 (no stated due date → end of week 2).
        let quiz = items.first { $0.kind == .quiz }
        XCTAssertEqual(quiz?.due, F.d(2026, 10, 2, 23, 59))
        XCTAssertEqual(quiz?.dueSource, .assumed)
        // Lecture prep.
        let prep = items.first { $0.kind == .prep }
        XCTAssertEqual(prep?.title, "Read chapter 3 of Newbold")
        XCTAssertEqual(prep?.due, F.d(2026, 10, 5, 9))
        // The summative brief isn't homework.
        XCTAssertFalse(items.contains { $0.cmid == 5020 })
    }

    func testTasksAreStable() {
        let detector = HomeworkDetector(calendar: .exeter, now: F.d(2026, 9, 26, 12))
        let a = detector.tasks(for: detector.detect(content: F.content(), texts: [5001: F.sheetText]))
        let b = detector.tasks(for: detector.detect(content: F.content(), texts: [5001: F.sheetText]))
        XCTAssertEqual(a.map(\.id), b.map(\.id))
        let task = a.first { $0.sourceRef == "hw-BEE1022-cm5001" }
        XCTAssertEqual(task?.title, "BEE1022 HW stats sheet")
        XCTAssertEqual(task?.deadline, F.d(2026, 10, 2, 23, 59))
        XCTAssertEqual(task?.source, .ele)
        XCTAssertEqual(task?.moduleCode, "BEE1022")
        XCTAssertEqual(task?.estimateMinutes, 45)
        XCTAssertTrue(task?.notes.contains("https://ele.exeter.ac.uk/mod/resource/view.php?id=5001") ?? false)
        XCTAssertTrue(task?.notes.contains("3 questions") ?? false)
        XCTAssertEqual(StableID.uuid("x"), StableID.uuid("x"))
        XCTAssertNotEqual(StableID.uuid("x"), StableID.uuid("y"))
    }

    func testKeywordsAndQuestions() {
        XCTAssertTrue(HomeworkDetector.looksLikeHomework("Problem Set 2"))
        XCTAssertTrue(HomeworkDetector.looksLikeHomework("Tutorial sheet 3"))
        XCTAssertTrue(HomeworkDetector.looksLikeHomework("Formative mock test"))
        XCTAssertFalse(HomeworkDetector.looksLikeHomework("Problem set 2 solutions"))
        XCTAssertFalse(HomeworkDetector.looksLikeHomework("Lecture 3 slides"))
        XCTAssertEqual(HomeworkDetector.questionCount("1. a\n2. b\n3) c\nIn 2019 there were 45 firms."), 3)
        XCTAssertNil(HomeworkDetector.questionCount("Nothing numbered here."))
    }
}

final class LectureTrackerTests: XCTestCase {
    typealias F = AcademicFixtures

    func testLecturesMatchedToSlidesAndNotes() {
        let kb = F.knowledge()
        let note = LectureNote(id: "n1", title: "Stats lecture 1", moduleCode: "BEE1022", week: 1, created: F.d(2026, 9, 22, 11),
                               segments: [NoteSegment(kind: .typed, text: String(repeating: "Mean, median and mode. ", count: 20))])
        let tracker = LectureTracker(knowledge: kb, notes: [note], now: F.d(2026, 9, 30, 12))
        let lectures = tracker.lectures(module: "BEE1022")
        XCTAssertEqual(lectures.count, 2)
        XCTAssertEqual(lectures[0].week, 1)
        XCTAssertEqual(lectures[0].status, .notesTaken)
        XCTAssertEqual(lectures[0].noteIDs, ["n1"])
        XCTAssertEqual(lectures[1].week, 2)
        XCTAssertEqual(lectures[1].status, .noNotes)
        XCTAssertEqual(lectures[1].slideDocumentIDs, ["ele-cm-5003"])
        // Tutorial on Thursday is upcoming and not a lecture.
        let all = tracker.sessions(module: "BEE1022")
        XCTAssertEqual(all.last?.kind, .tutorial)
        XCTAssertEqual(all.last?.status, .upcoming)
        // Thin notes are incomplete.
        var thin = note; thin.segments = [NoteSegment(kind: .typed, text: "mean")]
        XCTAssertEqual(LectureTracker(knowledge: kb, notes: [thin], now: F.d(2026, 9, 30)).lectures().first?.status, .notesIncomplete)
    }
}

final class NotesReviewTests: XCTestCase {
    typealias F = AcademicFixtures

    let notes = LectureNote(id: "n2", title: "BEE1022 week 2", moduleCode: "BEE1022", week: 2, segments: [
        NoteSegment(kind: .typed, text: """
        Probability rules: addition rule, multiplication rule for independent events
        Random variables - discrete, expected value, variance
        CLT: central limit theorm -> sample mean ~ normal for big n
        Why does the standard error use n not n-1?
        Q: is the CLT true for skewed data
        ask tutor about Bayes rule
        """),
    ])

    func testKeywordCoverageFindsMissedTopic() {
        let result = NotesReview.coverageCheck(notesText: notes.allText, deck: F.slidesWeek2)
        XCTAssertEqual(result.missed.first?.topic, "Sampling distributions")
        XCTAssertEqual(result.missed.first?.slides, [5, 6])
        XCTAssertEqual(result.missed.first?.slideText, "slides 5–6")
        XCTAssertFalse(result.missed.contains { $0.topic == "Central limit theorem" }, "a one-letter slip still counts as covered")
        XCTAssertFalse(result.missed.contains { $0.topic == "Probability rules" })
        XCTAssertLessThan(result.coverage, 1)
    }

    func testAIPhrasesMissedList() async {
        let llm = MockLLMProvider { req in
            XCTAssertEqual(req.purpose, .privateData)
            return #"{"missed":[{"topic":"sampling distributions","slides":[5,6,99],"why":"the sample mean has its own distribution"}]}"#
        }
        let result = await NotesReview.missedContent(notes: [notes], slides: F.slidesWeek2, router: LLMRouter(providers: [llm]))
        XCTAssertTrue(result.usedAI)
        XCTAssertEqual(result.missed, [MissedTopic(topic: "sampling distributions", slides: [5, 6], detail: "the sample mean has its own distribution")])
    }

    func testExtractQuestions() {
        let qs = NotesReview.extractQuestions(notes).map(\.text)
        XCTAssertEqual(qs, ["Why does the standard error use n not n-1?", "Is the CLT true for skewed data?", "Bayes rule?"])
        var other = notes
        other.segments = [NoteSegment(kind: .typed, text: "- Elasticity (?)\n- Why?\n- Price elasticity of demand??")]
        XCTAssertEqual(NotesReview.extractQuestions(other).map(\.text), ["Price elasticity of demand?"])
    }

    func testReviewAnswersQuestionsOnceWithCitations() async {
        let kb = F.knowledge()
        final class Counter: @unchecked Sendable { var answers = 0 }
        let counter = Counter()
        let llm = MockLLMProvider { req in
            if req.json { return #"{"missed":[{"topic":"sampling distributions","slides":[5,6]}]}"# }
            counter.answers += 1
            return "Because the sample mean's spread falls with sample size [1]."
        }
        let router = LLMRouter(providers: [llm])
        let slides = kb.documents(moduleCode: "BEE1022", week: 2, kinds: [.slides])
        let first = await NotesReview.review(moduleCode: "BEE1022", term: 1, week: 2, title: "Probability", notes: [notes],
                                             slides: slides, kb: kb, router: router, previous: nil)
        XCTAssertEqual(first.id, "BEE1022-t1-w2")
        XCTAssertEqual(first.missed.first?.topic, "sampling distributions")
        XCTAssertEqual(first.questions.count, 3)
        XCTAssertTrue(first.questions.allSatisfy(\.isAnswered))
        let cited = first.questions.first { !$0.citations.isEmpty }
        XCTAssertEqual(cited?.citations.first?.moduleCode, "BEE1022")
        XCTAssertEqual(first.missedNotification?.title, "BEE1022 week 2: notes vs slides")
        XCTAssertEqual(first.missedNotification?.body, "You may have missed ‘sampling distributions’ (slides 5–6).")
        XCTAssertEqual(first.answeredNotification(newlyAnswered: 2)?.title, "Answered 2 questions from your BEE1022 notes")
        let asked = counter.answers
        // Second run: nothing re-asked, missed content not recomputed.
        let second = await NotesReview.review(moduleCode: "BEE1022", term: 1, week: 2, title: "Probability", notes: [notes],
                                              slides: slides, kb: kb, router: router, previous: first)
        XCTAssertEqual(counter.answers, asked)
        XCTAssertEqual(second.questions, first.questions)
    }

    func testSlideRange() {
        XCTAssertEqual(NotesReview.slideRange([12, 13, 14, 15]), "slides 12–15")
        XCTAssertEqual(NotesReview.slideRange([3]), "slide 3")
        XCTAssertEqual(NotesReview.slideRange([7, 3, 8]), "slides 3, 7–8")
    }
}

final class CourseKnowledgeBaseTests: XCTestCase {
    typealias F = AcademicFixtures

    func testSearchWithFilters() {
        let kb = F.knowledge()
        let hits = kb.search("sampling distribution standard error")
        XCTAssertEqual(hits.first?.document.id, "ele-cm-5003")
        XCTAssertEqual(hits.first?.slide, 5)
        XCTAssertTrue(hits.first?.citation.contains("BEE1022 · week 2 · Lecture 2 slides (slides)") ?? false)
        XCTAssertTrue(kb.search("sampling distribution", week: 1).allSatisfy { $0.document.week == 1 })
        XCTAssertEqual(kb.search("histogram", kinds: [.homework]).first?.document.id, "ele-cm-5001")
        XCTAssertTrue(kb.search("histogram", kinds: [.slides]).isEmpty)
        XCTAssertEqual(kb.document(named: "stats sheet")?.id, "ele-cm-5001")
        XCTAssertEqual(kb.document(named: "week 2 slides")?.id, "ele-cm-5003")
    }

    func testOverviewsAndWhatsHappening() {
        let kb = F.knowledge()
        XCTAssertEqual(kb.modules["BEE1022"]?.name, "Introduction to Statistics")
        XCTAssertEqual(kb.modules["BEE1022"]?.term, 1)
        let w2 = kb.weekOverview(module: "BEE1022", week: 2)
        XCTAssertEqual(w2?.materials.map(\.id), ["ele-cm-5003"])
        XCTAssertEqual(w2?.sessions.count, 2)
        XCTAssertTrue(w2?.homeworkDue.contains { $0.cmid == 5001 } ?? false, "the week-1 sheet is due in week 2")
        let now = F.d(2026, 9, 26, 12)
        let happening = kb.whatsHappening(now: now)
        XCTAssertEqual(happening.currentWeek?.week, 1)
        XCTAssertEqual(happening.nextWeek?.week, 2)
        XCTAssertTrue(happening.dueSoon.contains { $0.title == "HW stats sheet" })
        XCTAssertTrue(happening.dueSoon.contains { $0.title == "Data project" })
        let text = happening.text(calendar: kb.calendar)
        XCTAssertTrue(text.contains("This week: Week 1, w/c Mon 21 Sep"))
        XCTAssertTrue(text.contains("HW stats sheet — Fri 2 Oct 23:59"))
        XCTAssertTrue(happening.compact(calendar: kb.calendar).hasPrefix("Academic week: Week 1, w/c Mon 21 Sep."))
        XCTAssertEqual(kb.moduleOverview(module: "BEE1022")?.documentCounts[.slides], 1)
    }

    func testUpsertKeepsUnchangedAndPersists() throws {
        var kb = F.knowledge()
        let doc = kb.document(id: "ele-cm-5003")!
        XCTAssertFalse(kb.upsert(doc), "unchanged text isn't re-indexed")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kb-\(UUID().uuidString).json")
        try kb.save(to: url)
        let loaded = try CourseKnowledgeBase.load(from: url)
        XCTAssertEqual(loaded.search("central limit theorem").first?.document.id, "ele-cm-5003")
        XCTAssertEqual(loaded.homework, kb.homework)
        // Old files missing newer fields still load.
        let bare = try JSONSerialization.data(withJSONObject: ["updatedAt": 0])
        XCTAssertTrue(try JSONDecoder().decode(CourseKnowledgeBase.self, from: bare).isEmpty)
        kb.addNotes([LectureNote(id: "n9", title: "Stats week 2", moduleCode: "BEE1022", week: 2,
                                 segments: [NoteSegment(kind: .typed, text: "Bayes theorem worked example")])])
        XCTAssertEqual(kb.search("bayes", kinds: [.lectureNotes]).first?.document.id, "note:n9")
    }

    func testResourceTargets() {
        let kb = F.knowledge()
        let targets = kb.resourceTargets(from: F.snapshot())
        XCTAssertEqual(Set(targets.map(\.cmid)), [5000, 5001, 5002, 5003])
        XCTAssertEqual(targets.first { $0.cmid == 5001 }?.kind, .homework)
        XCTAssertEqual(targets.first { $0.cmid == 5000 }?.kind, .slides)
        XCTAssertEqual(targets.first { $0.cmid == 5000 }?.week, 1)
    }
}

final class AcademicToolsTests: XCTestCase {
    typealias F = AcademicFixtures

    actor Data: AcademicDataSource {
        var kb: CourseKnowledgeBase
        var done: Set<UUID> = []
        init(_ kb: CourseKnowledgeBase) { self.kb = kb }
        func courseKnowledge() async -> CourseKnowledgeBase { kb }
        func lectureReviews() async -> [LectureReview] {
            [LectureReview(id: "BEE1022-t1-w2", moduleCode: "BEE1022", term: 1, week: 2, title: "Probability", coverage: 0.7,
                           missed: [MissedTopic(topic: "sampling distributions", slides: [5, 6])])]
        }
        func tasks() async -> [OrbitTask] { [] }
    }

    final class Script: @unchecked Sendable {
        var replies: [String]
        var seen: [LLMRequest] = []
        init(_ r: [String]) { replies = r }
    }

    func tools(_ kb: CourseKnowledgeBase) -> [String: AssistantTool] {
        Dictionary(uniqueKeysWithValues: AcademicTools.make(Data(kb), now: { F.d(2026, 9, 26, 12) }).map { ($0.name, $0) })
    }

    func testTools() async throws {
        var kb = F.knowledge()
        kb.recordActivity([ELEActivityItem(id: "x1", kind: .newFile, moduleCode: "BEE1022", title: "New file in week 3: Lecture 5 slides",
                                           date: F.d(2026, 9, 25, 9))])
        let t = tools(kb)
        let hw = try await t["homework"]!.run([:])
        XCTAssertTrue(hw.contains("BEE1022 Homework: HW stats sheet — due Fri 2 Oct 23:59 [to do] · 3 questions"), hw)
        let week = try await t["whats_happening"]!.run([:])
        XCTAssertTrue(week.contains("Week 1"), week)
        let search = try await t["course_search"]!.run(["query": .string("central limit theorem"), "module": .string("stats")])
        XCTAssertTrue(search.contains("Lecture 2 slides"), search)
        let mats = try await t["week_materials"]!.run(["module": .string("BEE1022"), "week": .number(2)])
        XCTAssertTrue(mats.contains("id ele-cm-5003"), mats)
        let read = try await t["read_resource"]!.run(["name": .string("ele-cm-5001")])
        XCTAssertTrue(read.contains("Question 2. Draw a histogram"), read)
        let review = try await t["lecture_review"]!.run(["module": .string("BEE1022"), "week": .number(2)])
        XCTAssertTrue(review.contains("May have missed: sampling distributions (slides 5–6)"), review)
        let activity = try await t["ele_activity"]!.run(["since": .string("3 days")])
        XCTAssertTrue(activity.contains("New file in week 3: Lecture 5 slides"), activity)
        let overview = try await t["module_overview"]!.run(["module": .string("bee1022")])
        XCTAssertTrue(overview.contains("Data project (30%)"), overview)
    }

    func testAssistantUsesToolAndGetsWeekContext() async throws {
        let kb = F.knowledge()
        let script = Script([#"{"tool": "homework", "args": {}}"#, #"{"reply": "Your stats sheet is due Friday of week 2."}"#])
        let llm = MockLLMProvider { req in script.seen.append(req); return script.replies.removeFirst() }
        let context = AcademicTools.context(kb, now: F.d(2026, 9, 26, 12))
        let assistant = Assistant(router: LLMRouter(providers: [llm]), tools: AcademicTools.make(Data(kb), now: { F.d(2026, 9, 26, 12) }),
                                  contextProvider: { context })
        let turn = try await assistant.send("what homework do I have?", now: F.d(2026, 9, 26, 12))
        XCTAssertEqual(turn.toolsUsed, ["homework"])
        let system = script.seen[0].messages[0].text
        XCTAssertTrue(system.contains("Academic week: Week 1, w/c Mon 21 Sep."), system)
        XCTAssertTrue(system.contains("- homework("), system)
        XCTAssertTrue(script.seen[1].messages.last!.text.contains("HW stats sheet"))
    }
}
