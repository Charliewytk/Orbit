import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OrbitCore

/// Money: overview, transactions, budgets and investments. Local only.
struct MoneyView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", spending = "Spending", transactions = "Transactions", budgets = "Budgets", investments = "Investments"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .overview
    @State private var showSettings = false
    private var money: MoneyService { FeatureHub.shared.money }

    var body: some View {
        Group {
            if !money.hasAnyData {
                ContentUnavailableView {
                    Label("No money data yet", systemImage: "sterlingsign.circle")
                } description: {
                    Text("Connect Monzo, import a statement CSV, add accounts by hand, or add a Trading 212 key. Everything stays on this Mac.")
                } actions: {
                    Button("Set up money…") { showSettings = true }
                }
            } else {
                switch tab {
                case .overview: MoneyOverviewView()
                case .spending: SpendingInsightsView()
                case .transactions: TransactionsView()
                case .budgets: BudgetsView()
                case .investments: InvestmentsView()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            if money.hasAnyData {
                GlassSegmented(options: Tab.allCases.map { ($0, $0.rawValue) }, selection: $tab)
                    .padding(.vertical, Theme.Space.m)
            }
        }
        .orbitBackground()
        .toolbar {
            Button { showSettings = true } label: { Label("Money settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                MoneySettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
            }
            .frame(minWidth: 620, minHeight: 640)
        }
        .navigationTitle("Money")
    }
}

/// A plain horizontal bar list (spending by category).
struct AmountBarRow: View {
    let label: String
    let symbol: String
    let pence: Int
    let maxPence: Int
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(label, systemImage: symbol)
                Spacer()
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
                Text(MoneyFormat.pounds(pence)).monospacedDigit()
            }
            GeometryReader { geo in
                Capsule().fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule().fill(.tint)
                            .frame(width: geo.size.width * CGFloat(min(1, max(0, Double(pence) / Double(max(1, maxPence))))))
                    }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 2)
    }
}

struct MoneyOverviewView: View {
    private var money: MoneyService { FeatureHub.shared.money }

