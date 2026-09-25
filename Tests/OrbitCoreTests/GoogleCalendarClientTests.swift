import XCTest
@testable import OrbitCore

final class GoogleCalendarClientTests: XCTestCase {
    typealias F = SchedFixtures
    let base = "https://www.googleapis.com/calendar/v3"

    func client(_ stub: SchedStubTransport, orbitID: String? = "orbit123") -> GoogleCalendarClient {
        GoogleCalendarClient(http: HTTPClient(transport: stub), tokens: StaticTokenProvider("tok"),
                             orbitCalendarID: orbitID, timeZone: F.tz)
    }

    static let calendarPage1 = """
    {"items":[
      {"id":"me@gmail.com","summary":"me@gmail.com","primary":true,"accessRole":"owner","timeZone":"Europe/London","selected":true},
      {"id":"en.uk#holiday@group.v.calendar.google.com","summary":"UK Holidays","accessRole":"reader","selected":true}
    ],"nextPageToken":"p2"}
    """
    static let calendarPage2 = """
    {"items":[
      {"id":"orbit123","summary":"Orbit","accessRole":"owner"},
      {"id":"hidden1","summary":"Old","accessRole":"owner","hidden":true}
    ]}
    """

    func testListCalendarsPages() async throws {
        let stub = SchedStubTransport { r in
            (200, r.query["pageToken"] == "p2" ? Self.calendarPage2 : Self.calendarPage1)
        }
        let cals = try await client(stub).listCalendars()
        XCTAssertEqual(cals.map(\.id), ["me@gmail.com", "en.uk#holiday@group.v.calendar.google.com", "orbit123", "hidden1"])
        XCTAssertTrue(cals[0].isPrimary)
        XCTAssertTrue(cals[0].canWrite)
        XCTAssertFalse(cals[1].canWrite)
        XCTAssertTrue(cals[3].hidden)
        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertEqual(stub.requests[0].headers["Authorization"], "Bearer tok")
        XCTAssertTrue(stub.requests[0].url.absoluteString.hasPrefix(base + "/users/me/calendarList"))
    }

    static let eventsPage1 = """
    {"timeZone":"Europe/London","items":[
      {"id":"e1","status":"confirmed","summary":"BEM2031 Lecture","location":"Forum","start":{"dateTime":"2026-10-05T09:00:00+01:00"},"end":{"dateTime":"2026-10-05T11:00:00+01:00"}},
      {"id":"e2","summary":"Essay due","start":{"date":"2026-10-12"},"end":{"date":"2026-10-13"}},
      {"id":"e3","summary":"Maybe gym","transparency":"transparent","start":{"dateTime":"2026-10-05T18:00:00Z"},"end":{"dateTime":"2026-10-05T19:00:00Z"}},
      {"id":"e4","status":"cancelled","summary":"Cancelled","start":{"dateTime":"2026-10-06T09:00:00+01:00"},"end":{"dateTime":"2026-10-06T10:00:00+01:00"}}
    ],"nextPageToken":"n2"}
    """
    static let eventsPage2 = """
    {"items":[
      {"id":"e5","summary":"Declined meeting","attendees":[{"email":"me@gmail.com","self":true,"responseStatus":"declined"}],"start":{"dateTime":"2026-10-07T12:00:00+01:00"},"end":{"dateTime":"2026-10-07T13:00:00+01:00"}}
    ]}
    """

