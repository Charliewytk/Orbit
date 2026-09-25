import XCTest
@testable import OrbitCore

final class PlanToCalendarTests: XCTestCase {
    static func date(_ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        return cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: mi))!
    }

    func plan(_ title: String, _ start: Date, end: Date? = nil) -> ExtractedPlan {
        ExtractedPlan(title: title, start: start, end: end, location: "Côte", people: ["Sam"], source: .whatsapp,
                      quote: "fancy dinner at Côte sat 7pm?", confidence: 0.9)
    }

    func testDefaultDurations() {
        let converter = PlanToCalendar()
        let start = Self.date(17, 19)
        let expected: [(String, TimeInterval)] = [
            ("Dinner with Sam", 7200), ("Drinks with Sam", 10800), ("Coffee with Zoë", 3600), ("Gym", 5400),
            ("Call with Mum", 1800), ("BEM2031 Lecture", 3600), ("Party at Sam's", 14400), ("Meet up with Sam", 7200),
        ]
        for (title, seconds) in expected {
            let event = converter.suggestion(for: plan(title, start), existing: []).event
            XCTAssertEqual(event.end.timeIntervalSince(event.start), seconds, title)
        }
        let withEnd = converter.suggestion(for: plan("Dinner with Sam", start, end: Self.date(17, 22)), existing: []).event
        XCTAssertEqual(withEnd.end, Self.date(17, 22))
    }

    func testEventGoesToOrbitCalendarWithQuote() {
        let s = PlanToCalendar().suggestion(for: plan("Dinner with Sam", Self.date(17, 19)), existing: [])
        XCTAssertEqual(s.kind, .dinner)
        XCTAssertEqual(s.event.calendarID, "orbit")
        XCTAssertEqual(s.event.source, .orbit)
        XCTAssertEqual(s.event.location, "Côte")
        XCTAssertTrue(s.event.notes?.contains("WhatsApp") ?? false)
        XCTAssertTrue(s.event.notes?.contains("fancy dinner at Côte sat 7pm?") ?? false)
        XCTAssertFalse(s.isDuplicate)
        XCTAssertFalse(s.hasConflicts)
    }

    func testConflictsAndDuplicates() {
        let existing = [
            CalendarEvent(id: "dup", title: "Sam dinner 🍝", start: Self.date(17, 19, 30), end: Self.date(17, 21, 30)),
            CalendarEvent(id: "netball", title: "Netball training", start: Self.date(17, 20), end: Self.date(17, 21)),
            CalendarEvent(id: "alex", title: "Dinner with Alex", start: Self.date(17, 18), end: Self.date(17, 19, 30)),
            CalendarEvent(id: "week", title: "Reading week", start: Self.date(17, 0), end: Self.date(18, 0), isAllDay: true),
            CalendarEvent(id: "free", title: "Maybe library", start: Self.date(17, 19), end: Self.date(17, 20), isBusy: false),
            CalendarEvent(id: "later", title: "Dinner with Sam", start: Self.date(24, 19), end: Self.date(24, 21)),
        ]
        let s = PlanToCalendar().suggestion(for: plan("Dinner with Sam", Self.date(17, 19)), existing: existing)
        XCTAssertEqual(s.duplicateOf?.id, "dup")
        XCTAssertEqual(s.conflicts.map(\.id), ["alex", "netball"])
    }

    func testFuzzyTitles() {
        XCTAssertTrue(PlanTitleMatch.similar("Dinner with Sam", "sam dinner!"))
        XCTAssertTrue(PlanTitleMatch.similar("Dinner w/ Sam", "Dinner"))
        XCTAssertTrue(PlanTitleMatch.similar("Drinks with Sam", "Pub with Sam"))
        XCTAssertTrue(PlanTitleMatch.similar("Coffee with Zoë", "coffee w zoe"))
        XCTAssertFalse(PlanTitleMatch.similar("Dinner with Sam", "Dinner with Alex"))
        XCTAssertFalse(PlanTitleMatch.similar("Gym", "BEM2031 Lecture"))
    }
}
