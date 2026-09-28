import XCTest
@testable import OrbitCore

final class TicketEmailParserTests: XCTestCase {
    let tz = TimeZone(identifier: "Europe/London")!
    /// Email received Sat 26 Sep 2026, 14:03 London.
    let received = ISO8601.parse("2026-09-26T13:03:00Z")!

    private func london(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        DayCalendar(timeZone: tz).date(year: y, month: m, day: d, hour: h, minute: min)!
    }

    /// A FIXR confirmation as Gmail hands over the plain-text part.
    static let fixrBody = """
    Hi Charles,

    You're going to Timepiece Tuesdays: Freshers Special!

    Your tickets are attached to this email and in the FIXR app. Show the QR code on the door.

    Event: Timepiece Tuesdays: Freshers Special
    Date: Tuesday 29 September 2026
    Time: 22:00 - 03:00
    Venue: Timepiece Nightclub, Little Castle Street, Exeter EX4 3PX

    Ticket type: Early Entry (before 11pm)
    Quantity: 2
    Order reference: FX8K2QZ7

    Need help? Visit fixr.co/support

    FIXR · Ticketing for students
    """

    func testFIXRConfirmation() throws {
        let m = EmailMessage(id: "gm-1", account: .gmail, from: "tickets@fixr.co", fromName: "FIXR",
                             subject: "Your tickets for Timepiece Tuesdays: Freshers Special", body: Self.fixrBody,
                             date: received)
        let t = try XCTUnwrap(TicketEmailParser(timeZone: tz).parse(m))
        XCTAssertEqual(t.provider, .fixr)
        XCTAssertEqual(t.title, "Timepiece Tuesdays: Freshers Special")
        XCTAssertEqual(t.start, london(2026, 9, 29, 22))
        XCTAssertEqual(t.end, london(2026, 9, 30, 3))
        XCTAssertTrue(t.hasTime)
        XCTAssertEqual(t.venue, "Timepiece Nightclub, Little Castle Street, Exeter EX4 3PX")
        XCTAssertEqual(t.orderReference, "FX8K2QZ7")
        XCTAssertEqual(t.quantity, 2)
        XCTAssertEqual(t.ticketType, "Early Entry (before 11pm)")
        XCTAssertTrue(t.planID.hasPrefix("ticket-"))
        // Same event from a second copy of the email → same id.
        var copy = m
        copy.id = "gm-2"
        XCTAssertEqual(TicketEmailParser(timeZone: tz).parse(copy)?.planID, t.planID)
    }

    func testFIXRSubjectOnlyAndCompactDate() throws {
        let body = """
        You're going!
        Sat 3 Oct 2026, 21:00
        Arena Exeter
        Order number 55120394
        """
        let m = EmailMessage(id: "gm-3", account: .gmail, from: "FIXR <noreply@fixr.co>",
                             subject: "Your FIXR tickets for Arena: Welcome Week Finale", body: body, date: received)
        let t = try XCTUnwrap(TicketEmailParser(timeZone: tz).parse(m))
        XCTAssertEqual(t.title, "Arena: Welcome Week Finale")
        XCTAssertEqual(t.start, london(2026, 10, 3, 21))
        XCTAssertEqual(t.end, london(2026, 10, 4, 0))
    }

    func testEventbriteDateWithoutTime() throws {
        let body = """
        Thanks for your order!
        When
        Thursday, 8 October 2026
        Where
        Exeter Northcott Theatre
        """
        let m = EmailMessage(id: "gm-4", account: .gmail, from: "noreply@order.eventbrite.com",
                             subject: "Your tickets for Economics Society Careers Night", body: body, date: received)
        let t = try XCTUnwrap(TicketEmailParser(timeZone: tz).parse(m))
        XCTAssertEqual(t.provider, .eventbrite)
        XCTAssertEqual(t.title, "Economics Society Careers Night")
        XCTAssertFalse(t.hasTime)
        XCTAssertEqual(t.start, london(2026, 10, 8, 19))
        XCTAssertEqual(t.venue, "Exeter Northcott Theatre")
    }

    func testIgnoresMarketingAndOtherSenders() {
        let promo = EmailMessage(id: "p", account: .gmail, from: "hello@fixr.co",
                                 subject: "Tickets selling fast: Halloween at Timepiece",
                                 body: "Don't miss out. Saturday 31 October 2026. Buy now.", date: received)
        XCTAssertNil(TicketEmailParser(timeZone: tz).parse(promo))
        let friend = EmailMessage(id: "f", account: .gmail, from: "sam@gmail.com",
                                  subject: "Your tickets for Timepiece", body: Self.fixrBody, date: received)
        XCTAssertNil(TicketEmailParser(timeZone: tz).parse(friend))
        XCTAssertEqual(TicketEmailParser.provider(from: "Skiddle <tickets@mail.skiddle.com>"), .skiddle)
        XCTAssertEqual(TicketEmailParser.provider(from: "orders@dice.fm"), .dice)
    }
}
