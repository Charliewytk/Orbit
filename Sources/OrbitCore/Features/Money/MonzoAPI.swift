import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Monzo developer API (https://docs.monzo.com). Optional "advanced" path: the
// student creates a confidential OAuth client at developers.monzo.com, Orbit
// receives the code on a loopback redirect, then the student approves Orbit in
// the Monzo app. Orbit only ever reads (no deposits, withdrawals or other writes).

public struct MonzoClientConfig: Codable, Hashable, Sendable {
    public static let redirectPort: UInt16 = 53682
    public static let redirectPath = "/monzo/callback"
    public static let redirectURI = "http://127.0.0.1:53682/monzo/callback"

    public var clientID: String
    public var clientSecret: String
    public var redirectURI: String

    public init(clientID: String, clientSecret: String, redirectURI: String = MonzoClientConfig.redirectURI) {
        self.clientID = clientID; self.clientSecret = clientSecret; self.redirectURI = redirectURI
    }

    public func authorizeURL(state: String) -> URL {
        var c = URLComponents(string: "https://auth.monzo.com/")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
        ]
        return c.url!
    }
}

public struct MonzoToken: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var userID: String?
    /// Pasted from the API playground (no refresh; ~6 hours).
    public var isPlayground: Bool

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, userID: String? = nil, isPlayground: Bool = false) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        self.userID = userID; self.isPlayground = isPlayground
    }

    public func isExpired(at now: Date, margin: TimeInterval = 120) -> Bool {
        expiresAt.map { $0.addingTimeInterval(-margin) <= now } ?? false
    }
}

public enum MonzoError: Error, CustomStringConvertible, Sendable {
    /// 403: the token exists but the student hasn't approved Orbit in the Monzo app yet.
    case awaitingApproval
    /// 401: expired or revoked.
    case unauthorised
    /// 429: slow down.
    case rateLimited
    case http(Int, String)

    public var description: String {
        switch self {
        case .awaitingApproval: "Approve Orbit in your Monzo app (check for a notification), then try again."
        case .unauthorised: "Monzo sign-in expired. Connect again."
        case .rateLimited: "Monzo asked Orbit to slow down; it will retry later."
        case .http(let code, let body): "Monzo error \(code): \(body.prefix(200))"
        }
    }

    static func from(_ error: Error) -> Error {
        guard let h = error as? HTTPError else { return error }
        switch h.status {
        case 401: return MonzoError.unauthorised
        case 403: return MonzoError.awaitingApproval
        case 429: return MonzoError.rateLimited
        default: return MonzoError.http(h.status, h.body)
        }
    }
}

// MARK: - JSON

public struct MonzoAccountJSON: Codable, Hashable, Sendable {
    public var id: String
    public var description: String?
    public var type: String?
    public var created: String?
    public var closed: Bool?
    public var currency: String?

    public var isFlex: Bool { (type ?? "").lowercased().contains("flex") }
    public var label: String {
        let t = (type ?? "").lowercased()
        if isFlex { return "Monzo Flex" }
        if t.contains("joint") { return "Monzo Joint" }
        if t.contains("retail") { return "Monzo" }
        return "Monzo (\(type ?? "account"))"
    }
}

public struct MonzoBalanceJSON: Codable, Hashable, Sendable {
    public var balance: Int
    public var total_balance: Int?
    public var currency: String?
    public var spend_today: Int?
}

public struct MonzoPotJSON: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var balance: Int
    public var currency: String?
    public var deleted: Bool?
}

public struct MonzoMerchantJSON: Codable, Hashable, Sendable {
    public var id: String?
    public var name: String?
    public var category: String?
    public var emoji: String?
    public var logo: String?
}

