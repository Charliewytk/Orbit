import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A calendar in the user's Google calendar list.
public struct GoogleCalendarInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var summary: String
    public var isPrimary: Bool
    public var accessRole: String?
    public var timeZone: String?
    public var backgroundColor: String?
    public var selected: Bool
    public var hidden: Bool

    public var canWrite: Bool { accessRole == "owner" || accessRole == "writer" }
}

/// Google Calendar API v3. Reads every calendar; writes only to the
/// dedicated "Orbit" calendar, tagging each event with its block ID in
/// `extendedProperties.private` so Orbit can find its own events again.
public actor GoogleCalendarClient {
    public static let orbitCalendarName = "Orbit"
    /// Private extended property holding "orbit-block:<uuid>".
    public static let blockPropertyKey = "orbitBlock"
    public static let taskPropertyKey = "orbitTask"

    public static func blockTag(_ id: UUID) -> String { "orbit-block:\(id.uuidString.lowercased())" }

    public nonisolated let http: HTTPClient
    public nonisolated let tokens: AccessTokenProvider
    public nonisolated let baseURL: URL
    public nonisolated let timeZone: TimeZone
    /// ID of the "Orbit" calendar once found or created. Persist it and pass it back in.
    public private(set) var orbitCalendarID: String?

    public init(http: HTTPClient = HTTPClient(), tokens: AccessTokenProvider, orbitCalendarID: String? = nil,
                timeZone: TimeZone = TimeZone(identifier: "Europe/London")!,
                baseURL: URL = URL(string: "https://www.googleapis.com/calendar/v3")!) {
        self.http = http; self.tokens = tokens; self.orbitCalendarID = orbitCalendarID
        self.timeZone = timeZone; self.baseURL = baseURL
    }

    public func setOrbitCalendarID(_ id: String?) { orbitCalendarID = id }

    // MARK: - Wire types

    struct CalendarListResponse: Decodable {
        struct Entry: Decodable {
            let id: String
            let summary: String?
            let summaryOverride: String?
            let primary: Bool?
            let accessRole: String?
            let timeZone: String?
            let backgroundColor: String?
            let selected: Bool?
            let hidden: Bool?
            let deleted: Bool?
        }
        let items: [Entry]?
        let nextPageToken: String?
    }

    struct EventTime: Codable {
        var date: String?
        var dateTime: String?
        var timeZone: String?
    }

    struct ExtendedProperties: Codable {
        var privateProperties: [String: String]?
        enum CodingKeys: String, CodingKey { case privateProperties = "private" }
    }

    struct Attendee: Decodable {
        let isSelf: Bool?
        let responseStatus: String?
        enum CodingKeys: String, CodingKey { case isSelf = "self", responseStatus }
    }

    struct EventResource: Decodable {
        let id: String
        let status: String?
        let summary: String?
        let description: String?
        let location: String?
        let start: EventTime?
        let end: EventTime?
        let transparency: String?
        let attendees: [Attendee]?
        let extendedProperties: ExtendedProperties?
    }

    struct EventsResponse: Decodable {
        let items: [EventResource]?
        let nextPageToken: String?
        let timeZone: String?
    }

    struct EventBody: Encodable {
        struct Reminders: Encodable { let useDefault: Bool }
        let summary: String
        let description: String
        let start: EventTime
        let end: EventTime
        let transparency: String
        let extendedProperties: ExtendedProperties
        let reminders: Reminders
    }

    struct CreatedCalendar: Decodable { let id: String }
    struct NewCalendar: Encodable { let summary: String; let description: String; let timeZone: String }

    struct FreeBusyRequest: Encodable {
        struct Item: Encodable { let id: String }
        let timeMin: String
        let timeMax: String
        let timeZone: String
        let items: [Item]
    }

    struct FreeBusyResponse: Decodable {
        struct Period: Decodable { let start: String; let end: String }
        struct Cal: Decodable { let busy: [Period]? }
        let calendars: [String: Cal]
    }

    // MARK: - Requests

    private func url(_ path: String, _ query: [(String, String)] = []) -> URL {
        var s = baseURL.absoluteString + path
        if !query.isEmpty { s += "?" + FormEncoding.encode(query) }
        return URL(string: s)!
    }

    private static func seg(_ s: String) -> String { FormEncoding.escape(s) }

    private func headers() async throws -> [String: String] {
        ["Authorization": "Bearer \(try await tokens.accessToken())"]
    }

    // MARK: - Calendars

    public func listCalendars() async throws -> [GoogleCalendarInfo] {
        var out: [GoogleCalendarInfo] = []
        var pageToken: String?
        repeat {
            var q: [(String, String)] = [("maxResults", "250")]
            if let pageToken { q.append(("pageToken", pageToken)) }
            let res = try await http.get(CalendarListResponse.self, url("/users/me/calendarList", q), headers: try await headers())
            for e in res.items ?? [] where e.deleted != true {
                out.append(GoogleCalendarInfo(id: e.id, summary: e.summaryOverride ?? e.summary ?? e.id,
                                              isPrimary: e.primary ?? false, accessRole: e.accessRole,
                                              timeZone: e.timeZone, backgroundColor: e.backgroundColor,
                                              selected: e.selected ?? false, hidden: e.hidden ?? false))
            }
            pageToken = res.nextPageToken
        } while pageToken != nil
        return out
    }

    /// Finds the calendar named "Orbit" that we own, or creates it. The ID is remembered.
    @discardableResult
    public func findOrCreateOrbitCalendar() async throws -> String {
        if let orbitCalendarID { return orbitCalendarID }
        let existing = try await listCalendars().first {
            $0.summary == Self.orbitCalendarName && $0.accessRole == "owner"
        }
        if let existing {
            orbitCalendarID = existing.id
            return existing.id
        }
        let body = NewCalendar(summary: Self.orbitCalendarName,
                               description: "Study blocks planned by Orbit. Safe to hide; don't edit by hand.",
                               timeZone: timeZone.identifier)
        let created = try await http.post(CreatedCalendar.self, url("/calendars"), body: body, headers: try await headers())
        orbitCalendarID = created.id
        return created.id
    }

    // MARK: - Reading events

    /// Events in one calendar, expanded (recurring events become single instances).
    public func listEvents(calendarID: String, from start: Date, to end: Date) async throws -> [CalendarEvent] {
        var out: [CalendarEvent] = []
        var pageToken: String?
        let source: CalendarSource = calendarID == orbitCalendarID ? .orbit : .google
        repeat {
            var q: [(String, String)] = [
                ("timeMin", ISO8601.string(start)), ("timeMax", ISO8601.string(end)),
                ("singleEvents", "true"), ("orderBy", "startTime"), ("maxResults", "250"),
            ]
            if let pageToken { q.append(("pageToken", pageToken)) }
            let res = try await http.get(EventsResponse.self, url("/calendars/\(Self.seg(calendarID))/events", q),
                                         headers: try await headers())
            let tz = res.timeZone.flatMap(TimeZone.init(identifier:)) ?? timeZone
            out += (res.items ?? []).compactMap { Self.map($0, calendarID: calendarID, source: source, timeZone: tz) }
            pageToken = res.nextPageToken
        } while pageToken != nil
        return out
    }

    /// Events across calendars (default: every visible calendar), sorted by start.
    public func listEvents(from start: Date, to end: Date, calendarIDs: [String]? = nil) async throws -> [CalendarEvent] {
        let ids: [String]
        if let calendarIDs {
            ids = calendarIDs
        } else {
            ids = try await listCalendars().filter { !$0.hidden }.map(\.id)
        }
        var all: [CalendarEvent] = []
        for id in ids { all += try await listEvents(calendarID: id, from: start, to: end) }
        return all.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
    }

    static func parseTime(_ t: EventTime?, timeZone: TimeZone) -> (Date, Bool)? {
        guard let t else { return nil }
        if let dt = t.dateTime, let d = ISO8601.parse(dt) { return (d, false) }
        if let day = t.date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = t.timeZone.flatMap(TimeZone.init(identifier:)) ?? timeZone
            f.dateFormat = "yyyy-MM-dd"
            if let d = f.date(from: day) { return (d, true) }
        }
        return nil
    }

    static func map(_ e: EventResource, calendarID: String, source: CalendarSource, timeZone: TimeZone) -> CalendarEvent? {
        guard e.status != "cancelled", let (start, allDay) = parseTime(e.start, timeZone: timeZone) else { return nil }
        let end = parseTime(e.end, timeZone: timeZone)?.0 ?? start.addingTimeInterval(allDay ? 86400 : 3600)
        let declined = e.attendees?.contains { $0.isSelf == true && $0.responseStatus == "declined" } ?? false
        return CalendarEvent(id: e.id, title: e.summary ?? "(no title)", start: start, end: end, isAllDay: allDay,
                             location: e.location, notes: e.description, calendarID: calendarID, source: source,
                             isBusy: e.transparency != "transparent" && !declined)
    }

    /// Orbit's own blocks as currently on the calendar (read back from the tags).
    public func listOrbitBlocks(from start: Date, to end: Date) async throws -> [ScheduledBlock] {
        let calID = try await findOrCreateOrbitCalendar()
        var out: [ScheduledBlock] = []
        var pageToken: String?
        repeat {
            var q: [(String, String)] = [
                ("timeMin", ISO8601.string(start)), ("timeMax", ISO8601.string(end)),
                ("singleEvents", "true"), ("orderBy", "startTime"), ("maxResults", "250"),
            ]
            if let pageToken { q.append(("pageToken", pageToken)) }
            let res = try await http.get(EventsResponse.self, url("/calendars/\(Self.seg(calID))/events", q),
                                         headers: try await headers())
            for e in res.items ?? [] where e.status != "cancelled" {
                let props = e.extendedProperties?.privateProperties ?? [:]
                guard let tag = props[Self.blockPropertyKey], tag.hasPrefix("orbit-block:"),
                      let id = UUID(uuidString: String(tag.dropFirst("orbit-block:".count))),
                      let taskID = props[Self.taskPropertyKey].flatMap(UUID.init(uuidString:)),
                      let (s, _) = Self.parseTime(e.start, timeZone: timeZone),
                      let (en, _) = Self.parseTime(e.end, timeZone: timeZone) else { continue }
                out.append(ScheduledBlock(id: id, taskID: taskID, title: e.summary ?? "", start: s, end: en,
                                          moduleCode: props["orbitModule"], externalEventID: e.id))
            }
            pageToken = res.nextPageToken
        } while pageToken != nil
        return out
    }

    // MARK: - Writing blocks

    func body(for block: ScheduledBlock) -> EventBody {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        var props = [Self.blockPropertyKey: Self.blockTag(block.id), Self.taskPropertyKey: block.taskID.uuidString]
        if let m = block.moduleCode { props["orbitModule"] = m }
        var description = "Planned by Orbit."
        if let m = block.moduleCode { description += " Module: \(m)." }
        return EventBody(summary: block.title, description: description,
                         start: EventTime(dateTime: f.string(from: block.start), timeZone: timeZone.identifier),
                         end: EventTime(dateTime: f.string(from: block.end), timeZone: timeZone.identifier),
                         transparency: "opaque", extendedProperties: ExtendedProperties(privateProperties: props),
                         reminders: .init(useDefault: false))
    }

    /// Writes a block to the Orbit calendar. Returns it with `externalEventID` set.
    public func createEvent(for block: ScheduledBlock) async throws -> ScheduledBlock {
        let calID = try await findOrCreateOrbitCalendar()
        let created = try await http.post(EventResource.self, url("/calendars/\(Self.seg(calID))/events"),
                                          body: body(for: block), headers: try await headers())
        var b = block
        b.externalEventID = created.id
        return b
    }

    /// Moves/renames a block's event (creates it if it no longer exists).
    public func updateEvent(for block: ScheduledBlock) async throws -> ScheduledBlock {
        let calID = try await findOrCreateOrbitCalendar()
        var eventID = block.externalEventID
        if eventID == nil { eventID = try await findEventID(blockID: block.id) }
        guard let eventID else { return try await createEvent(for: block) }
        do {
            let data = try HTTPClient.encoder.encode(body(for: block))
            let updated = try await http.json(EventResource.self, "PATCH",
                                              url("/calendars/\(Self.seg(calID))/events/\(Self.seg(eventID))"),
                                              headers: try await headers(), body: data)
            var b = block
            b.externalEventID = updated.id
            return b
        } catch let e as HTTPError where e.status == 404 || e.status == 410 {
            var b = block
            b.externalEventID = nil
            return try await createEvent(for: b)
        }
    }

    /// Removes a block's event. Missing events are ignored.
    public func deleteEvent(for block: ScheduledBlock) async throws {
        let calID = try await findOrCreateOrbitCalendar()
        var eventID = block.externalEventID
        if eventID == nil { eventID = try await findEventID(blockID: block.id) }
        guard let eventID else { return }
        do {
            _ = try await http.data("DELETE", url("/calendars/\(Self.seg(calID))/events/\(Self.seg(eventID))"),
                                    headers: try await headers())
        } catch let e as HTTPError where e.status == 404 || e.status == 410 {
            return
        }
    }

    /// Looks up a block's event by its private tag.
    public func findEventID(blockID: UUID) async throws -> String? {
        let calID = try await findOrCreateOrbitCalendar()
        let q: [(String, String)] = [
            ("privateExtendedProperty", "\(Self.blockPropertyKey)=\(Self.blockTag(blockID))"),
            ("showDeleted", "false"), ("maxResults", "5"),
        ]
        let res = try await http.get(EventsResponse.self, url("/calendars/\(Self.seg(calID))/events", q),
                                     headers: try await headers())
        return res.items?.first { $0.status != "cancelled" }?.id
    }

    /// Applies a `Replanner` change set. Returns every resulting block with event IDs filled in.
    public func apply(_ changes: CalendarChangeSet) async throws -> [ScheduledBlock] {
        var out = changes.unchanged
        for b in changes.delete { try await deleteEvent(for: b) }
        for b in changes.update { out.append(try await updateEvent(for: b)) }
        for b in changes.create { out.append(try await createEvent(for: b)) }
        return out.sorted { $0.start < $1.start }
    }

    // MARK: - Free/busy

    /// Busy periods per calendar ID.
    public func freeBusy(from start: Date, to end: Date, calendarIDs: [String]) async throws -> [String: [DateInterval]] {
        let req = FreeBusyRequest(timeMin: ISO8601.string(start), timeMax: ISO8601.string(end),
                                  timeZone: timeZone.identifier, items: calendarIDs.map { .init(id: $0) })
        let res = try await http.post(FreeBusyResponse.self, url("/freeBusy"), body: req, headers: try await headers())
        var out: [String: [DateInterval]] = [:]
        for (id, cal) in res.calendars {
            out[id] = (cal.busy ?? []).compactMap { p in
                guard let s = ISO8601.parse(p.start), let e = ISO8601.parse(p.end), e >= s else { return nil }
                return DateInterval(start: s, end: e)
            }
        }
        return out
    }
}