    func testListEventsMapsAllDayTransparencyAndPaging() async throws {
        let stub = SchedStubTransport { r in (200, r.query["pageToken"] == "n2" ? Self.eventsPage2 : Self.eventsPage1) }
        let from = F.date(2026, 10, 5), to = F.date(2026, 10, 12)
        let events = try await client(stub).listEvents(calendarID: "en.uk#holiday@group.v.calendar.google.com", from: from, to: to)
        XCTAssertEqual(events.map(\.id), ["e1", "e2", "e3", "e5"])

        XCTAssertEqual(events[0].start, F.date(2026, 10, 5, 9))
        XCTAssertEqual(events[0].end, F.date(2026, 10, 5, 11))
        XCTAssertEqual(events[0].location, "Forum")
        XCTAssertTrue(events[0].isBusy)
        XCTAssertFalse(events[0].isAllDay)
        XCTAssertEqual(events[0].source, .google)

        XCTAssertTrue(events[1].isAllDay)
        XCTAssertEqual(events[1].start, F.date(2026, 10, 12), "all-day dates are London midnight, not UTC")
        XCTAssertEqual(events[1].end, F.date(2026, 10, 13))

        XCTAssertFalse(events[2].isBusy)
        XCTAssertFalse(events[3].isBusy, "declined events don't block")

        let q = stub.requests[0].query
        XCTAssertEqual(q["singleEvents"], "true")
        XCTAssertEqual(q["orderBy"], "startTime")
        XCTAssertEqual(q["timeMin"], "2026-10-04T23:00:00Z")
        XCTAssertEqual(q["timeMax"], "2026-10-11T23:00:00Z")
        XCTAssertTrue(stub.requests[0].url.absoluteString
            .hasPrefix(base + "/calendars/en.uk%23holiday%40group.v.calendar.google.com/events?"))
        XCTAssertEqual(stub.requests[1].query["pageToken"], "n2")
    }

