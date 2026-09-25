import XCTest
@testable import OrbitCore

final class ELECalendarFeedTests: XCTestCase {
    let ics = """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    PRODID:-//Moodle Pty Ltd//NONSGML Moodle Version 2024100700//EN\r
    BEGIN:VEVENT\r
    UID:1234@ele.exeter.ac.uk\r
    SUMMARY:Individual Essay (40%) is due\r
    DESCRIPTION:Submit your 2\\,000-word essay.\r
    CATEGORIES:BEM2031_2026\r
    DTSTART:20261105T120000Z\r
    DTEND:20261105T120000Z\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:1235@ele.exeter.ac.uk\r
    SUMMARY:Week 3 quiz closes\r
    CATEGORIES:BEM2024\r
    DTSTART:20261020T170000Z\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:1236@ele.exeter.ac.uk\r
    SUMMARY:Week 3 quiz opens\r
    CATEGORIES:BEM2024\r
    DTSTART:20261013T090000Z\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:1237@ele.exeter.ac.uk\r
    SUMMARY:Guest lecture: analytics in industry\r
    DTSTART:20261014T140000Z\r
    DTEND:20261014T150000Z\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    func testSplitsDeadlinesFromEvents() throws {
        let now = ISO8601.parse("2026-10-01T00:00:00Z")!
        let result = ELECalendarFeed.parse(ics, now: now)
        XCTAssertEqual(result.assessments.count, 2)
        XCTAssertEqual(result.events.map(\.title), ["Week 3 quiz opens", "Guest lecture: analytics in industry"])

        let essay = try XCTUnwrap(result.assessments.first { $0.id == "ele-ics-1234@ele.exeter.ac.uk" })
        XCTAssertEqual(essay.title, "Individual Essay (40%)")
        XCTAssertEqual(essay.moduleCode, "BEM2031")
        XCTAssertEqual(essay.kind, .essay)
        XCTAssertEqual(essay.weightPercent, 40)
        XCTAssertEqual(essay.wordCount, 2000)
        XCTAssertEqual(essay.due, ISO8601.parse("2026-11-05T12:00:00Z"))

        let quiz = try XCTUnwrap(result.assessments.first { $0.title == "Week 3 quiz" })
        XCTAssertEqual(quiz.kind, .quiz)
        XCTAssertEqual(quiz.moduleCode, "BEM2024")
    }

    func testFetchConvertsWebcal() async throws {
        let t = UniStubTransport { req, _ in
            XCTAssertEqual(req.url?.scheme, "https")
            return (200, self.ics)
        }
        let feed = ELECalendarFeed(url: URL(string: "webcal://ele.exeter.ac.uk/calendar/export_execute.php?userid=1&authtoken=x")!,
                                   http: HTTPClient(transport: t))
        let result = try await feed.fetch(now: ISO8601.parse("2026-10-01T00:00:00Z")!)
        XCTAssertEqual(result.assessments.count, 2)
    }
}