/// Read-only Exeter (Microsoft 365) calendar via Microsoft Graph `/me/calendarView`.
public struct OutlookCalendarClient: Sendable {
    public var http: HTTPClient
    public var tokens: AccessTokenProvider
    public var baseURL: URL
    public var timeZone: TimeZone
    /// `CalendarEvent.calendarID` for these events.
    public var calendarID: String

    public init(http: HTTPClient = HTTPClient(), tokens: AccessTokenProvider,
                timeZone: TimeZone = TimeZone(identifier: "Europe/London")!, calendarID: String = "exeter",
                baseURL: URL = URL(string: "https://graph.microsoft.com/v1.0")!) {
        self.http = http; self.tokens = tokens; self.timeZone = timeZone
        self.calendarID = calendarID; self.baseURL = baseURL
    }

    struct GraphTime: Decodable { let dateTime: String; let timeZone: String? }
    struct GraphLocation: Decodable { let displayName: String? }
    struct GraphEvent: Decodable {
        let id: String
        let subject: String?
        let isAllDay: Bool?
        let isCancelled: Bool?
        let showAs: String?
        let bodyPreview: String?
        let location: GraphLocation?
        let start: GraphTime
        let end: GraphTime
    }
    struct Page: Decodable {
        let value: [GraphEvent]
        let nextLink: String?
        enum CodingKeys: String, CodingKey { case value, nextLink = "@odata.nextLink" }
    }

