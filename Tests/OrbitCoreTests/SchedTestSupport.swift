import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OrbitCore

/// Fixed dates in Europe/London for scheduling, parsing, auth and brief tests.
enum SchedFixtures {
    static let tz = TimeZone(identifier: "Europe/London")!
    static let cal = DayCalendar(timeZone: tz)

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(year: y, month: mo, day: d, hour: h, minute: mi)!
    }

    /// Monday 5 October 2026.
    static let monday = date(2026, 10, 5)

    static func task(_ title: String, minutes: Int = 60, deadline: Date? = nil, priority: Priority = .normal,
                     energy: Energy = .medium, earliestStart: Date? = nil, minBlock: Int = 25, maxBlock: Int = 120,
                     done: Int = 0, index: Int = 0) -> OrbitTask {
        OrbitTask(id: uuid(index), title: title, estimateMinutes: minutes, deadline: deadline,
                  earliestStart: earliestStart, priority: priority, energy: energy,
                  minutesDone: done, minBlockMinutes: minBlock, maxBlockMinutes: maxBlock,
                  createdAt: date(2026, 9, 1))
    }

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    static func event(_ title: String, _ start: Date, _ end: Date, busy: Bool = true, allDay: Bool = false,
                      source: CalendarSource = .google) -> CalendarEvent {
        CalendarEvent(id: title, title: title, start: start, end: end, isAllDay: allDay, source: source, isBusy: busy)
    }
}

/// Records requests and replies from a handler. Shared by Auth and Google Calendar tests.
final class SchedStubTransport: HTTPTransport, @unchecked Sendable {
    struct Recorded {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?
        var bodyString: String { body.map { String(decoding: $0, as: UTF8.self) } ?? "" }
        var bodyJSON: [String: Any]? { body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        var query: [String: String] {
            var out: [String: String] = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                out[item.name] = item.value
            }
            return out
        }
    }

    private let lock = NSLock()
    private var _requests: [Recorded] = []
    var handler: (Recorded) -> (Int, String)

    init(handler: @escaping (Recorded) -> (Int, String)) { self.handler = handler }

    var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let rec = Recorded(method: request.httpMethod ?? "GET", url: request.url!,
                           headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody)
        lock.lock(); _requests.append(rec); lock.unlock()
        let (status, body) = handler(rec)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), resp)
    }
}
