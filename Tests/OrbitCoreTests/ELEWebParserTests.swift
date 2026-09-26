import XCTest
@testable import OrbitCore

final class ELEWebParserTests: XCTestCase {
    let london = TimeZone(identifier: "Europe/London")!

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = london
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    func testCourseNamesAndCodes() {
        XCTAssertEqual(ELEWebParser.moduleCode(shortName: "BEE1032_A_1_202627"), "BEE1032")
        XCTAssertNil(ELEWebParser.moduleCode(shortName: "UEBS_CAREERS"))
        XCTAssertNil(ELEWebParser.moduleCode(shortName: "ECO_BSc_ECONOMICS"))
        XCTAssertEqual(ELEWebParser.courseName(fullName: "History of Economic Thought (BEE1032_A_1_202627)",
                                               shortName: "BEE1032_A_1_202627"), "History of Economic Thought")
        XCTAssertEqual(ELEWebParser.academicYearStart(shortName: "BEE1032_A_1_202627"), 2026)
        XCTAssertNil(ELEWebParser.academicYearStart(shortName: "BEE1032_A_1_202699"))
    }

    func testCoursesFromAJAX() throws {
        let courses = try ELEWebParser.courses(fromAJAX: Data(ELEWebFixtures.coursesJSON.utf8))
        XCTAssertEqual(courses.count, 9)
        let split = ELEWebSnapshot.split(courses)
        XCTAssertEqual(split.modules.map { $0.moduleCode! }, ["BEE1022", "BEE1024", "BEE1032", "BEE1036", "BSD1000"])
        XCTAssertEqual(split.resources.count, 4)
        let het = split.modules.first { $0.moduleCode == "BEE1032" }!
        XCTAssertEqual(het.id, 29450)
        XCTAssertEqual(het.name, "History of Economic Thought")
        XCTAssertEqual(het.progress, 4)
        XCTAssertEqual(het.viewURL, "https://ele.exeter.ac.uk/course/view.php?id=29450")
        XCTAssertEqual(split.resources.first { $0.id == 1300 }?.name, "UEBS Careers & Employability")
    }

    func testSessionExpiry() {
        XCTAssertThrowsError(try ELEWebParser.courses(fromAJAX: Data(ELEWebFixtures.expiredJSON.utf8))) {
            XCTAssertEqual($0 as? ELEWebError, .sessionExpired)
        }
        XCTAssertThrowsError(try ELEWebParser.ajaxData(Data("<html><body id=\"page-login-index\">".utf8))) {
            XCTAssertEqual($0 as? ELEWebError, .sessionExpired)
        }
        XCTAssertThrowsError(try ELEWebParser.ajaxData(Data(#"{"error":"Invalid sesskey","errorcode":"invalidsesskey"}"#.utf8))) {
            XCTAssertEqual($0 as? ELEWebError, .sessionExpired)
        }
        let other = #"[{"error":true,"exception":{"message":"nope","errorcode":"servicenotavailable"}}]"#
        XCTAssertThrowsError(try ELEWebParser.ajaxData(Data(other.utf8))) {
            XCTAssertTrue(($0 as? ELEWebError)?.isUnavailableFunction ?? false)
        }
    }

    func testEventsToAssessments() throws {
        let courses = try ELEWebParser.courses(fromAJAX: Data(ELEWebFixtures.coursesJSON.utf8))
        let events = try ELEWebParser.events(fromAJAX: Data(ELEWebFixtures.eventsJSON.utf8))
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].courseID, 29460)
        XCTAssertEqual(events[0].instance, 55501)
        let a = ELEWebParser.assessments(fromEvents: events, courses: courses)
        XCTAssertEqual(a.count, 2, "info-course quiz is skipped")
        XCTAssertEqual(a[0].id, "ele-assign-55501")
        XCTAssertEqual(a[0].moduleCode, "BEE1036")
        XCTAssertEqual(a[0].title, "Economics I Problem Set 1")
        XCTAssertEqual(a[0].eleURL, "https://ele.exeter.ac.uk/mod/assign/view.php?id=990001")
        XCTAssertEqual(a[1].kind, .essay)
    }

    func testWeekHeading() {
        let w = ELEWebParser.weekHeading("Week 3 W/c 5 October", academicYear: 2026)
        XCTAssertEqual(w?.week, 3)
        XCTAssertEqual(w?.commencing, date(2026, 10, 5))
        XCTAssertEqual(ELEWebParser.weekHeading("Week 12 W/c 7 December", academicYear: 2026)?.commencing, date(2026, 12, 7))
        XCTAssertEqual(ELEWebParser.weekHeading("Week 2 w/c 11th January", academicYear: 2026)?.commencing, date(2027, 1, 11))
        XCTAssertNil(ELEWebParser.weekHeading("Past papers", academicYear: 2026))
    }