    func testListEventsAcrossVisibleCalendars() async throws {
        let stub = SchedStubTransport { r in
            let u = r.url.absoluteString
            if u.contains("calendarList") { return (200, r.query["pageToken"] == "p2" ? Self.calendarPage2 : Self.calendarPage1) }
            if u.contains("/calendars/orbit123/events") {
                return (200, #"{"items":[{"id":"o1","summary":"Essay","start":{"dateTime":"2026-10-05T08:00:00+01:00"},"end":{"dateTime":"2026-10-05T09:00:00+01:00"}}]}"#)
            }
            if u.contains("hidden1") { return (500, "{}") }
            return (200, #"{"items":[{"id":"x-\#(r.url.path.count)","summary":"Other","start":{"dateTime":"2026-10-05T10:00:00+01:00"},"end":{"dateTime":"2026-10-05T11:00:00+01:00"}}]}"#)
        }
        let events = try await client(stub).listEvents(from: F.date(2026, 10, 5), to: F.date(2026, 10, 6))
        XCTAssertEqual(events.count, 3, "hidden calendar skipped")
        XCTAssertEqual(events.first?.id, "o1")
        XCTAssertEqual(events.first?.source, .orbit)
        XCTAssertEqual(events.first?.calendarID, "orbit123")
    }

    func testFindsExistingOrbitCalendar() async throws {
        let stub = SchedStubTransport { r in (200, r.query["pageToken"] == "p2" ? Self.calendarPage2 : Self.calendarPage1) }
        let c = client(stub, orbitID: nil)
        let id = try await c.findOrCreateOrbitCalendar()
        XCTAssertEqual(id, "orbit123")
        XCTAssertFalse(stub.requests.contains { $0.method == "POST" })
        let stored = await c.orbitCalendarID
        XCTAssertEqual(stored, "orbit123")
    }

    func testCreatesOrbitCalendarWhenMissing() async throws {
        let stub = SchedStubTransport { r in
            if r.method == "POST" { return (200, #"{"id":"newcal@group.calendar.google.com","summary":"Orbit"}"#) }
            return (200, Self.calendarPage2.replacingOccurrences(of: "\"Orbit\"", with: "\"Not orbit\""))
        }
        let c = client(stub, orbitID: nil)
        let id = try await c.findOrCreateOrbitCalendar()
        XCTAssertEqual(id, "newcal@group.calendar.google.com")
        let post = stub.requests.first { $0.method == "POST" }!
        XCTAssertEqual(post.url.absoluteString, base + "/calendars")
        XCTAssertEqual(post.bodyJSON?["summary"] as? String, "Orbit")
        XCTAssertEqual(post.bodyJSON?["timeZone"] as? String, "Europe/London")
        _ = try await c.findOrCreateOrbitCalendar()
        XCTAssertEqual(stub.requests.count, 2, "ID is cached")
    }

    func block() -> ScheduledBlock {
        ScheduledBlock(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, taskID: F.uuid(7),
                       title: "Essay plan", start: F.date(2026, 10, 5, 9), end: F.date(2026, 10, 5, 10, 30),
                       moduleCode: "BEM2031")
    }

    func testCreateEventTagsBlock() async throws {
        let stub = SchedStubTransport { _ in (200, #"{"id":"evt1"}"#) }
        let created = try await client(stub).createEvent(for: block())
        XCTAssertEqual(created.externalEventID, "evt1")
        let req = stub.requests[0]
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.url.absoluteString, base + "/calendars/orbit123/events")
        let json = try XCTUnwrap(req.bodyJSON)
        XCTAssertEqual(json["summary"] as? String, "Essay plan")
        let start = json["start"] as? [String: Any]
        XCTAssertEqual(start?["dateTime"] as? String, "2026-10-05T09:00:00+01:00")
        XCTAssertEqual(start?["timeZone"] as? String, "Europe/London")
        let props = (json["extendedProperties"] as? [String: Any])?["private"] as? [String: String]
        XCTAssertEqual(props?["orbitBlock"], "orbit-block:11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(props?["orbitTask"], F.uuid(7).uuidString)
        XCTAssertEqual(props?["orbitModule"], "BEM2031")
    }

    func testUpdateUsesPatchAndRecreatesMissingEvents() async throws {
        var b = block()
        b.externalEventID = "evt1"
        let stub = SchedStubTransport { r in (200, #"{"id":"evt1"}"#) }
        let updated = try await client(stub).updateEvent(for: b)
        XCTAssertEqual(updated.externalEventID, "evt1")
        XCTAssertEqual(stub.requests[0].method, "PATCH")
        XCTAssertEqual(stub.requests[0].url.absoluteString, base + "/calendars/orbit123/events/evt1")

        let gone = SchedStubTransport { r in r.method == "PATCH" ? (404, #"{"error":{"code":404}}"#) : (200, #"{"id":"evt2"}"#) }
        let recreated = try await client(gone).updateEvent(for: b)
        XCTAssertEqual(recreated.externalEventID, "evt2")
        XCTAssertEqual(gone.requests.map(\.method), ["PATCH", "POST"])
    }

    func testDeleteFindsEventByTagAndIgnoresMissing() async throws {
        let stub = SchedStubTransport { r in
            if r.method == "GET" { return (200, #"{"items":[{"id":"found1","start":{"dateTime":"2026-10-05T09:00:00Z"}}]}"#) }
            return (410, "{}")
        }
        try await client(stub).deleteEvent(for: block())
        XCTAssertEqual(stub.requests.map(\.method), ["GET", "DELETE"])
        XCTAssertEqual(stub.requests[0].query["privateExtendedProperty"],
                       "orbitBlock=orbit-block:11111111-2222-3333-4444-555555555555")
        XCTAssertTrue(stub.requests[1].url.absoluteString.hasSuffix("/calendars/orbit123/events/found1"))
    }

    func testApplyChangeSet() async throws {
        var counter = 0
        let stub = SchedStubTransport { r in
            if r.method == "POST" { counter += 1; return (200, #"{"id":"new\#(counter)"}"#) }
            return (200, #"{"id":"upd"}"#)
        }
        var upd = block(); upd.id = F.uuid(2); upd.externalEventID = "upd"
        var del = block(); del.id = F.uuid(3); del.externalEventID = "old"
        var keep = block(); keep.id = F.uuid(4); keep.externalEventID = "keep"
        var create = block(); create.id = F.uuid(5)
        let changes = CalendarChangeSet(create: [create], update: [upd], delete: [del], unchanged: [keep])
        let result = try await client(stub).apply(changes)
        XCTAssertEqual(Set(result.compactMap(\.externalEventID)), ["keep", "upd", "new1"])
        XCTAssertEqual(stub.requests.map(\.method), ["DELETE", "PATCH", "POST"])
    }

    func testListOrbitBlocksReadsTags() async throws {
        let stub = SchedStubTransport { _ in
            (200, """
            {"items":[
              {"id":"evt9","summary":"Essay plan","start":{"dateTime":"2026-10-05T09:00:00+01:00"},"end":{"dateTime":"2026-10-05T10:00:00+01:00"},
               "extendedProperties":{"private":{"orbitBlock":"orbit-block:11111111-2222-3333-4444-555555555555","orbitTask":"\(F.uuid(7).uuidString)"}}},
              {"id":"manual","summary":"Added by hand","start":{"dateTime":"2026-10-05T12:00:00+01:00"},"end":{"dateTime":"2026-10-05T13:00:00+01:00"}}
            ]}
            """)
        }
        let blocks = try await client(stub).listOrbitBlocks(from: F.date(2026, 10, 5), to: F.date(2026, 10, 6))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].id, UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        XCTAssertEqual(blocks[0].taskID, F.uuid(7))
        XCTAssertEqual(blocks[0].externalEventID, "evt9")
        XCTAssertEqual(blocks[0].minutes, 60)
    }

    func testFreeBusy() async throws {
        let stub = SchedStubTransport { _ in
            (200, #"{"kind":"calendar#freeBusy","calendars":{"me@gmail.com":{"busy":[{"start":"2026-10-05T08:00:00Z","end":"2026-10-05T09:30:00Z"}]},"x":{"errors":[{"reason":"notFound"}]}}}"#)
        }
        let busy = try await client(stub).freeBusy(from: F.date(2026, 10, 5), to: F.date(2026, 10, 6), calendarIDs: ["me@gmail.com", "x"])
        XCTAssertEqual(busy["me@gmail.com"]?.first?.duration, 5400)
        XCTAssertEqual(busy["x"], [])
        let body = try XCTUnwrap(stub.requests[0].bodyJSON)
        XCTAssertEqual((body["items"] as? [[String: String]])?.map { $0["id"] }, ["me@gmail.com", "x"])
        XCTAssertEqual(stub.requests[0].url.absoluteString, base + "/freeBusy")
    }
}

final class GoogleCalendarOutlookTests: XCTestCase {
    typealias F = SchedFixtures

    func testCalendarViewPagingAndMapping() async throws {
        let page1 = """
        {"value":[
          {"id":"m1","subject":"Tutorial","isAllDay":false,"isCancelled":false,"showAs":"busy","location":{"displayName":"Amory 128"},
           "start":{"dateTime":"2026-10-05T14:00:00.0000000","timeZone":"Europe/London"},"end":{"dateTime":"2026-10-05T15:00:00.0000000","timeZone":"Europe/London"}},
          {"id":"m2","subject":"Reading week","isAllDay":true,"showAs":"free",
           "start":{"dateTime":"2026-10-12T00:00:00.0000000","timeZone":"Europe/London"},"end":{"dateTime":"2026-10-17T00:00:00.0000000","timeZone":"Europe/London"}}
        ],"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/calendarView?$skip=2"}
        """
        let page2 = """
        {"value":[
          {"id":"m3","subject":"Cancelled lab","isCancelled":true,"start":{"dateTime":"2026-10-06T09:00:00.0000000","timeZone":"Europe/London"},"end":{"dateTime":"2026-10-06T10:00:00.0000000","timeZone":"Europe/London"}},
          {"id":"m4","subject":"UTC one","showAs":"tentative","start":{"dateTime":"2026-10-06T09:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-10-06T10:00:00.0000000","timeZone":"UTC"}}
        ]}
        """
        let stub = SchedStubTransport { r in (200, r.url.absoluteString.contains("skip") ? page2 : page1) }
        let client = OutlookCalendarClient(http: HTTPClient(transport: stub), tokens: StaticTokenProvider("ms"), timeZone: F.tz)
        let events = try await client.listEvents(from: F.date(2026, 10, 5), to: F.date(2026, 10, 19))
        XCTAssertEqual(events.map(\.id), ["m1", "m4", "m2"])
        XCTAssertEqual(events[0].start, F.date(2026, 10, 5, 14))
        XCTAssertEqual(events[0].location, "Amory 128")
        XCTAssertEqual(events[0].source, .outlook)
        XCTAssertEqual(events[0].calendarID, "exeter")
        XCTAssertEqual(events[1].start, F.date(2026, 10, 6, 10), "09:00 UTC is 10:00 BST")
        XCTAssertTrue(events[1].isBusy)
        XCTAssertTrue(events[2].isAllDay)
        XCTAssertFalse(events[2].isBusy)
        XCTAssertEqual(events[2].start, F.date(2026, 10, 12))

        let first = stub.requests[0]
        XCTAssertEqual(first.headers["Authorization"], "Bearer ms")
        XCTAssertEqual(first.headers["Prefer"], "outlook.timezone=\"Europe/London\"")
        XCTAssertTrue(first.url.absoluteString.hasPrefix("https://graph.microsoft.com/v1.0/me/calendarView?startDateTime="))
        XCTAssertEqual(first.query["startDateTime"], "2026-10-04T23:00:00Z")
        XCTAssertEqual(stub.requests.count, 2)
    }
}
