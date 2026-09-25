import XCTest
@testable import OrbitCore

final class ICSParserTests: XCTestCase {
    func testParsesTimetableWithRecurrenceAndFolding() {
        let ics = """
        BEGIN:VCALENDAR\r
        BEGIN:VEVENT\r
        UID:abc\r
        SUMMARY:BEM2031 Lecture\\, Week
         ly\r
        DTSTART;TZID=Europe/London:20261005T090000\r
        DTEND;TZID=Europe/London:20261005T110000\r
        RRULE:FREQ=WEEKLY;COUNT=3\r
        EXDATE;TZID=Europe/London:20261012T090000\r
        LOCATION:Forum\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:due\r
        SUMMARY:Essay due\r
        DTSTART;VALUE=DATE:20261101\r
        END:VEVENT\r
        END:VCALENDAR\r
        """
        let events = ICSParser.parse(ics)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].title, "BEM2031 Lecture, Weekly")
        XCTAssertEqual(events[0].end.timeIntervalSince(events[0].start), 7200)
        XCTAssertEqual(events[1].start.timeIntervalSince(events[0].start), 14 * 86400) // skips the 12th
        XCTAssertTrue(events[2].isAllDay)
    }
}