    var body: some View {
        let now = Date()
        let nw = money.netWorth()
        let safe = money.safeToSpend(now: now)
        let month = money.monthSpending(now: now)
        let week = money.weekly(now: now)
        let subs = money.subscriptions(now: now)
        let cal = DayCalendar(timeZone: money.timeZone)

        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Net worth").foregroundStyle(.secondary)
                    Text(MoneyFormat.pounds(nw.totalPence)).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    Text("Cash \(MoneyFormat.pounds(nw.cashPence)) · Pots \(MoneyFormat.pounds(nw.potsPence)) · Investments \(MoneyFormat.pounds(nw.investmentsPence)) · Owed \(MoneyFormat.pounds(nw.liabilitiesPence))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section("Safe to spend") {
                HStack(alignment: .firstTextBaseline) {
                    Text(MoneyFormat.pounds(safe.availablePence)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    Text("· \(MoneyFormat.pounds(safe.perDayPence)) a day for \(safe.days) day\(safe.days == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
                Text("Until \(safe.nextIncome.map { "\($0.label), \(cal.shortDay($0.date))" } ?? "the end of the month (add top-up dates in settings)"). After \(MoneyFormat.pounds(safe.committedPence)) of subscriptions due and a \(MoneyFormat.pounds(safe.bufferPence)) buffer.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("This month") {
                if month.isEmpty { Text("No spending yet this month.").foregroundStyle(.secondary) }
                ForEach(month) { t in
                    AmountBarRow(label: t.category.label, symbol: t.category.symbol, pence: t.pence, maxPence: month.first?.pence ?? 1)
                }
            }
            Section("Last 7 days") {
                Text(week.summary)
                ForEach(week.topMerchants, id: \.name) { m in
                    HStack { Text(m.name); Spacer(); Text(MoneyFormat.pounds(m.pence)).monospacedDigit().foregroundStyle(.secondary) }
                }
            }
            if !subs.isEmpty {
                Section("Subscriptions · \(MoneyFormat.pounds(subs.reduce(0) { $0 + $1.monthlyPence })) a month") {
                    ForEach(subs) { s in
                        HStack {
                            Text(s.name)
                            Spacer()
                            Text("\(MoneyFormat.pounds(s.amountPence)) \(s.cadence.rawValue) · next \(cal.shortDay(s.nextExpected))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Accounts") {
                ForEach(money.data.accounts) { a in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(a.name)
                            Text("\(a.kind.label) · updated \(cal.shortDay(a.updatedAt))").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text((a.isLiability ? "−" : "") + MoneyFormat.pounds(abs(a.balancePence), currency: a.currency)).monospacedDigit()
                    }
                }
                if money.data.flexNotAvailable && !money.data.accounts.contains(where: { $0.kind == .flex }) {
                    Text("Monzo Flex isn't available through Monzo's developer API. Add what you owe on Flex as a manual account in settings.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct TransactionsView: View {
    @State private var search = ""
    @State private var category: SpendingCategory?
    private var money: MoneyService { FeatureHub.shared.money }

    var body: some View {
        let cal = DayCalendar(timeZone: money.timeZone)
        let rows = money.data.transactions.filter { tx in
            (search.isEmpty || tx.name.localizedCaseInsensitiveContains(search) || tx.descriptionText.localizedCaseInsensitiveContains(search)
                || (tx.notes ?? "").localizedCaseInsensitiveContains(search))
                && (category == nil || money.category(tx) == category)
        }.prefix(1500)

        Table(Array(rows)) {
            TableColumn("Date") { tx in Text(cal.format(tx.date, "d MMM yy")).monospacedDigit() }
                .width(min: 70, ideal: 80, max: 100)
            TableColumn("Name") { tx in
                VStack(alignment: .leading) {
                    Text(tx.name.isEmpty ? tx.descriptionText : tx.name)
                    if tx.isPending || tx.isDeclined || tx.isInternal {
                        Text(tx.isDeclined ? "Declined" : (tx.isInternal ? "Transfer" : "Pending"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            TableColumn("Category") { tx in
                Menu(money.category(tx).label) {
                    ForEach(SpendingCategory.allCases) { c in
                        Button(c.label) { money.setCategory(tx, c) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .width(min: 110, ideal: 140)
            TableColumn("Amount") { tx in
                Text(MoneyFormat.pounds(tx.amountPence, currency: tx.currency, showPlus: true))
                    .monospacedDigit()
                    .foregroundStyle(tx.amountPence > 0 ? Color.green : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100)
        }
        .searchable(text: $search, prompt: "Search transactions")
        .toolbar {
            Picker("Category", selection: $category) {
                Text("All categories").tag(SpendingCategory?.none)
                ForEach(SpendingCategory.allCases) { Text($0.label).tag(SpendingCategory?.some($0)) }
            }
        }
    }
}

struct BudgetsView: View {
    private var money: MoneyService { FeatureHub.shared.money }

    var body: some View {
        let statuses = Dictionary(uniqueKeysWithValues: money.budgetStatuses().map { ($0.category, $0) })
        let spent = Dictionary(uniqueKeysWithValues: money.monthSpending().map { ($0.category, $0.pence) })
        Form {
            Section {
                ForEach(SpendingCategory.spendingCases) { c in
                    BudgetRow(category: c, status: statuses[c], spent: spent[c] ?? 0,
                              limit: money.data.budgets.first { $0.category == c }?.monthlyLimitPence ?? 0) { pence in
                        money.setBudget(c, pence: pence)
                    }
                }
            } header: {
                Text("Monthly budgets")
            } footer: {
                Text("Leave a budget empty to just track the category. Correct a transaction's category in Transactions and Orbit remembers it for that shop.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct BudgetRow: View {
    let category: SpendingCategory
    let status: BudgetStatus?
    let spent: Int
    let limit: Int
    let onChange: (Int) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(category.label, systemImage: category.symbol)
                Spacer()
                Text(MoneyFormat.pounds(max(0, spent))).monospacedDigit().foregroundStyle(.secondary)
                Text("of").foregroundStyle(.secondary)
                TextField("£", text: $text)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { onChange(MoneyFormat.parsePence(text) ?? 0) }
            }
            if let status {
                ProgressView(value: min(1, status.fractionUsed))
                Text(status.isOver ? "Over by \(MoneyFormat.pounds(-status.remainingPence))"
                     : "\(MoneyFormat.pounds(status.remainingPence)) left" + (status.aheadOfPace ? " · spending faster than the month" : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(status.isOver ? Color.red : Color.secondary)
            }
        }
        .onAppear { text = limit > 0 ? String(format: "%.0f", Double(limit) / 100) : "" }
    }
}

struct InvestmentsView: View {
    private var money: MoneyService { FeatureHub.shared.money }

    var body: some View {
        if let inv = money.data.investments {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Trading 212").foregroundStyle(.secondary)
                        Text(MoneyFormat.pounds(inv.totalPence, currency: inv.currency)).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                        Text("Invested \(MoneyFormat.pounds(inv.investedPence, currency: inv.currency)) · Cash \(MoneyFormat.pounds(inv.freeCashPence, currency: inv.currency)) · P/L \(MoneyFormat.pounds(inv.unrealisedPence, currency: inv.currency, showPlus: true)) · Realised \(MoneyFormat.pounds(inv.realisedPence, currency: inv.currency, showPlus: true))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("Updated \(DayCalendar(timeZone: money.timeZone).time(inv.fetchedAt)) · \(money.t212Status)")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                Section("Positions") {
                    ForEach(inv.positions) { p in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(p.symbol)
                                Text(String(format: "%.4g shares · avg %.2f · now %.2f", p.quantity, p.averagePrice ?? 0, p.currentPrice ?? 0))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(MoneyFormat.pounds(MoneyFormat.pence(p.ppl ?? 0), currency: inv.currency, showPlus: true))
                                .monospacedDigit()
                                .foregroundStyle((p.ppl ?? 0) >= 0 ? Color.green : Color.red)
                        }
                    }
                }
                if !inv.orders.isEmpty {
                    Section("Recent orders") {
                        ForEach(inv.orders.prefix(20)) { o in
                            HStack {
                                Text("\(o.ticker.map { $0.split(separator: "_").first.map(String.init) ?? $0 } ?? "?") \(o.type ?? "")")
                                Spacer()
                                Text("\(o.status ?? "") \(o.filledValue.map { String(format: "%.2f", $0) } ?? "")")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .toolbar { Button("Refresh") { Task { await money.syncTrading212() } } }
        } else {
            ContentUnavailableView("No investments", systemImage: "chart.line.uptrend.xyaxis",
                                   description: Text("Add a Trading 212 API key in Money settings."))
        }
    }
}
