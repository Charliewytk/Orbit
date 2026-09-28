import Foundation
import OrbitCore

/// Adds a plain event (an accepted plan) to the "Orbit" Google calendar.
/// `GoogleCalendarClient` writes study blocks; this covers one-off events,
/// and it only ever writes to the Orbit calendar.
struct GoogleEventWriter {
    var tokens: AccessTokenProvider
    var http = HTTPClient()

    private struct Time: Encodable { let dateTime: String; let timeZone: String }
    private struct Body: Encodable {
        let summary: String
        let description: String?
        let location: String?
        let start: Time
        let end: Time
    }
    private struct Created: Decodable { let id: String }

    func insert(_ event: CalendarEvent, calendarID: String, timeZone: TimeZone) async throws -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        let body = Body(summary: event.title, description: event.notes, location: event.location,
                        start: Time(dateTime: f.string(from: event.start), timeZone: timeZone.identifier),
                        end: Time(dateTime: f.string(from: max(event.end, event.start.addingTimeInterval(900))),
                                  timeZone: timeZone.identifier))
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(FormEncoding.escape(calendarID))/events")!
        let token = try await tokens.accessToken()
        return try await http.post(Created.self, url, body: body, headers: ["Authorization": "Bearer \(token)"]).id
    }
}
