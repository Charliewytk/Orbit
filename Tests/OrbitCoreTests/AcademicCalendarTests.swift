import XCTest
@testable import OrbitCore

final class AcademicCalendarTests: XCTestCase {
    let cal = AcademicCalendar.exeter
    var london: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }

    func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        london.date(from: DateComponents(year: y, month: m, day: day, hour: h, minute: min))!
    }

    func testWeekForDate() {
        XCTAssertEqual(cal.week(for: d(2026, 9, 21, 9))?.week, 1)
        XCTAssertEqual(cal.week(for: d(2026, 9, 27, 23))?.week, 1)
        XCTAssertEqual(cal.week(for: d(2026, 9, 28))?.week, 2)
        XCTAssertEqual(cal.week(for: d(2026, 9, 26, 12))?.label, "Week 1")
        let six = cal.week(for: d(2026, 10, 27))
        XCTAssertEqual(six?.week, 6)
        XCTAssertEqual(six?.isReadingWeek, true)
        XCTAssertEqual(six?.label, "Week 6 (reading week)")
        // Across the clocks going back (25 Oct).
        XCTAssertEqual(cal.week(for: d(2026, 11, 2, 10))?.week, 7)
        XCTAssertEqual(cal.week(for: d(2026, 12, 7))?.week, 12)
        XCTAssertNil(cal.week(for: d(2026, 12, 15)))
        XCTAssertNil(cal.week(for: d(2026, 9, 20)))
        let t2 = cal.week(for: d(2027, 1, 11, 9))
        XCTAssertEqual(t2?.term, 2)
        XCTAssertEqual(t2?.week, 1)
        XCTAssertEqual(t2?.label, "T2 week 1")
        XCTAssertEqual(cal.week(for: d(2026, 9, 21))?.start, d(2026, 9, 21))
    }

    func testDateForWeek() {
        XCTAssertEqual(cal.date(term: 1, week: 2, weekday: 5, hour: 23, minute: 59), d(2026, 10, 2, 23, 59))
        XCTAssertEqual(cal.date(term: 2, week: 1), d(2027, 1, 11))
        XCTAssertEqual(cal.currentOrNextWeek(d(2026, 12, 20))?.term, 2)
        XCTAssertEqual(cal.next(after: cal.academicWeek(term: 1, week: 12)!)?.label, "T2 week 1")
    }

    func testPhrases() {
        let now = d(2026, 9, 26, 12)
        let end2 = cal.resolve("HW stats sheet due end of week 2", reference: now)
        XCTAssertEqual(end2?.date, d(2026, 10, 2, 23, 59))
        XCTAssertEqual(end2?.hasTime, true)
        XCTAssertEqual(end2?.week, 2)

        let w5 = cal.resolve("week 5", reference: now)
        XCTAssertEqual(w5?.date, d(2026, 10, 19))
        XCTAssertEqual(w5?.isPeriod, true)
        XCTAssertEqual(w5?.periodEnd, d(2026, 10, 25, 23, 59))
        XCTAssertEqual(w5.map { $0.dueDate(in: cal) }, d(2026, 10, 23, 23, 59))

        XCTAssertEqual(cal.resolve("by week 3 Monday", reference: now)?.date, d(2026, 10, 5))
        XCTAssertEqual(cal.resolve("Friday of week 3", reference: now)?.date, d(2026, 10, 9))
        XCTAssertEqual(cal.resolve("week 1 of term 2", reference: now)?.date, d(2027, 1, 11))
        XCTAssertEqual(cal.resolve("T2 week 1", reference: now)?.term, 2)
        XCTAssertEqual(cal.resolve("Term 2, week 3", reference: now)?.date, d(2027, 1, 25))
        let wc = cal.resolve("Week 1 W/c 21 September", reference: now)
        XCTAssertEqual(wc?.week, 1)
        XCTAssertEqual(wc?.date, d(2026, 9, 21))
        XCTAssertEqual(cal.resolve("W/c 11 January", reference: now)?.term, 2)
        XCTAssertEqual(cal.resolve("start of week 4", reference: now)?.date, d(2026, 10, 12))
        XCTAssertEqual(cal.resolve("reading week", reference: now)?.week, 6)
        // In term 2, a bare week means term 2.
        XCTAssertEqual(cal.resolve("end of week 2", reference: d(2027, 1, 12))?.date, d(2027, 1, 22, 23, 59))
        XCTAssertNil(cal.resolve("in two weeks", reference: now))
    }

    func testDateExtractorUnderstandsWeeks() {
        let now = d(2026, 9, 26, 12)
        let x = DateExtractor(now: now, academic: cal)
        let m = x.extract(from: "Stats homework due end of week 2").first
        XCTAssertEqual(m?.date, d(2026, 10, 2, 23, 59))
        XCTAssertEqual(m?.text, "end of week 2")
        XCTAssertEqual(x.first(in: "essay plan by week 3 Monday")?.date, d(2026, 10, 5))
        // Without a calendar, week phrases are ignored as before.
        XCTAssertNotEqual(DateExtractor(now: now).first(in: "due end of week 2")?.date, d(2026, 10, 2, 23, 59))
    }

    func testAssessmentWeekDeadline() {
        let ctx = ELEAssessmentExtractor.Context(moduleCode: "BEE1022", academicYear: 2026, academic: cal)
        let (due, note) = ELEAssessmentExtractor.resolveDue("End of week 5", brief: "", kind: .coursework, context: ctx)
        XCTAssertEqual(due, d(2026, 10, 23, 23, 59))
        XCTAssertNotNil(note)
        // TBA stays unresolved.
        let (tba, tbaNote) = ELEAssessmentExtractor.resolveDue("TBA: week 1 of term2", brief: "", kind: .exam, context: ctx)
        XCTAssertNil(tba)
        XCTAssertEqual(tbaNote, "Due date TBA: week 1 of term2")
    }

    func testFillWeekCommencing() {
        var sections = [
            ELEWebSection(title: "Week 1 W/c 11 January", kind: .week, week: 1, weekCommencing: d(2027, 1, 11)),
            ELEWebSection(title: "Week 2", kind: .week, week: 2),
        ]
        XCTAssertEqual(cal.inferTerm(for: sections), 2)
        cal.fillWeekCommencing(&sections)
        XCTAssertEqual(sections[1].weekCommencing, d(2027, 1, 18))
    }

    func testConfigCodableInPrefs() throws {
        var prefs = UserPrefs()
        prefs.academicCalendar = .exeter2026
        let data = try JSONEncoder().encode(prefs)
        XCTAssertEqual(try JSONDecoder().decode(UserPrefs.self, from: data).academicCalendar?.terms.first?.startDate, "2026-09-21")
        // Old saved prefs (without the field) still decode.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(UserPrefs())) as! [String: Any]
        json["academicCalendar"] = nil
        XCTAssertNil(try JSONDecoder().decode(UserPrefs.self, from: JSONSerialization.data(withJSONObject: json)).academicCalendar)
    }
}
