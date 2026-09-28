import Foundation

public struct BudgetStatus: Codable, Hashable, Sendable, Identifiable {
    public var id: String { category.rawValue }
    public var category: SpendingCategory
    public var limitPence: Int
    public var spentPence: Int
    public var remainingPence: Int { limitPence - spentPence }
    public var fractionUsed: Double { limitPence > 0 ? Double(spentPence) / Double(limitPence) : 0 }
    /// Spend by month end at the current pace.
    public var projectedPence: Int
    public var isOver: Bool { spentPence > limitPence }
    /// Spending faster than the month is passing (by more than 10%).
    public var aheadOfPace: Bool
}

public struct CategoryTotal: Codable, Hashable, Sendable, Identifiable {
    public var id: String { category.rawValue }
    public var category: SpendingCategory
    public var pence: Int
}

public struct WeeklySpend: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date
    public var totalPence: Int
    public var previousWeekPence: Int
    public var byCategory: [CategoryTotal]
    public var topMerchants: [MerchantTotal]

    public struct MerchantTotal: Codable, Hashable, Sendable { public var name: String; public var pence: Int }

    public var summary: String {
        let change = totalPence - previousWeekPence
        var s = "Spent \(MoneyFormat.pounds(totalPence)) this week"
        if previousWeekPence > 0 {
            s += change == 0 ? " (same as last week)" : " (\(MoneyFormat.pounds(abs(change))) \(change > 0 ? "more" : "less") than last week)"
        }
        if let top = byCategory.first { s += ". Most on \(top.category.label.lowercased()): \(MoneyFormat.pounds(top.pence))" }
        return s + "."
    }
}

public struct SafeToSpend: Codable, Hashable, Sendable {
    public var spendablePence: Int
    public var committedPence: Int
    public var bufferPence: Int
    public var availablePence: Int { max(0, spendablePence - committedPence - bufferPence) }
    public var days: Int
    public var perDayPence: Int { days > 0 ? availablePence / days : availablePence }
    public var nextIncome: IncomeEvent?
    public var commitments: [Subscription]
}

public struct Subscription: Codable, Hashable, Sendable, Identifiable {
    public enum Cadence: String, Codable, Sendable {
        case weekly, monthly, yearly
        public var days: Double { switch self { case .weekly: 7; case .monthly: 30.44; case .yearly: 365.25 } }
    }
    public var id: String { merchantKey }
    public var merchantKey: String
    public var name: String
    public var amountPence: Int
    public var cadence: Cadence
    public var lastDate: Date
    public var nextExpected: Date
    public var occurrences: Int

    public var monthlyPence: Int { Int((Double(amountPence) * 30.44 / cadence.days).rounded()) }
}

public struct NetWorth: Codable, Hashable, Sendable {
    public var cashPence: Int
    public var potsPence: Int
    public var investmentsPence: Int
    public var liabilitiesPence: Int
    public var totalPence: Int { cashPence + potsPence + investmentsPence - liabilitiesPence }
}

public enum MoneyMath {
    /// Spending (positive pence) per category for transactions in [from, to).
    /// Refunds in a spending category reduce it; internal moves, income and declined payments are ignored.
    public static func spending(_ txs: [MoneyTransaction], categoriser: Categoriser, from: Date, to: Date) -> [SpendingCategory: Int] {
        var out: [SpendingCategory: Int] = [:]
        for tx in txs where tx.date >= from && tx.date < to && !tx.isDeclined && !tx.isInternal {
            let (cat, _) = categoriser.categorise(tx)
            guard cat.isSpending else { continue }
            out[cat, default: 0] -= tx.amountPence
        }
        return out.filter { $0.value != 0 }
    }

    public static func monthBounds(_ date: Date, timeZone: TimeZone) -> (start: Date, end: Date, daysInMonth: Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.date(from: cal.dateComponents([.year, .month], from: date))!
        let end = cal.date(byAdding: .month, value: 1, to: start)!
        let days = cal.range(of: .day, in: .month, for: start)?.count ?? 30
        return (start, end, days)
    }

    public static func sorted(_ totals: [SpendingCategory: Int]) -> [CategoryTotal] {
        totals.map { CategoryTotal(category: $0.key, pence: $0.value) }
            .sorted { $0.pence != $1.pence ? $0.pence > $1.pence : $0.category < $1.category }
    }

    public static func budgets(_ budgets: [Budget], spending: [SpendingCategory: Int], now: Date,
                               timeZone: TimeZone) -> [BudgetStatus] {
        let (start, _, days) = monthBounds(now, timeZone: timeZone)
        let elapsedDays = max(1, now.timeIntervalSince(start) / 86400)
        let fractionOfMonth = min(1, elapsedDays / Double(days))
        return budgets.filter { $0.monthlyLimitPence > 0 }.map { b in
            let spent = max(0, spending[b.category] ?? 0)
            let projected = Int((Double(spent) / elapsedDays * Double(days)).rounded())
            let used = Double(spent) / Double(b.monthlyLimitPence)
            return BudgetStatus(category: b.category, limitPence: b.monthlyLimitPence, spentPence: spent,
                                projectedPence: projected, aheadOfPace: used > fractionOfMonth + 0.1)
        }.sorted { $0.fractionUsed > $1.fractionUsed }
    }