public struct MonzoTransactionJSON: Decodable, Hashable, Sendable {
    public var id: String
    public var created: String
    public var amount: Int
    public var currency: String?
    public var description: String?
    public var category: String?
    public var settled: String?
    public var decline_reason: String?
    public var is_load: Bool?
    public var notes: String?
    public var merchant: MonzoMerchantJSON?
    public var metadata: [String: String]?
    public var account_id: String?
    public var include_in_spending: Bool?
    public var counterparty: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id, created, amount, currency, description, category, settled, decline_reason, is_load, notes, merchant,
             metadata, account_id, include_in_spending, counterparty
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        created = try c.decode(String.self, forKey: .created)
        amount = try c.decode(Int.self, forKey: .amount)
        currency = try? c.decodeIfPresent(String.self, forKey: .currency)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        settled = try? c.decodeIfPresent(String.self, forKey: .settled)
        decline_reason = try? c.decodeIfPresent(String.self, forKey: .decline_reason)
        is_load = try? c.decodeIfPresent(Bool.self, forKey: .is_load)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        // Expanded merchant is an object; unexpanded it's an id string (or null).
        if let m = try? c.decodeIfPresent(MonzoMerchantJSON.self, forKey: .merchant) { merchant = m }
        else if let s = try? c.decodeIfPresent(String.self, forKey: .merchant) { merchant = MonzoMerchantJSON(id: s) }
        else { merchant = nil }
        // Metadata values are strings, but be lenient.
        if let meta = try? c.decodeIfPresent([String: JSONValue].self, forKey: .metadata) {
            metadata = meta.compactMapValues { $0.string }
        } else { metadata = nil }
        account_id = try? c.decodeIfPresent(String.self, forKey: .account_id)
        include_in_spending = try? c.decodeIfPresent(Bool.self, forKey: .include_in_spending)
        if let cp = try? c.decodeIfPresent([String: JSONValue].self, forKey: .counterparty) {
            counterparty = cp.compactMapValues { $0.string }
        } else { counterparty = nil }
    }

    /// Orbit's transaction. Pot moves, top-ups and transfers to the student's own accounts are internal.
    public func transaction(accountID: String, ownAccountIDs: Set<String> = []) -> MoneyTransaction {
        let date = ISO8601.parse(created) ?? Date(timeIntervalSince1970: 0)
        let desc = description ?? ""
        let potMove = metadata?["pot_id"] != nil || desc.hasPrefix("pot_") || (category == "savings" && metadata?["pot_account_id"] != nil)
        let ownTransfer = counterparty?["account_id"].map { ownAccountIDs.contains($0) } ?? false
        let name = merchant?.name ?? counterparty?["name"] ?? desc
        return MoneyTransaction(
            id: id, accountID: account_id ?? accountID, date: date, amountPence: amount, currency: currency ?? "GBP",
            name: name, descriptionText: desc, bankCategory: category, type: metadata?["trigger"] ?? (is_load == true ? "Top up" : nil),
            notes: (notes ?? "").isEmpty ? nil : notes, isPending: (settled ?? "").isEmpty && decline_reason == nil,
            isDeclined: decline_reason != nil, isInternal: potMove || ownTransfer || is_load == true || category == "mondo",
            source: .monzoAPI)
    }
}

// MARK: - Client

public struct MonzoAPI: Sendable {
    public static let base = URL(string: "https://api.monzo.com")!
    public var http: HTTPClient
    public var token: String

    public init(token: String, http: HTTPClient = HTTPClient(timeout: 30)) {
        self.token = token; self.http = http
    }