    func testCourseHTMLSections() {
        XCTAssertEqual(ELEWebParser.sesskey(inHTML: ELEWebFixtures.courseHTML), "AbC123xyZ9")
        XCTAssertFalse(ELEWebParser.looksLikeLoginPage(ELEWebFixtures.courseHTML))
        let sections = ELEWebParser.sections(fromCourseHTML: ELEWebFixtures.courseHTML, academicYear: 2026)
        XCTAssertEqual(sections.map(\.kind), [.general, .assessment, .readingList, .recordings, .week, .week, .week, .pastPapers, .exemplars])
        let assessment = sections[1]
        XCTAssertEqual(assessment.id, 701)
        XCTAssertEqual(assessment.url, "https://ele.exeter.ac.uk/course/section.php?id=701")
        XCTAssertNotNil(assessment.html)
        XCTAssertEqual(assessment.items.map(\.role), [.assessmentBrief, .submission])
        XCTAssertEqual(assessment.items[0].name, "Essay Assessment Brief -- questions, deadline (3pm 16 November, as word or pdf file)")
        XCTAssertEqual(assessment.items[0].cmid, 990020)
        XCTAssertEqual(assessment.items[0].url, "https://ele.exeter.ac.uk/mod/resource/view.php?id=990020")
        XCTAssertEqual(sections[2].items.first?.role, .readingList)
        XCTAssertEqual(sections[2].items.first?.kind, .lti)

        let week1 = sections[4]
        XCTAssertEqual(week1.week, 1)
        XCTAssertEqual(week1.weekCommencing, date(2026, 9, 21))
        XCTAssertEqual(week1.items.map(\.role), [.slides, .handout, .tutorial, .reading, .readingGuide])
        XCTAssertEqual(week1.items[0].name, "Week 1 lecture slides")
        XCTAssertEqual(sections[7].items.first?.role, .pastPaper)
        XCTAssertEqual(sections[6].week, 12)
        XCTAssertTrue(sections[6].items.isEmpty)
    }

    func testWeeksReadingsTutorials() {
        let sections = ELEWebParser.sections(fromCourseHTML: ELEWebFixtures.courseHTML, academicYear: 2026)
        let content = ELEWebCourseContent(courseID: 29450, moduleCode: "BEE1032", sections: sections)
        XCTAssertEqual(content.weeks.map(\.week), [1, 3, 12])
        let w1 = content.weeks[0]
        XCTAssertEqual(w1.lectures.map(\.name), ["Week 1 lecture slides", "Week 1 handout"])
        XCTAssertEqual(w1.tutorials, ["What is economic thought?"])
        XCTAssertEqual(w1.readings, ["Heilbroner, The Worldly Philosophers, ch. 1"])
        XCTAssertEqual(w1.readingGuides.map(\.name), ["guide to reading, week 1"])
        XCTAssertEqual(content.weeks[1].tutorials, ["Smith on the division of labour"])
        XCTAssertEqual(content.readings.map(\.week), [1, 3])
        XCTAssertEqual(content.readings[1].title, "Smith, Wealth of Nations, Book I ch. 1-3")
        XCTAssertTrue(content.readings.allSatisfy { $0.moduleCode == "BEE1032" && $0.id.hasPrefix("eleweb-BEE1032-w") })
        XCTAssertEqual(content.pastPapers.count, 1)
        // IDs are stable between parses.
        let again = ELEWebCourseContent(courseID: 29450, moduleCode: "BEE1032", sections: sections)
        XCTAssertEqual(again.readings.map(\.id), content.readings.map(\.id))
    }

    func testCourseStateFallback() throws {
        let sections = try ELEWebParser.sections(fromCourseState: Data(ELEWebFixtures.courseStateJSON.utf8), academicYear: 2026)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].kind, .assessment)
        XCTAssertEqual(sections[0].items.first?.role, .assessmentBrief)
        XCTAssertEqual(sections[1].week, 1)
        XCTAssertEqual(sections[1].items.map(\.kind), [.resource, .label])
        XCTAssertEqual(ELEWebParser.readings(from: sections, moduleCode: "BEE1032").first?.title, "Heilbroner, ch. 1")
    }

    func testDownloadURL() {
        let item = ELEWebItem(cmid: 1, name: "x", kind: .resource, url: "https://ele.exeter.ac.uk/mod/resource/view.php?id=990020")
        XCTAssertEqual(ELEWebParser.downloadURL(for: item)?.absoluteString,
                       "https://ele.exeter.ac.uk/mod/resource/view.php?id=990020&redirect=1")
        let html = #"<div class="resourceworkaround">Click <a href="https://ele.exeter.ac.uk/pluginfile.php/123/mod_resource/content/2/Essay%20Brief.docx" onclick="">Essay Brief.docx</a></div>"#
        XCTAssertEqual(ELEWebParser.pluginFileURL(inHTML: html)?.lastPathComponent, "Essay Brief.docx")
    }

    func testAJAXBody() throws {
        let body = ELEWebParser.ajaxBody(method: "core_calendar_get_action_events_by_timesort", args: ["limitnum": 50])
        let json = try JSONSerialization.jsonObject(with: body) as? [[String: Any]]
        XCTAssertEqual(json?.first?["methodname"] as? String, "core_calendar_get_action_events_by_timesort")
        XCTAssertEqual(json?.first?["index"] as? Int, 0)
        XCTAssertEqual(ELEWebParser.ajaxURL(sesskey: "k", method: "m").absoluteString,
                       "https://ele.exeter.ac.uk/lib/ajax/service.php?sesskey=k&info=m")
    }
}
