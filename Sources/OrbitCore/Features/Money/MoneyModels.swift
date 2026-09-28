import Foundation

// Money is kept on the Mac only (Application Support), never synced to iCloud,
// and only ever sent to the local AI (`.privateData`). Amounts are integer
// pence (minor units) to avoid rounding errors.

public enum SpendingCategory: String, Codable, CaseIterable, Sendable, Identifiable, Comparable {
    case groceries, eatingOut, takeaway, goingOut, transport, subscriptions, bills, rent, shopping, entertainment,
         personalCare, education, holidays, gifts, charity, cash, general
    // Not spending:
    case transfers, savings, income

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .groceries: "Groceries"
        case .eatingOut: "Eating out"
        case .takeaway: "Takeaway"
        case .goingOut: "Going out"
        case .transport: "Transport"
        case .subscriptions: "Subscriptions"
        case .bills: "Bills"
        case .rent: "Rent"
        case .shopping: "Shopping"
        case .entertainment: "Entertainment"
        case .personalCare: "Personal care"
        case .education: "Uni & books"
        case .holidays: "Holidays"
        case .gifts: "Gifts"
        case .charity: "Charity"
        case .cash: "Cash"
        case .general: "General"
        case .transfers: "Transfers"
        case .savings: "Savings"
        case .income: "Income"
        }
    }

    public var symbol: String {
        switch self {
        case .groceries: "cart"
        case .eatingOut: "fork.knife"
        case .takeaway: "takeoutbag.and.cup.and.straw"
        case .goingOut: "music.note"
        case .transport: "tram"
        case .subscriptions: "repeat"
        case .bills: "doc.plaintext"
        case .rent: "house"
        case .shopping: "bag"
        case .entertainment: "ticket"
        case .personalCare: "heart"
        case .education: "book"
        case .holidays: "airplane"
        case .gifts: "gift"
        case .charity: "hands.sparkles"
        case .cash: "banknote"
        case .general: "circle.grid.2x2"
        case .transfers: "arrow.left.arrow.right"
        case .savings: "building.columns"
        case .income: "arrow.down.circle"
        }
    }

    /// Counts towards spending totals and budgets.
    public var isSpending: Bool { ![.transfers, .savings, .income].contains(self) }

    public static var spendingCases: [SpendingCategory] { allCases.filter(\.isSpending) }

    public static func < (a: SpendingCategory, b: SpendingCategory) -> Bool {
        (allCases.firstIndex(of: a) ?? 0) < (allCases.firstIndex(of: b) ?? 0)
    }

    /// Monzo's own category names (API values like "eating_out" or CSV labels like "Eating out").
    public init?(monzo raw: String?) {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        switch key {
        case "groceries": self = .groceries
        case "eating_out": self = .eatingOut
        case "transport": self = .transport
        case "bills": self = .bills
        case "entertainment": self = .entertainment
        case "shopping": self = .shopping
        case "personal_care": self = .personalCare
        case "holidays": self = .holidays
        case "gifts": self = .gifts
        case "charity": self = .charity
        case "cash": self = .cash
        case "savings": self = .savings
        case "transfers", "mondo", "topup", "top_up": self = .transfers
        case "income": self = .income
        case "finances": self = .bills
        case "expenses", "family": self = .general
        case "general", "": return nil // too vague: let the rules decide
        default:
            if let c = SpendingCategory(rawValue: raw) { self = c } else { return nil }
        }
    }
}

public enum MoneySource: String, Codable, Sendable { case monzoAPI, monzoCSV, csv, manual, trading212 }

public struct MoneyTransaction: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var accountID: String
    public var date: Date
    /// Negative = money out.
    public var amountPence: Int
    public var currency: String
    /// Merchant or counterparty name as shown by the bank.
    public var name: String
    public var descriptionText: String
    /// The bank's own category label, if any.
    public var bankCategory: String?
    /// "Card payment", "Pot transfer", "Direct Debit"… (CSV) or API scheme.
    public var type: String?
    public var notes: String?
    public var isPending: Bool
    public var isDeclined: Bool
    /// Pot moves and transfers between the student's own accounts.
    public var isInternal: Bool
    public var source: MoneySource

    public init(id: String, accountID: String, date: Date, amountPence: Int, currency: String = "GBP", name: String,
                descriptionText: String = "", bankCategory: String? = nil, type: String? = nil, notes: String? = nil,
                isPending: Bool = false, isDeclined: Bool = false, isInternal: Bool = false, source: MoneySource) {
        self.id = id; self.accountID = accountID; self.date = date; self.amountPence = amountPence; self.currency = currency
        self.name = name; self.descriptionText = descriptionText; self.bankCategory = bankCategory; self.type = type
        self.notes = notes; self.isPending = isPending; self.isDeclined = isDeclined; self.isInternal = isInternal
        self.source = source
    }

    public var merchantKey: String { MerchantKey.make(name.isEmpty ? descriptionText : name) }
    public var isDebit: Bool { amountPence < 0 }
}

