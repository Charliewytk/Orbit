import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Trading 212 public API (read-only). The student makes an API key in the
// Trading 212 app (Settings → API). Newer keys come with a secret and use HTTP
// Basic auth; older ones send the key alone in the Authorization header.

public struct Trading212Credentials: Codable, Hashable, Sendable {
    public var apiKey: String
    public var apiSecret: String?
    public var demo: Bool

    public init(apiKey: String, apiSecret: String? = nil, demo: Bool = false) {
        self.apiKey = apiKey; self.apiSecret = apiSecret; self.demo = demo
    }

    public var baseURL: URL {
        URL(string: demo ? "https://demo.trading212.com/api/v0/" : "https://live.trading212.com/api/v0/")!
    }

    public var authorization: String {
        if let secret = apiSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
            return "Basic " + Data("\(apiKey):\(secret)".utf8).base64EncodedString()
        }
        return apiKey
    }
}

public struct T212Cash: Codable, Hashable, Sendable {
    public var free: Double?
    public var total: Double?
    public var ppl: Double?
    public var result: Double?
    public var invested: Double?
    public var pieCash: Double?
    public var blocked: Double?
}

public struct T212AccountInfo: Codable, Hashable, Sendable {
    public var currencyCode: String?
    public var id: Int?
}

public struct T212Position: Codable, Hashable, Sendable, Identifiable {
    public var id: String { ticker }
    public var ticker: String
    public var quantity: Double
    public var averagePrice: Double?
    public var currentPrice: Double?
    /// Unrealised P/L in the account currency.
    public var ppl: Double?
    public var fxPpl: Double?
    public var initialFillDate: String?

    /// "AAPL_US_EQ" → "AAPL".
    public var symbol: String { ticker.split(separator: "_").first.map(String.init) ?? ticker }
}

public struct T212Order: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var ticker: String?
    public var type: String?
    public var status: String?
    public var dateCreated: String?
    public var dateExecuted: String?
    public var filledQuantity: Double?
    public var filledValue: Double?
    public var fillPrice: Double?
    public var orderedQuantity: Double?
    public var orderedValue: Double?
}

public struct T212Transaction: Codable, Hashable, Sendable {
    public var amount: Double?
    public var dateTime: String?
    public var reference: String?
    public var type: String?
}

struct T212Page<T: Decodable & Sendable>: Decodable, Sendable {
    let items: [T]
    let nextPagePath: String?
}

/// What Orbit shows on the Investments screen.
public struct InvestmentSnapshot: Codable, Hashable, Sendable {
    public var fetchedAt: Date
    public var currency: String
    public var cash: T212Cash
    public var positions: [T212Position]
    public var orders: [T212Order]
    public var transactions: [T212Transaction]

    public init(fetchedAt: Date, currency: String, cash: T212Cash, positions: [T212Position] = [], orders: [T212Order] = [],
                transactions: [T212Transaction] = []) {
        self.fetchedAt = fetchedAt; self.currency = currency; self.cash = cash; self.positions = positions
        self.orders = orders; self.transactions = transactions
    }

    public var totalPence: Int { MoneyFormat.pence(cash.total ?? 0) }
    public var investedPence: Int { MoneyFormat.pence(cash.invested ?? 0) }
    public var freeCashPence: Int { MoneyFormat.pence(cash.free ?? 0) }
    /// Unrealised profit/loss on open positions.
    public var unrealisedPence: Int { MoneyFormat.pence(cash.ppl ?? positions.reduce(0) { $0 + ($1.ppl ?? 0) }) }
    /// Realised result so far.
    public var realisedPence: Int { MoneyFormat.pence(cash.result ?? 0) }

    /// Net deposits (deposits − withdrawals) from the transaction history.
    public var netDepositsPence: Int {
        MoneyFormat.pence(transactions.reduce(0) { sum, t in
            let type = (t.type ?? "").uppercased()
            if type.contains("DEPOSIT") { return sum + abs(t.amount ?? 0) }
            if type.contains("WITHDRAW") { return sum - abs(t.amount ?? 0) }
            return sum
        })
    }
}

public enum Trading212Error: Error, CustomStringConvertible, Sendable {
    case badKey
    case rateLimited
    case http(Int, String)

    public var description: String {
        switch self {
        case .badKey: "Trading 212 didn't accept the API key. Make a new one in Trading 212 → Settings → API (read-only is enough)."
        case .rateLimited: "Trading 212 rate limit reached; Orbit will try again shortly."
        case .http(let c, let b): "Trading 212 error \(c): \(b.prefix(200))"
        }
    }
}