    var headers: [String: String] { ["Authorization": "Bearer \(token)"] }

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        var c = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        do {
            let data = try await http.data("GET", c.url!, headers: headers)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MonzoError.from(error)
        }
    }

    // Token exchange / refresh (form posts).
    struct TokenJSON: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
        let user_id: String?
    }

    public static func exchange(code: String, config: MonzoClientConfig, http: HTTPClient = HTTPClient(timeout: 30),
                                now: Date = Date()) async throws -> MonzoToken {
        try await token(fields: [("grant_type", "authorization_code"), ("client_id", config.clientID),
                                 ("client_secret", config.clientSecret), ("redirect_uri", config.redirectURI), ("code", code)],
                        http: http, now: now)
    }

    /// Refresh tokens are single-use: always store the new one returned.
    public static func refresh(_ refreshToken: String, config: MonzoClientConfig, http: HTTPClient = HTTPClient(timeout: 30),
                               now: Date = Date()) async throws -> MonzoToken {
        try await token(fields: [("grant_type", "refresh_token"), ("client_id", config.clientID),
                                 ("client_secret", config.clientSecret), ("refresh_token", refreshToken)],
                        http: http, now: now)
    }

    static func token(fields: [(String, String)], http: HTTPClient, now: Date) async throws -> MonzoToken {
        do {
            let t = try await http.form(TokenJSON.self, base.appendingPathComponent("oauth2/token"), fields: fields)
            return MonzoToken(accessToken: t.access_token, refreshToken: t.refresh_token,
                              expiresAt: t.expires_in.map { now.addingTimeInterval($0) }, userID: t.user_id)
        } catch {
            throw MonzoError.from(error)
        }
    }

    public struct WhoAmI: Decodable, Sendable {
        public let authenticated: Bool
        public let client_id: String?
        public let user_id: String?
    }

    public func whoami() async throws -> WhoAmI { try await get(WhoAmI.self, "ping/whoami") }

    struct AccountsJSON: Decodable { let accounts: [MonzoAccountJSON] }
    public func accounts() async throws -> [MonzoAccountJSON] {
        try await get(AccountsJSON.self, "accounts").accounts.filter { $0.closed != true }
    }

    public func balance(accountID: String) async throws -> MonzoBalanceJSON {
        try await get(MonzoBalanceJSON.self, "balance", query: [URLQueryItem(name: "account_id", value: accountID)])
    }

    struct PotsJSON: Decodable { let pots: [MonzoPotJSON] }
    public func pots(accountID: String) async throws -> [MonzoPotJSON] {
        try await get(PotsJSON.self, "pots", query: [URLQueryItem(name: "current_account_id", value: accountID)])
            .pots.filter { $0.deleted != true }
    }

    struct TransactionsJSON: Decodable { let transactions: [MonzoTransactionJSON] }
    /// One page (oldest first). `since` is an RFC 3339 time or a transaction id.
    public func transactions(accountID: String, since: String?, before: String? = nil, limit: Int = 100) async throws -> [MonzoTransactionJSON] {
        var q = [URLQueryItem(name: "account_id", value: accountID), URLQueryItem(name: "expand[]", value: "merchant"),
                 URLQueryItem(name: "limit", value: String(limit))]
        if let since { q.append(URLQueryItem(name: "since", value: since)) }
        if let before { q.append(URLQueryItem(name: "before", value: before)) }
        return try await get(TransactionsJSON.self, "transactions", query: q).transactions
    }

    /// Pages forward from `since` until a short page. Used right after approval (full
    /// history is only available for 5 minutes) and for incremental syncs (since = last id).
    public func allTransactions(accountID: String, since: String?, maxPages: Int = 200,
                                pause: @Sendable () async -> Void = {}) async throws -> [MonzoTransactionJSON] {
        var out: [MonzoTransactionJSON] = []
        var cursor = since
        for _ in 0..<maxPages {
            let page = try await transactions(accountID: accountID, since: cursor, limit: 100)
            out += page
            guard page.count == 100, let last = page.last?.id, last != cursor else { break }
            cursor = last
            await pause()
        }
        return out
    }

    /// Ends the session (read-only clients should still tidy up).
    public func logout() async {
        _ = try? await http.data("POST", Self.base.appendingPathComponent("oauth2/logout"), headers: headers)
    }

    /// RFC 3339 for `since`.
    public static func rfc3339(_ date: Date) -> String { ISO8601.string(date) }
}