public enum MerchantKey {
    /// Words that say nothing about the merchant: places, company suffixes and bank
    /// statement boilerplate ("CARD PAYMENT TO …", "POS …").
    static let noise: Set<String> = ["gbr", "gb", "uk", "ltd", "limited", "plc", "www", "com", "co", "the", "exeter", "london",
                                     "card", "payment", "payments", "to", "at", "purchase", "pos", "contactless", "visa",
                                     "debit", "dd", "fpo", "fpi", "bgc", "so", "tfr", "via", "ref", "on", "clearpay", "sumup",
                                     "zettle", "izettle", "sq", "paypal", "pp"]

    /// "TESCO STORES 3456 EXETER GBR" → "tesco stores". Lower-case words,
    /// store numbers and trailing location noise dropped, at most three words.
    public static func make(_ raw: String) -> String {
        let cleaned = raw.lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
        let words = cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: ".")))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { w in !w.isEmpty && !w.allSatisfy { $0.isNumber } && w.filter(\.isNumber).count < 3 }
            .filter { !noise.contains($0) }
        return words.prefix(3).joined(separator: " ")
    }
}

public enum AccountKind: String, Codable, CaseIterable, Sendable {
    case current, joint, pot, savings, cash, flex, creditCard, loan, investment, other

    public var label: String {
        switch self {
        case .current: "Current account"
        case .joint: "Joint account"
        case .pot: "Pot"
        case .savings: "Savings"
        case .cash: "Cash"
        case .flex: "Monzo Flex (owed)"
        case .creditCard: "Credit card (owed)"
        case .loan: "Loan (owed)"
        case .investment: "Investments"
        case .other: "Other"
        }
    }

    /// Money owed rather than held.
    public var isLiability: Bool { [.flex, .creditCard, .loan].contains(self) }
}

public struct MoneyAccount: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: AccountKind
    /// Held money, or for liabilities the amount owed (positive).
    public var balancePence: Int
    public var currency: String
    public var updatedAt: Date
    public var source: MoneySource
    /// Spendable money for "safe to spend" (current accounts by default; not pots).
    public var countsAsSpendable: Bool

    public init(id: String, name: String, kind: AccountKind, balancePence: Int, currency: String = "GBP",
                updatedAt: Date = Date(), source: MoneySource = .manual, countsAsSpendable: Bool? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.balancePence = balancePence; self.currency = currency
        self.updatedAt = updatedAt; self.source = source
        self.countsAsSpendable = countsAsSpendable ?? [.current, .joint, .cash].contains(kind)
    }

    public var isLiability: Bool { kind.isLiability }
}

/// A date money comes in (student loan instalment, payday).
public struct IncomeEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var date: Date
    public var amountPence: Int?

    public init(id: String = UUID().uuidString, label: String, date: Date, amountPence: Int? = nil) {
        self.id = id; self.label = label; self.date = date; self.amountPence = amountPence
    }
}

public struct Budget: Codable, Hashable, Sendable, Identifiable {
    public var id: String { category.rawValue }
    public var category: SpendingCategory
    public var monthlyLimitPence: Int
    public init(category: SpendingCategory, monthlyLimitPence: Int) {
        self.category = category; self.monthlyLimitPence = monthlyLimitPence
    }
}

public enum MoneyFormat {
    /// "£1,234.56", "−£12.00".
    public static func pounds(_ pence: Int, currency: String = "GBP", showPlus: Bool = false) -> String {
        let symbol: String
        switch currency.uppercased() {
        case "GBP": symbol = "£"
        case "EUR": symbol = "€"
        case "USD": symbol = "$"
        default: symbol = currency.uppercased() + " "
        }
        let neg = pence < 0
        let abs = Swift.abs(pence)
        let whole = abs / 100, frac = abs % 100
        var digits = String(whole)
        var grouped = ""
        while digits.count > 3 {
            grouped = "," + digits.suffix(3) + grouped
            digits = String(digits.dropLast(3))
        }
        grouped = digits + grouped
        let sign = neg ? "−" : (showPlus && pence > 0 ? "+" : "")
        return "\(sign)\(symbol)\(grouped).\(String(format: "%02d", frac))"
    }

    /// "12.50", "-3", "£1,234.56", "(4.20)" → pence.
    public static func parsePence(_ raw: String) -> Int? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") { negative = true; s = String(s.dropFirst().dropLast()) }
        s = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "£", with: "")
            .replacingOccurrences(of: "€", with: "").replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "GBP", with: "").replacingOccurrences(of: "−", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("-") { negative.toggle(); s.removeFirst() }
        if s.hasPrefix("+") { s.removeFirst() }
        guard let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var value = d * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        let pence = NSDecimalNumber(decimal: rounded).intValue
        return negative ? -pence : pence
    }

    public static func pence(_ amount: Double) -> Int { Int((amount * 100).rounded()) }
}