    public func listEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let query = "startDateTime=\(FormEncoding.escape(ISO8601.string(start)))"
            + "&endDateTime=\(FormEncoding.escape(ISO8601.string(end)))"
            + "&$top=100&$orderby=start/dateTime"
            + "&$select=id,subject,isAllDay,isCancelled,showAs,bodyPreview,location,start,end"
        var next: URL? = URL(string: baseURL.absoluteString + "/me/calendarView?" + query)
        var out: [CalendarEvent] = []
        while let u = next {
            let headers = [
                "Authorization": "Bearer \(try await tokens.accessToken())",
                "Prefer": "outlook.timezone=\"\(timeZone.identifier)\"",
            ]
            let page = try await http.get(Page.self, u, headers: headers)
            out += page.value.compactMap(map)
            next = page.nextLink.flatMap(URL.init(string:))
        }
        return out.sorted { $0.start < $1.start }
    }

    func parse(_ t: GraphTime) -> Date? {
        let tz = t.timeZone.flatMap(TimeZone.init(identifier:)) ?? timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            f.dateFormat = fmt
            if let d = f.date(from: t.dateTime) { return d }
        }
        return ISO8601.parse(t.dateTime)
    }

    func map(_ e: GraphEvent) -> CalendarEvent? {
        guard e.isCancelled != true, let s = parse(e.start), let en = parse(e.end) else { return nil }
        let showAs = (e.showAs ?? "busy").lowercased()
        return CalendarEvent(id: e.id, title: e.subject ?? "(no title)", start: s, end: en,
                             isAllDay: e.isAllDay ?? false, location: e.location?.displayName,
                             notes: e.bodyPreview, calendarID: calendarID, source: .outlook,
                             isBusy: showAs != "free" && showAs != "workingelsewhere")
    }
}
