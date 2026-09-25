import XCTest
@testable import OrbitCore

final class DateExtractorTests: XCTestCase {
    typealias F = SchedFixtures
    /// Wednesday 7 October 2026, 10:00 BST.
    let now = SchedFixtures.date(2026, 10, 7, 10)
    var ex: DateExtractor { DateExtractor(now: now, timeZone: F.tz) }

    func one(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> DateMatch? {
        let m = ex.extract(from: text)
        XCTAssertEqual(m.count, 1, "matches in \"\(text)\": \(m.map(\.text))", file: file, line: line)
        return m.first
    }

    func testRelativeDays() {
        XCTAssertEqual(one("do it today")?.date, F.date(2026, 10, 7))
        let t = one("finish tomorrow please")
        XCTAssertEqual(t?.date, F.date(2026, 10, 8))
        XCTAssertEqual(t?.hasTime, false)
        XCTAssertEqual(t?.text, "tomorrow")
        XCTAssertEqual(one("day after tomorrow")?.date, F.date(2026, 10, 9))
        XCTAssertEqual(one("tmrw")?.date, F.date(2026, 10, 8))
        let tonight = one("pub tonight")
        XCTAssertEqual(tonight?.date, F.date(2026, 10, 7, 20))
        XCTAssertEqual(tonight?.hasTime, true)
    }

    func testRangesPointAtTheText() {
        let text = "Dinner with Sam Sat 7pm, then lecture Monday at 9"
        let m = ex.extract(from: text)
        XCTAssertEqual(m.map(\.text), ["Sat 7pm", "Monday at 9"])
        for x in m { XCTAssertEqual(String(text[x.range]), x.text) }
        XCTAssertEqual(m[0].date, F.date(2026, 10, 10, 19))
        XCTAssertEqual(m[1].date, F.date(2026, 10, 12, 9))
    }

    func testWeekdays() {
        XCTAssertEqual(one("before Friday")?.date, F.date(2026, 10, 9))
        XCTAssertEqual(one("on wednesday")?.date, F.date(2026, 10, 14), "same weekday means next week")
        XCTAssertEqual(one("this Wednesday")?.date, F.date(2026, 10, 7))
        XCTAssertEqual(one("next Monday")?.date, F.date(2026, 10, 12))
        XCTAssertEqual(one("next friday")?.date, F.date(2026, 10, 16), "next = the week after this one")
        XCTAssertEqual(one("by Tues")?.date, F.date(2026, 10, 13))
    }

    func testAbbreviationsNeedContext() {
        XCTAssertTrue(ex.extract(from: "I sat down with the sun behind me").isEmpty)
        XCTAssertEqual(one("gym sat 10am")?.date, F.date(2026, 10, 10, 10))
        XCTAssertEqual(one("gym on sat")?.date, F.date(2026, 10, 10))
        XCTAssertTrue(ex.extract(from: "you may 2 go").isEmpty)
    }

    func testNumericDatesAreDayMonth() {
        XCTAssertEqual(one("due 12/11")?.date, F.date(2026, 11, 12))
        XCTAssertEqual(one("due 12/11/2027")?.date, F.date(2027, 11, 12))
        XCTAssertEqual(one("due 12/11/27")?.date, F.date(2027, 11, 12))
        XCTAssertEqual(one("due 12.11.2026")?.date, F.date(2026, 11, 12))
        XCTAssertEqual(one("on 2026-11-12")?.date, F.date(2026, 11, 12))
        XCTAssertEqual(one("back on 3/1")?.date, F.date(2027, 1, 3), "past dates roll to next year")
        XCTAssertEqual(one("was 5/10")?.date, F.date(2026, 10, 5), "last few days stay this year")
        XCTAssertTrue(ex.extract(from: "31/02").isEmpty)
        XCTAssertTrue(ex.extract(from: "1.5h").isEmpty)
    }

    func testWrittenDates() {
        XCTAssertEqual(one("by 12 Nov")?.date, F.date(2026, 11, 12))
        XCTAssertEqual(one("the 12th of November 2027")?.date, F.date(2027, 11, 12))
        XCTAssertEqual(one("Nov 3rd")?.date, F.date(2026, 11, 3))
        XCTAssertEqual(one("21st December, 2026")?.date, F.date(2026, 12, 21))
        XCTAssertEqual(one("by the 20th")?.date, F.date(2026, 10, 20))
        XCTAssertEqual(one("by the 2nd")?.date, F.date(2026, 11, 2))
        XCTAssertEqual(one("Friday the 16th")?.date, F.date(2026, 10, 16))
        XCTAssertEqual(one("Fri 13 Nov at 2pm")?.date, F.date(2026, 11, 13, 14))
    }

    func testTimes() {
        let t = one("meet at 17:30")
        XCTAssertEqual(t?.date, F.date(2026, 10, 7, 17, 30))
        XCTAssertEqual(t?.hasTime, true)
        XCTAssertEqual(one("call at 9am")?.date, F.date(2026, 10, 8, 9), "passed times roll to tomorrow")
        XCTAssertEqual(one("5:30 pm")?.date, F.date(2026, 10, 7, 17, 30))
        XCTAssertEqual(one("at noon")?.date, F.date(2026, 10, 7, 12))
        XCTAssertEqual(one("at 5")?.date, F.date(2026, 10, 7, 17))
        XCTAssertEqual(one("12am")?.date, F.date(2026, 10, 8, 0))
        XCTAssertEqual(one("this evening")?.date, F.date(2026, 10, 7, 19))
        XCTAssertEqual(one("tomorrow morning")?.date, F.date(2026, 10, 8, 9))
        XCTAssertTrue(ex.extract(from: "good morning Sam").isEmpty)
    }

    func testDateAndTimeCombine() {
        XCTAssertEqual(one("before Friday 5pm")?.date, F.date(2026, 10, 9, 17))
        XCTAssertEqual(one("at 3pm tomorrow")?.date, F.date(2026, 10, 8, 15))
        XCTAssertEqual(one("3pm on Monday")?.date, F.date(2026, 10, 12, 15))
        XCTAssertEqual(one("12 Nov at 17:00")?.text, "12 Nov at 17:00")
        XCTAssertEqual(one("tomorrow at 9")?.date, F.date(2026, 10, 8, 9))
    }

    func testRelativeSpans() {
        XCTAssertEqual(one("in 3 days")?.date, F.date(2026, 10, 10))
        XCTAssertEqual(one("in a fortnight")?.date, F.date(2026, 10, 21))
        let h = one("in 2 hours")
        XCTAssertEqual(h?.date, F.date(2026, 10, 7, 12))
        XCTAssertEqual(h?.hasTime, true)
        XCTAssertEqual(one("in 30 mins")?.date, F.date(2026, 10, 7, 10, 30))

        let nw = one("sometime next week")
        XCTAssertEqual(nw?.date, F.date(2026, 10, 12))
        XCTAssertEqual(nw?.periodEnd, F.date(2026, 10, 18, 23, 59))
        let eow = one("by end of week")
        XCTAssertEqual(eow?.date, F.date(2026, 10, 9, 17))
        XCTAssertEqual(one("end of the month")?.date, F.date(2026, 10, 31, 17))
        XCTAssertEqual(one("this weekend")?.date, F.date(2026, 10, 10))
        XCTAssertEqual(one("next month")?.periodEnd, F.date(2026, 11, 30, 23, 59))
    }

    func testDSTAwareTimes() {
        // 25 Oct is GMT, 24 Oct is BST.
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.hour, from: one("24/10 9am")!.date), 8)
        XCTAssertEqual(utc.component(.hour, from: one("25/10 9am")!.date), 9)
    }

    func testNoFalsePositives() {
        XCTAssertTrue(ex.extract(from: "essay plan for BEM2031, 2h").isEmpty)
        XCTAssertTrue(ex.extract(from: "read ch3 45 mins").isEmpty)
        XCTAssertTrue(ex.extract(from: "a week of work").isEmpty)
    }
}
