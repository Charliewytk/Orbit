import Foundation

/// A loosely-typed JSON value. Moodle's web services vary between versions
/// (ints vs strings, missing keys, bools as 0/1), so responses are read through
/// this with lenient accessors rather than strict Decodable structs.
public enum MoodleJSON: Decodable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MoodleJSON])
    case object([String: MoodleJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([MoodleJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: MoodleJSON].self)) }
    }

    public static func parse(_ data: Data) throws -> MoodleJSON {
        try JSONDecoder().decode(MoodleJSON.self, from: data)
    }

    public subscript(key: String) -> MoodleJSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    public subscript(index: Int) -> MoodleJSON {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    public var isNull: Bool { self == .null }
    public var array: [MoodleJSON] { if case .array(let a) = self { return a }; return [] }
    public var object: [String: MoodleJSON]? { if case .object(let o) = self { return o }; return nil }

    public var string: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): b ? "1" : "0"
        default: nil
        }
    }

    public var double: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): b ? 1 : 0
        default: nil
        }
    }

    public var int: Int? { double.flatMap { $0.isFinite ? Int($0.rounded()) : nil } }

    public var bool: Bool? {
        switch self {
        case .bool(let b): b
        case .number(let n): n != 0
        case .string(let s): ["1", "true", "yes"].contains(s.lowercased())
        default: nil
        }
    }

    /// Moodle timestamps are Unix seconds, with 0 meaning "not set".
    public var date: Date? {
        guard let n = double, n > 0 else { return nil }
        return Date(timeIntervalSince1970: n)
    }
}

/// A parameter value for a Moodle web-service call. Arrays and objects are
/// flattened into Moodle's form encoding, e.g. `courseids[0]=5`.
public indirect enum MoodleParam: Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                                  ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral {
    case value(String)
    case list([MoodleParam])
    case dict([String: MoodleParam])

    public init(stringLiteral value: String) { self = .value(value) }
    public init(integerLiteral value: Int) { self = .value(String(value)) }
    public init(booleanLiteral value: Bool) { self = .value(value ? "1" : "0") }
    public init(arrayLiteral elements: MoodleParam...) { self = .list(elements) }

    public static func int(_ n: Int) -> MoodleParam { .value(String(n)) }
    public static func ints(_ ns: [Int]) -> MoodleParam { .list(ns.map(int)) }

    /// Flattens `name` + value into form fields (keys in a stable order).
    public func fields(_ name: String) -> [(String, String)] {
        switch self {
        case .value(let v): [(name, v)]
        case .list(let items): items.enumerated().flatMap { $0.element.fields("\(name)[\($0.offset)]") }
        case .dict(let d): d.keys.sorted().flatMap { d[$0]!.fields("\(name)[\($0)]") }
        }
    }
}

public enum MoodleError: Error, CustomStringConvertible, Sendable, Equatable {
    /// A web-service exception (Moodle returns these with HTTP 200).
    case exception(errorCode: String, message: String)
    /// /login/token.php refused the login.
    case login(errorCode: String?, message: String)
    /// The SSO callback URL didn't contain a token we could read.
    case invalidSSOCallback(String)
    /// The SSO token's signature didn't match md5(site + passport).
    case signatureMismatch
    /// The site has the mobile web service switched off.
    case mobileServiceDisabled
    case unexpectedResponse(String)

    public var description: String {
        switch self {
        case .exception(let code, let msg): "ELE error (\(code)): \(msg)"
        case .login(let code, let msg): "ELE login failed\(code.map { " (\($0))" } ?? ""): \(msg)"
        case .invalidSSOCallback(let s): "Couldn't read the ELE sign-in response: \(s.prefix(120))"
        case .signatureMismatch: "The ELE sign-in response didn't match this request. Please try again."
        case .mobileServiceDisabled: "ELE doesn't allow mobile-app access right now."
        case .unexpectedResponse(let s): "Unexpected reply from ELE: \(s.prefix(200))"
        }
    }

    /// The token has expired or been revoked, so the user needs to sign in again.
    public var needsReauthentication: Bool {
        if case .exception(let code, _) = self { return ["invalidtoken", "accessexception_invalidtoken", "invalidsesskey"].contains(code) }
        return false
    }

    /// The function isn't enabled for the mobile service on this site.
    public var isFunctionUnavailable: Bool {
        if case .exception(let code, let msg) = self {
            return code == "accessexception" || code == "webservice_access_exception"
                || code == "servicenotavailable" || (code == "invalidrecord" && msg.contains("external_functions"))
        }
        return false
    }

    /// Reads Moodle's error shapes: `{exception, errorcode, message}` from the
    /// REST server and `{error, errorcode}` from the login endpoints.
    static func from(_ json: MoodleJSON) -> MoodleError? {
        if let e = exception(from: json) { return e }
        if case .string(let err) = json["error"], json["token"].isNull {
            return .login(errorCode: json["errorcode"].string, message: err)
        }
        return nil
    }

    /// Only the REST server's `{exception, errorcode, message}` shape.
    static func exception(from json: MoodleJSON) -> MoodleError? {
        guard let o = json.object, o["exception"] != nil || (o["errorcode"] != nil && o["message"] != nil) else { return nil }
        return .exception(errorCode: json["errorcode"].string ?? "unknown",
                          message: json["message"].string ?? json["exception"].string ?? "Unknown error")
    }
}
