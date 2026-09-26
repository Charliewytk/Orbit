import Foundation

/// Informational money view (parents pay; no loan): weekly and term spending, categories,
/// and gentle notes when something looks unusual. Never restrictive.
public struct MoneyOverview: Codable, Hashable, Sendable {
    public struct Week: Codable, Hashable, Sendable, Identifiable {
        public var id: Date { start }
        public var start: Date
        public var pence: Int
    }

    public struct Alert: Codable, Hashable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable { case categorySpike, largePayment, newMerchantLarge }
        public var id: String
        public var kind: Kind
        public var message: String
        public var pence: Int
    }

    public var weeks: [Week]
    public var thisWeekPence: Int
    public var typicalWeekPence: Int
    public var termLabel: String
    public var termStart: Date
    public var termPence: Int
    public var termByCategory: [CategoryTotal]
    public var weekByCategory: [CategoryTotal]
    public var alerts: [Alert]
}

public enum MoneyInsights {
    /// Exeter-style terms: Autumn (mid-Sep–mid-Dec), Spring (Jan–Mar), Summer (Apr–Jun); otherwise "Summer break".
    public static func term(containing date: Date, calendar: DayCalendar) -> (label: String, start: Date) {
        let y = Int(calendar.format(date, "yyyy"))!, m = Int(calendar.format(date, "M"))!
        switch m {
        case 9...12: return ("Autumn term", calendar.date(year: y, month: 9, day: 15)!)
        case 1...3: return ("Spring term", calendar.date(year: y, month: 1, day: 1)!)
        case 4...6: return ("Summer term", calendar.date(year: y, month: 4, day: 1)!)
        default: return ("Summer break", calendar.date(year: y, month: 7, day: 1)!)
        }
    }

    public static func overview(_ txs: [MoneyTransaction], categoriser: Categoriser, now: Date,
                                calendar: DayCalendar, weeksBack: Int = 8) -> MoneyOverview {
        let thisWeek = calendar.startOfWeek(now)
        var weeks: [MoneyOverview.Week] = []
        var weeklyByCat: [[SpendingCategory: Int]] = []
        for i in stride(from: weeksBack - 1, through: 0, by: -1) {
            let s = calendar.addingDays(-7 * i, to: thisWeek)
            let e = calendar.addingDays(7, to: s)
            let spend = MoneyMath.spending(txs, categoriser: categoriser, from: s, to: min(e, now.addingTimeInterval(1)))
            weeks.append(.init(start: s, pence: max(0, spend.values.reduce(0, +))))
            weeklyByCat.append(spend)
        }
        let past = weeks.dropLast().map(\.pence).filter { $0 > 0 }.sorted()
        let typical = past.isEmpty ? 0 : past[past.count / 2]
        let (label, termStart) = term(containing: now, calendar: calendar)
        let termSpend = MoneyMath.spending(txs, categoriser: categoriser, from: termStart, to: now.addingTimeInterval(1))
        let current = weeklyByCat.last ?? [:]

        var alerts: [MoneyOverview.Alert] = []
        // Category spike: this week > 2× the median of previous weeks and at least £20 over.
        for (cat, pence) in current where pence > 0 {
            let history = weeklyByCat.dropLast().map { $0[cat] ?? 0 }.sorted()
            let median = history.isEmpty ? 0 : history[history.count / 2]
            if history.filter({ $0 > 0 }).count >= 2, pence > median * 2, pence - median >= 2000 {
                alerts.append(.init(id: "spike|\(cat.rawValue)", kind: .categorySpike,
                                    message: "\(cat.label) is higher than usual this week (\(pounds(pence)) vs about \(pounds(median))). Just so you know.",
                                    pence: pence))
            }
        }
        // Large single payments vs that merchant's usual, or a big first-time payment.
        let recent = txs.filter { $0.isDebit && !$0.isDeclined && !$0.isInternal && $0.date >= calendar.addingDays(-7, to: now) && $0.date <= now
            && categoriser.categorise($0).category.isSpending }
        for tx in recent {
            let amount = -tx.amountPence
            let prior = txs.filter { $0.merchantKey == tx.merchantKey && $0.isDebit && $0.date < tx.date }.map { -$0.amountPence }.sorted()
            if prior.isEmpty {
                if amount >= 7500 {
                    alerts.append(.init(id: "new|\(tx.id)", kind: .newMerchantLarge,
                                        message: "First payment to \(tx.name) was \(pounds(amount)).", pence: amount))
                }
            } else {
                let median = prior[prior.count / 2]
                if amount >= 3000 && amount > median * 3 {
                    alerts.append(.init(id: "large|\(tx.id)", kind: .largePayment,
                                        message: "\(tx.name): \(pounds(amount)), more than you usually spend there (about \(pounds(median))).",
                                        pence: amount))
                }
            }
        }
        alerts.sort { $0.pence > $1.pence }
        return MoneyOverview(weeks: weeks, thisWeekPence: weeks.last?.pence ?? 0, typicalWeekPence: typical,
                             termLabel: label, termStart: termStart, termPence: max(0, termSpend.values.reduce(0, +)),
                             termByCategory: MoneyMath.sorted(termSpend), weekByCategory: MoneyMath.sorted(current),
                             alerts: Array(alerts.prefix(5)))
    }

    public static func pounds(_ pence: Int) -> String {
        let p = abs(pence)
        return (pence < 0 ? "-" : "") + "£\(p / 100)" + (p % 100 == 0 ? "" : String(format: ".%02d", p % 100))
    }
}