    public static func weekly(_ txs: [MoneyTransaction], categoriser: Categoriser, now: Date) -> WeeklySpend {
        let end = now, start = now.addingTimeInterval(-7 * 86400), prevStart = start.addingTimeInterval(-7 * 86400)
        let this = spending(txs, categoriser: categoriser, from: start, to: end)
        let prev = spending(txs, categoriser: categoriser, from: prevStart, to: start)
        var merchants: [String: (String, Int)] = [:]
        for tx in txs where tx.date >= start && tx.date < end && tx.isDebit && !tx.isDeclined && !tx.isInternal
            && categoriser.categorise(tx).category.isSpending {
            let key = tx.merchantKey
            let prior = merchants[key] ?? (tx.name, 0)
            merchants[key] = (prior.0, prior.1 - tx.amountPence)
        }
        let top = merchants.values.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(5)
            .map { WeeklySpend.MerchantTotal(name: $0.0, pence: $0.1) }
        return WeeklySpend(start: start, end: end, totalPence: this.values.reduce(0, +), previousWeekPence: prev.values.reduce(0, +),
                           byCategory: sorted(this), topMerchants: Array(top))
    }

    /// Recurring payments: the same merchant charged at a steady interval (weekly,
    /// monthly or yearly, ±20%) with a steady amount (within 15% of the median).
    /// Two charges are enough for monthly/yearly; weekly needs three.
    public static func subscriptions(_ txs: [MoneyTransaction], now: Date) -> [Subscription] {
        let debits = txs.filter { $0.isDebit && !$0.isDeclined && !$0.isInternal && !$0.isPending }
        let groups = Dictionary(grouping: debits, by: \.merchantKey)
        var out: [Subscription] = []
        for (key, list) in groups where !key.isEmpty && list.count >= 2 {
            let sorted = list.sorted { $0.date < $1.date }
            let amounts = sorted.map { -$0.amountPence }.sorted()
            let median = amounts[amounts.count / 2]
            let steady = sorted.filter { abs(-$0.amountPence - median) <= max(50, median * 15 / 100) }
            guard steady.count >= 2 else { continue }
            let gaps = zip(steady.dropFirst(), steady).map { $0.date.timeIntervalSince($1.date) / 86400 }
            let avg = gaps.reduce(0, +) / Double(gaps.count)
            guard gaps.allSatisfy({ abs($0 - avg) <= max(3, avg * 0.2) }) else { continue }
            let cadence: Subscription.Cadence
            if abs(avg - 7) <= 1.5, steady.count >= 3 { cadence = .weekly }
            else if avg >= 26 && avg <= 35 { cadence = .monthly }
            else if avg >= 350 && avg <= 380 { cadence = .yearly }
            else { continue }
            let last = steady.last!
            // Stale: missed two cycles.
            guard now.timeIntervalSince(last.date) < cadence.days * 2 * 86400 else { continue }
            var next = last.date.addingTimeInterval(cadence.days * 86400)
            while next < now { next = next.addingTimeInterval(cadence.days * 86400) }
            out.append(Subscription(merchantKey: key, name: last.name.isEmpty ? key : last.name, amountPence: median,
                                    cadence: cadence, lastDate: last.date, nextExpected: next, occurrences: steady.count))
        }
        return out.sorted { $0.monthlyPence != $1.monthlyPence ? $0.monthlyPence > $1.monthlyPence : $0.merchantKey < $1.merchantKey }
    }

    /// Spendable money until the next income, after subscriptions due before then and a buffer.
    public static func safeToSpend(accounts: [MoneyAccount], income: [IncomeEvent], subscriptions: [Subscription],
                                   bufferPence: Int, now: Date, timeZone: TimeZone) -> SafeToSpend {
        let spendable = accounts.filter { $0.countsAsSpendable && !$0.isLiability }.reduce(0) { $0 + $1.balancePence }
        let next = income.filter { $0.date > now }.min { $0.date < $1.date }
        let cal = DayCalendar(timeZone: timeZone)
        let horizon = next?.date ?? MoneyMath.monthBounds(now, timeZone: timeZone).end
        let days = max(1, cal.days(from: now, to: horizon))
        let due = subscriptions.filter { $0.nextExpected > now && $0.nextExpected < horizon }
        return SafeToSpend(spendablePence: spendable, committedPence: due.reduce(0) { $0 + $1.amountPence },
                           bufferPence: bufferPence, days: days, nextIncome: next, commitments: due)
    }

    /// Net worth: current accounts, cash and pots, plus investments, minus money owed (Flex, cards, loans).
    public static func netWorth(accounts: [MoneyAccount], investmentsPence: Int?) -> NetWorth {
        var cash = 0, pots = 0, investments = investmentsPence ?? 0, owed = 0
        for a in accounts {
            if a.isLiability { owed += abs(a.balancePence); continue }
            switch a.kind {
            case .pot, .savings: pots += a.balancePence
            case .investment: if investmentsPence == nil || a.source != .trading212 { investments += a.balancePence }
            default: cash += a.balancePence
            }
        }
        return NetWorth(cashPence: cash, potsPence: pots, investmentsPence: investments, liabilitiesPence: owed)
    }
}

/// Merging imports without duplicates.
public enum TransactionLedger {
    /// Upserts by id. Returns the merged list (newest first) and how many were new.
    public static func merge(_ existing: [MoneyTransaction], with incoming: [MoneyTransaction]) -> (all: [MoneyTransaction], added: Int) {
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var added = 0
        for tx in incoming {
            if byID[tx.id] == nil { added += 1 }
            // API data (richer) wins over CSV; otherwise the newer import wins.
            if let old = byID[tx.id], old.source == .monzoAPI, tx.source != .monzoAPI { continue }
            byID[tx.id] = tx
        }
        let all = byID.values.sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
        return (all, added)
    }
}
