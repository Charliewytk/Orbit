import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPError: Error, CustomStringConvertible, Sendable {
    public var status: Int
    public var body: String
    public var url: String
    public var description: String { "HTTP \(status) from \(url): \(body.prefix(300))" }
}

/// Anything that can send a request. Real code uses URLSession; tests use a stub.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: request) { data, response, error in
                if let error { cont.resume(throwing: error); return }
                guard let response else {
                    cont.resume(throwing: HTTPError(status: -1, body: "No response", url: request.url?.absoluteString ?? ""))
                    return
                }
                cont.resume(returning: (data ?? Data(), response))
            }
            task.resume()
        }
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError(status: -1, body: "No HTTP response", url: request.url?.absoluteString ?? "")
        }
        return (data, http)
    }
}

/// Small JSON-over-HTTP helper used by every API client.
public struct HTTPClient: Sendable {
    public var transport: HTTPTransport
    public var timeout: TimeInterval

    public init(transport: HTTPTransport = URLSessionTransport(), timeout: TimeInterval = 60) {
        self.transport = transport; self.timeout = timeout
    }

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let s = try? c.decode(String.self), let date = ISO8601.parse(s) { return date }
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSince1970: n) }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised date")
        }
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public func data(_ method: String = "GET", _ url: URL, headers: [String: String] = [:],
                     body: Data? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout ?? self.timeout)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let (data, resp) = try await transport.send(req)
        guard (200..<300).contains(resp.statusCode) else {
            throw HTTPError(status: resp.statusCode, body: String(decoding: data, as: UTF8.self), url: url.absoluteString)
        }
        return data
    }

    public func json<T: Decodable>(_ type: T.Type, _ method: String = "GET", _ url: URL,
                                   headers: [String: String] = [:], body: Data? = nil,
                                   timeout: TimeInterval? = nil) async throws -> T {
        var h = headers
        h["Accept"] = h["Accept"] ?? "application/json"
        if body != nil { h["Content-Type"] = h["Content-Type"] ?? "application/json" }
        let data = try await self.data(method, url, headers: h, body: body, timeout: timeout)
        return try Self.decoder.decode(T.self, from: data)
    }

    public func get<T: Decodable>(_ type: T.Type, _ url: URL, headers: [String: String] = [:],
                                  timeout: TimeInterval? = nil) async throws -> T {
        try await json(T.self, "GET", url, headers: headers, timeout: timeout)
    }

    public func post<Body: Encodable, T: Decodable>(_ type: T.Type, _ url: URL, body: Body,
                                                    headers: [String: String] = [:],
                                                    timeout: TimeInterval? = nil) async throws -> T {
        try await json(T.self, "POST", url, headers: headers, body: try Self.encoder.encode(body), timeout: timeout)
    }

    /// application/x-www-form-urlencoded POST (OAuth token endpoints, Moodle).
    public func form<T: Decodable>(_ type: T.Type, _ url: URL, fields: [(String, String)],
                                   headers: [String: String] = [:]) async throws -> T {
        var h = headers
        h["Content-Type"] = "application/x-www-form-urlencoded"
        return try await json(T.self, "POST", url, headers: h, body: Data(FormEncoding.encode(fields).utf8))
    }
}

public enum FormEncoding {
    static let allowed: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()

    public static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    public static func encode(_ fields: [(String, String)]) -> String {
        fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }
}

public enum ISO8601 {
    public static func parse(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return d }
        // Graph returns "2024-01-01T10:00:00.0000000" without zone for some fields.
        let f3 = DateFormatter()
        f3.locale = Locale(identifier: "en_US_POSIX")
        f3.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f3.dateFormat = fmt
            if let d = f3.date(from: s) { return d }
        }
        return nil
    }

    public static func string(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