/// Keeps requests under Trading 212's per-endpoint limits by spacing them out.
public actor RateLimiter {
    private var last: [String: Date] = [:]
    private let intervals: [String: TimeInterval]
    private let defaultInterval: TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(intervals: [String: TimeInterval], defaultInterval: TimeInterval = 2,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }) {
        self.intervals = intervals; self.defaultInterval = defaultInterval; self.sleep = sleep
    }

    /// Seconds to wait before calling `key` at `now` (0 if free), and books the slot.
    public func reserve(_ key: String, now: Date = Date()) -> TimeInterval {
        let gap = intervals[key] ?? defaultInterval
        let earliest = (last[key] ?? .distantPast).addingTimeInterval(gap)
        let wait = max(0, earliest.timeIntervalSince(now))
        last[key] = now.addingTimeInterval(wait)
        return wait
    }

    public func wait(_ key: String) async {
        let w = reserve(key)
        if w > 0 { await sleep(w) }
    }
}

public struct Trading212Client: Sendable {
    public var credentials: Trading212Credentials
    public var http: HTTPClient
    public var limiter: RateLimiter

    /// Documented limits: cash 1/2s, portfolio 1/5s, account info 1/30s, order and transaction history 6/min.
    public static func defaultLimiter() -> RateLimiter {
        RateLimiter(intervals: ["equity/account/cash": 2, "equity/portfolio": 5, "equity/account/info": 30,
                                "equity/history/orders": 10, "history/transactions": 10])
    }

    public init(credentials: Trading212Credentials, http: HTTPClient = HTTPClient(timeout: 30),
                limiter: RateLimiter = Trading212Client.defaultLimiter()) {
        self.credentials = credentials; self.http = http; self.limiter = limiter
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: String? = nil) async throws -> T {
        await limiter.wait(path)
        var s = credentials.baseURL.absoluteString + path
        if let query, !query.isEmpty { s += "?" + query }
        guard let url = URL(string: s) else { throw Trading212Error.http(0, "Bad URL") }
        do {
            let data = try await http.data("GET", url, headers: ["Authorization": credentials.authorization, "Accept": "application/json"])
            return try JSONDecoder().decode(T.self, from: data)
        } catch let e as HTTPError {
            switch e.status {
            case 401, 403: throw Trading212Error.badKey
            case 429: throw Trading212Error.rateLimited
            default: throw Trading212Error.http(e.status, e.body)
            }
        }
    }

    public func cash() async throws -> T212Cash { try await get(T212Cash.self, "equity/account/cash") }
    public func info() async throws -> T212AccountInfo { try await get(T212AccountInfo.self, "equity/account/info") }
    public func portfolio() async throws -> [T212Position] { try await get([T212Position].self, "equity/portfolio") }

    /// Follows `nextPagePath` (it carries the cursor) up to `maxPages`.
    func paged<T: Decodable & Sendable>(_ type: T.Type, _ path: String, maxPages: Int) async throws -> [T] {
        var out: [T] = []
        var query: String? = "limit=50"
        for _ in 0..<maxPages {
            let page = try await get(T212Page<T>.self, path, query: query)
            out += page.items
            guard let next = page.nextPagePath, let q = next.split(separator: "?", maxSplits: 1).last, next.contains("?") else { break }
            query = String(q)
        }
        return out
    }

    public func orders(maxPages: Int = 2) async throws -> [T212Order] { try await paged(T212Order.self, "equity/history/orders", maxPages: maxPages) }
    public func transactions(maxPages: Int = 2) async throws -> [T212Transaction] {
        try await paged(T212Transaction.self, "history/transactions", maxPages: maxPages)
    }

    /// Everything for the Investments screen (history is best-effort).
    public func snapshot(now: Date = Date(), includeHistory: Bool = true) async throws -> InvestmentSnapshot {
        let cash = try await cash()
        let positions = try await portfolio()
        let currency = (try? await info())?.currencyCode ?? "GBP"
        var orders: [T212Order] = [], txs: [T212Transaction] = []
        if includeHistory {
            orders = (try? await self.orders(maxPages: 1)) ?? []
            txs = (try? await transactions(maxPages: 2)) ?? []
        }
        return InvestmentSnapshot(fetchedAt: now, currency: currency, cash: cash,
                                  positions: positions.sorted { abs($0.ppl ?? 0) > abs($1.ppl ?? 0) }, orders: orders, transactions: txs)
    }
}
