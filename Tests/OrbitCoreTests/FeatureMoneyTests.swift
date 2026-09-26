import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OrbitCore

private func cs(_ r: (category: SpendingCategory, source: CategorySource)) -> String { "\(r.category.rawValue)/\(r.source.rawValue)" }

final class FeatureMoneyTests: XCTestCase {
    let tz = TimeZone(identifier: "Europe/London")!
    var cal: DayCalendar { DayCalendar(timeZone: tz) }
    func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 12) -> Date { cal.date(year: y, month: m, day: day, hour: h)! }

    func tx(_ name: String, _ pence: Int, _ date: Date, bank: String? = nil, isInternal: Bool = false, id: String? = nil,
            type: String? = nil) -> MoneyTransaction {
        MoneyTransaction(id: id ?? UUID().uuidString, accountID: "a", date: date, amountPence: pence, name: name,
                         bankCategory: bank, type: type, isInternal: isInternal, source: .manual)
    }

    // MARK: Categoriser

    func testMerchantKeyNormalises() {
        XCTAssertEqual(MerchantKey.make("TESCO STORES 3456 EXETER GBR"), "tesco stores")
        XCTAssertEqual(MerchantKey.make("Sainsbury's"), "sainsburys")
        XCTAssertEqual(MerchantKey.make("M&S Simply Food"), "m and s")
        XCTAssertEqual(MerchantKey.make("O2"), "o2")
        XCTAssertEqual(MerchantKey.make("APPLE.COM/BILL"), "apple.com bill")
    }

    func testRulesForCommonUKMerchants() {
        let c = Categoriser()
        let cases: [(String, SpendingCategory)] = [
            ("TESCO STORES 3456", .groceries), ("Sainsbury's", .groceries), ("ALDI 12", .groceries), ("Lidl GB Exeter", .groceries),
            ("Deliveroo", .takeaway), ("UBER *EATS", .takeaway), ("Uber Eats", .takeaway), ("Just Eat", .takeaway),
            ("TfL Travel Charge", .transport), ("Trainline", .transport), ("Stagecoach South West", .transport), ("Uber *Trip", .transport),
            ("Spotify", .subscriptions), ("Netflix.com", .subscriptions), ("APPLE.COM/BILL", .subscriptions),
            ("Exeter Students' Guild", .goingOut), ("Timepiece", .goingOut), ("Unite Students", .rent),
            ("O2", .bills), ("Boots", .personalCare), ("Amazon.co.uk", .shopping), ("Amazon Prime", .subscriptions),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(c.categorise(tx(name, -500, d(2026, 10, 1))).category, expected, name)
        }
    }

    func testShortPatternsNeedWholeWords() {
        XCTAssertNil(Categoriser.rule(for: "barnstaple museum"))  // "bar" inside a word
        XCTAssertEqual(Categoriser.rule(for: "the old bar"), .goingOut)
        XCTAssertNil(Categoriser.rule(for: "sheet music"))       // "ee" must be a whole word
    }

    func testOrderOverrideThenRefiningRuleThenBank() {
        var c = Categoriser()
        // Monzo says eating out; the takeaway rule refines it.
        XCTAssertEqual(c.categorise(tx("Deliveroo", -1500, d(2026, 10, 1), bank: "eating_out")).category, .takeaway)
        // Monzo's own category beats a general rule.
        XCTAssertEqual(c.categorise(tx("Tesco", -500, d(2026, 10, 1), bank: "shopping")).category, .shopping)
        // "general" is too vague: rules decide.
        XCTAssertEqual(cs(c.categorise(tx("Tesco", -500, d(2026, 10, 1), bank: "general"))), "groceries/rule")
        // Unknown merchant → general fallback, then AI guess, then the student's override wins.
        let odd = tx("Crankhouse Coffee Roasters", -350, d(2026, 10, 1))
        XCTAssertEqual(c.categorise(odd).category, .eatingOut) // "coffee"
        let unknown = tx("Zyx Holdings", -999, d(2026, 10, 1))
        XCTAssertEqual(c.categorise(unknown).source, .fallback)
        XCTAssertEqual(c.unknownMerchants([unknown]), ["zyx holdings"])
        c.aiGuesses["zyx holdings"] = .shopping
        XCTAssertEqual(cs(c.categorise(unknown)), "shopping/ai")
        c.learn(unknown, as: .gifts)
        XCTAssertEqual(cs(c.categorise(unknown)), "gifts/override")
        XCTAssertEqual(c.categorise(tx("ZYX HOLDINGS", -100, d(2026, 10, 2))).category, .gifts)
    }

    func testInternalAndIncome() {
        let c = Categoriser()
        XCTAssertEqual(c.categorise(tx("Savings pot", -5000, d(2026, 10, 1), isInternal: true)).category, .transfers)
        XCTAssertEqual(c.categorise(tx("Student Loans Company", 150_000, d(2026, 10, 1))).category, .income)
        // A refund keeps its spending category (reduces spending).
        XCTAssertEqual(c.categorise(tx("Tesco", 300, d(2026, 10, 1), bank: "groceries")).category, .groceries)
    }

    func testMonzoCategoryNames() {
        XCTAssertEqual(SpendingCategory(monzo: "eating_out"), .eatingOut)
        XCTAssertEqual(SpendingCategory(monzo: "Eating out"), .eatingOut)
        XCTAssertEqual(SpendingCategory(monzo: "Personal care"), .personalCare)
        XCTAssertEqual(SpendingCategory(monzo: "mondo"), .transfers)
        XCTAssertNil(SpendingCategory(monzo: "general"))
    }

    // MARK: Budget math

    func testSpendingAndBudgets() {
        let now = d(2026, 10, 10) // 9.5 days into a 31-day month
        let txs = [
            tx("Tesco", -4000, d(2026, 10, 2)), tx("Aldi", -2000, d(2026, 10, 8)), tx("Tesco", 500, d(2026, 10, 9), bank: "groceries"),
            tx("Deliveroo", -2500, d(2026, 10, 5)), tx("Deliveroo", -1000, d(2026, 9, 28)),
            tx("Pot", -10000, d(2026, 10, 3), isInternal: true), tx("Loan", 100_000, d(2026, 10, 1)),
        ]
        let (start, end, days) = MoneyMath.monthBounds(now, timeZone: tz)
        XCTAssertEqual(days, 31)
        let spending = MoneyMath.spending(txs, categoriser: Categoriser(), from: start, to: end)
        XCTAssertEqual(spending[.groceries], 5500)
        XCTAssertEqual(spending[.takeaway], 2500)
        XCTAssertNil(spending[.transfers])
        XCTAssertNil(spending[.income])

        let status = MoneyMath.budgets([Budget(category: .groceries, monthlyLimitPence: 12000),
                                        Budget(category: .takeaway, monthlyLimitPence: 2000)],
                                       spending: spending, now: now, timeZone: tz)
        XCTAssertEqual(status.first?.category, .takeaway) // most used first
        let take = status.first { $0.category == .takeaway }!
        XCTAssertTrue(take.isOver)
        XCTAssertEqual(take.remainingPence, -500)
        let groc = status.first { $0.category == .groceries }!
        XCTAssertEqual(groc.remainingPence, 6500)
        XCTAssertTrue(groc.aheadOfPace) // 46% used after ~31% of the month
        XCTAssertGreaterThan(groc.projectedPence, 12000)
    }

    func testWeeklySummary() {
        let now = d(2026, 10, 14)
        let txs = [tx("Tesco", -3000, d(2026, 10, 12)), tx("Greggs", -500, d(2026, 10, 13)), tx("Tesco", -1000, d(2026, 10, 5))]
        let w = MoneyMath.weekly(txs, categoriser: Categoriser(), now: now)
        XCTAssertEqual(w.totalPence, 3500)
        XCTAssertEqual(w.previousWeekPence, 1000)
        XCTAssertEqual(w.byCategory.first?.category, .groceries)
        XCTAssertEqual(w.topMerchants.first?.name, "Tesco")
        XCTAssertTrue(w.summary.contains("£35.00"), w.summary)
    }

    func testSubscriptionDetection() {
        let now = d(2026, 10, 20)
        var txs: [MoneyTransaction] = []
        for (i, m) in [7, 8, 9, 10].enumerated() { txs.append(tx("Spotify", -1199, d(2026, m, 3), id: "s\(i)")) }
        txs.append(tx("Netflix.com", -1099, d(2026, 9, 15)))
        txs.append(tx("Netflix.com", -1099, d(2026, 10, 15)))
        // Irregular: not a subscription.
        txs += [tx("Tesco", -2300, d(2026, 10, 1)), tx("Tesco", -800, d(2026, 10, 4)), tx("Tesco", -4100, d(2026, 10, 15))]
        // Stopped months ago.
        txs += [tx("Old Gym", -2000, d(2026, 3, 1)), tx("Old Gym", -2000, d(2026, 4, 1))]
        let subs = MoneyMath.subscriptions(txs, now: now)
        XCTAssertEqual(Set(subs.map(\.merchantKey)), ["spotify", "netflix.com"])
        let spotify = subs.first { $0.merchantKey == "spotify" }!
        XCTAssertEqual(spotify.cadence, .monthly)
        XCTAssertEqual(spotify.amountPence, 1199)
        XCTAssertGreaterThan(spotify.nextExpected, now)
        XCTAssertEqual(spotify.occurrences, 4)
    }

    func testSafeToSpend() {
        let now = d(2026, 10, 20)
        let accounts = [MoneyAccount(id: "cur", name: "Monzo", kind: .current, balancePence: 60000),
                        MoneyAccount(id: "pot", name: "Rent pot", kind: .pot, balancePence: 50000),
                        MoneyAccount(id: "flex", name: "Flex", kind: .flex, balancePence: 12000)]
        let spotify = Subscription(merchantKey: "spotify", name: "Spotify", amountPence: 1199, cadence: .monthly,
                                   lastDate: d(2026, 10, 3), nextExpected: d(2026, 11, 3), occurrences: 4)
        let later = Subscription(merchantKey: "x", name: "X", amountPence: 5000, cadence: .monthly,
                                 lastDate: d(2026, 10, 1), nextExpected: d(2026, 12, 1), occurrences: 2)
        let s = MoneyMath.safeToSpend(accounts: accounts,
                                      income: [IncomeEvent(label: "Loan", date: d(2027, 1, 11)), IncomeEvent(label: "Pay", date: d(2026, 11, 6))],
                                      subscriptions: [spotify, later], bufferPence: 5000, now: now, timeZone: tz)
        XCTAssertEqual(s.nextIncome?.label, "Pay")
        XCTAssertEqual(s.spendablePence, 60000)       // pots and Flex don't count
        XCTAssertEqual(s.committedPence, 1199)        // only Spotify is due before payday
        XCTAssertEqual(s.availablePence, 60000 - 1199 - 5000)
        XCTAssertEqual(s.days, 17)
        XCTAssertEqual(s.perDayPence, (60000 - 1199 - 5000) / 17)
    }

    func testNetWorth() {
        let accounts = [MoneyAccount(id: "cur", name: "Monzo", kind: .current, balancePence: 60000),
                        MoneyAccount(id: "pot", name: "Pot", kind: .pot, balancePence: 50000),
                        MoneyAccount(id: "cash", name: "Cash", kind: .cash, balancePence: 2000),
                        MoneyAccount(id: "flex", name: "Monzo Flex", kind: .flex, balancePence: 12000)]
        let nw = MoneyMath.netWorth(accounts: accounts, investmentsPence: 250_000)
        XCTAssertEqual(nw.cashPence, 62000)
        XCTAssertEqual(nw.potsPence, 50000)
        XCTAssertEqual(nw.investmentsPence, 250_000)
        XCTAssertEqual(nw.liabilitiesPence, 12000)
        XCTAssertEqual(nw.totalPence, 62000 + 50000 + 250_000 - 12000)
    }

    func testMoneyFormatting() {
        XCTAssertEqual(MoneyFormat.pounds(123456), "£1,234.56")
        XCTAssertEqual(MoneyFormat.pounds(-1200), "−£12.00")
        XCTAssertEqual(MoneyFormat.pounds(5), "£0.05")
        XCTAssertEqual(MoneyFormat.parsePence("-12.50"), -1250)
        XCTAssertEqual(MoneyFormat.parsePence("£1,234.56"), 123456)
        XCTAssertEqual(MoneyFormat.parsePence("(4.20)"), -420)
        XCTAssertEqual(MoneyFormat.parsePence("0.1"), 10)
        XCTAssertNil(MoneyFormat.parsePence("abc"))
    }

    // MARK: CSV

    static let monzoCSV = "\u{FEFF}" + #"""
    Transaction ID,Date,Time,Type,Name,Emoji,Category,Amount,Currency,Local amount,Local currency,Notes and #tags,Address,Receipt,Description,Category split,Money Out,Money In
    tx_0000AAAA0000000000000001,01/10/2026,09:12:44,Card payment,Tesco,🛒,Groceries,-23.45,GBP,-23.45,GBP,,"Sidwell Street, Exeter, EX4 6NN",,TESCO STORES 3456 EXETER GBR,,-23.45,
    tx_0000AAAA0000000000000002,01/10/2026,12:01:00,Faster payment,Student Loans Company,,Income,1500.00,GBP,1500.00,GBP,Term 1 loan,,,SLC,,,1500.00
    tx_0000AAAA0000000000000003,02/10/2026,18:30:10,Pot transfer,Rent pot,,Savings,-400.00,GBP,-400.00,GBP,,,,POT TRANSFER,,-400.00,
    tx_0000AAAA0000000000000004,03/10/2026,21:15:03,Card payment,"Deliveroo, London",🍔,Eating out,-18.20,GBP,-18.20,GBP,"late one, #takeaway",,,DELIVEROO,,-18.20,
    tx_0000AAAA0000000000000005,04/10/2026,23:40:00,Card payment,"Timepiece ""Nightclub""",,Entertainment,-12.00,GBP,-12.00,GBP,,,,TIMEPIECE EXETER,,-12.00,
    tx_0000AAAA0000000000000006,05/10/2026,10:00:00,Card payment,Uniqlo,,Shopping,-35.00,EUR,-40.00,EUR,,,,UNIQLO PARIS,,-35.00,
    not-a-date-row,,,,,,,,,,,,,,,,,
    """#

    func testMonzoCSVParsesRealisticExport() {
        let r = MonzoCSVImporter.parse(Self.monzoCSV, accountID: "monzo", timeZone: tz)
        XCTAssertEqual(r.transactions.count, 6)
        XCTAssertEqual(r.skippedRows, 1)
        let t = Dictionary(uniqueKeysWithValues: r.transactions.map { ($0.id, $0) })
        let tesco = t["tx_0000AAAA0000000000000001"]!
        XCTAssertEqual(tesco.amountPence, -2345)
        XCTAssertEqual(tesco.name, "Tesco")
        XCTAssertEqual(tesco.bankCategory, "Groceries")
        XCTAssertEqual(tesco.date, cal.date(year: 2026, month: 10, day: 1, hour: 9, minute: 12)!.addingTimeInterval(44))
        XCTAssertEqual(t["tx_0000AAAA0000000000000002"]!.amountPence, 150_000)
        XCTAssertTrue(t["tx_0000AAAA0000000000000003"]!.isInternal)
        let deliveroo = t["tx_0000AAAA0000000000000004"]!
        XCTAssertEqual(deliveroo.name, "Deliveroo, London")
        XCTAssertEqual(deliveroo.notes, "late one, #takeaway")
        XCTAssertEqual(t["tx_0000AAAA0000000000000005"]!.name, "Timepiece \"Nightclub\"")
        XCTAssertEqual(t["tx_0000AAAA0000000000000006"]!.currency, "EUR")

        let c = Categoriser()
        XCTAssertEqual(c.categorise(deliveroo).category, .takeaway)
        XCTAssertEqual(c.categorise(t["tx_0000AAAA0000000000000005"]!).category, .goingOut)
        XCTAssertEqual(c.categorise(t["tx_0000AAAA0000000000000003"]!).category, .transfers)
        XCTAssertEqual(c.categorise(t["tx_0000AAAA0000000000000002"]!).category, .income)
    }

    func testMonzoCSVMoneyInOutOnlyAndReimportMerge() {
        let csv = """
        Transaction ID,Date,Time,Name,Category,Money Out,Money In
        tx_1,01/10/2026,09:00:00,Tesco,Groceries,-10.00,
        tx_2,02/10/2026,09:00:00,Mum,Transfers,,50.00
        """
        let first = MonzoCSVImporter.parse(csv, timeZone: tz).transactions
        XCTAssertEqual(first.map(\.amountPence), [-1000, 5000])
        let merged = TransactionLedger.merge([], with: first)
        XCTAssertEqual(merged.added, 2)
        let again = TransactionLedger.merge(merged.all, with: MonzoCSVImporter.parse(csv, timeZone: tz).transactions)
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.all.count, 2)
    }

    func testGenericCSVWithMapping() {
        let csv = """
        Date;Description;Paid out;Paid in;Balance
        03/10/2026;CARD PAYMENT TO LIDL GB;12,50;;100.00
        04/10/2026;CARD PAYMENT TO LIDL GB;12,50;;87.50
        04/10/2026;CARD PAYMENT TO LIDL GB;12,50;;75.00
        """.replacingOccurrences(of: "12,50", with: "12.50")
        let headers = CSVReader.rows(csv, delimiter: ";").first!
        let mapping = GenericCSVImporter.suggestMapping(headers)!
        XCTAssertEqual(mapping.date, 0)
        XCTAssertEqual(mapping.moneyOut, 2)
        XCTAssertEqual(mapping.moneyIn, 3)
        let r = GenericCSVImporter.parse(csv, mapping: mapping, accountID: "bank", timeZone: tz)
        XCTAssertEqual(r.transactions.count, 3)
        XCTAssertEqual(r.transactions.map(\.amountPence), [-1250, -1250, -1250])
        XCTAssertEqual(Set(r.transactions.map(\.id)).count, 3) // same-day duplicates stay distinct
        let again = GenericCSVImporter.parse(csv, mapping: mapping, accountID: "bank", timeZone: tz)
        XCTAssertEqual(TransactionLedger.merge(r.transactions, with: again.transactions).added, 0)
        XCTAssertEqual(Categoriser().categorise(r.transactions[0]).category, .groceries)
    }

    func testCSVReaderEdgeCases() {
        let rows = CSVReader.rows("a,\"b,c\",\"d \"\"q\"\"\"\r\n1,\"multi\nline\",3\n\n")
        XCTAssertEqual(rows, [["a", "b,c", "d \"q\""], ["1", "multi\nline", "3"]])
    }

    // MARK: JSON fixtures (fake ids; no real tokens)

    func testMonzoJSONDecoding() throws {
        let accounts = """
        {"accounts":[{"id":"acc_00000000000000000000A","closed":false,"created":"2023-09-01T10:00:00.000Z","description":"user_000000000000000000001","type":"uk_retail","currency":"GBP"},
                     {"id":"acc_00000000000000000000B","closed":false,"created":"2024-01-01T10:00:00.000Z","description":"Flex","type":"uk_monzo_flex"},
                     {"id":"acc_00000000000000000000C","closed":true,"created":"2020-01-01T10:00:00.000Z","type":"uk_prepaid"}]}
        """
        struct A: Decodable { let accounts: [MonzoAccountJSON] }
        let decoded = try JSONDecoder().decode(A.self, from: Data(accounts.utf8)).accounts
        XCTAssertEqual(decoded.count, 3)
        XCTAssertTrue(decoded[1].isFlex)
        XCTAssertEqual(decoded[1].label, "Monzo Flex")
        XCTAssertEqual(decoded[0].label, "Monzo")

        let balance = try JSONDecoder().decode(MonzoBalanceJSON.self, from: Data(#"{"balance":5000,"total_balance":6000,"currency":"GBP","spend_today":-250}"#.utf8))
        XCTAssertEqual(balance.balance, 5000)
        XCTAssertEqual(balance.total_balance, 6000)

        let txs = """
        {"transactions":[
          {"id":"tx_00000000000000000000001","created":"2026-10-01T09:12:44.123Z","amount":-2345,"currency":"GBP","description":"TESCO STORES 3456",
           "category":"groceries","settled":"2026-10-02T03:00:00.000Z","decline_reason":null,"is_load":false,"notes":"",
           "merchant":{"id":"merch_0001","name":"Tesco","category":"groceries","emoji":"🛒","logo":""},"metadata":{},"account_id":"acc_00000000000000000000A"},
          {"id":"tx_00000000000000000000002","created":"2026-10-02T18:30:10Z","amount":-40000,"currency":"GBP","description":"pot_00000000000000000000001",
           "category":"savings","settled":"2026-10-02T18:30:10Z","merchant":null,"metadata":{"pot_id":"pot_00000000000000000000001"},"account_id":"acc_00000000000000000000A"},
          {"id":"tx_00000000000000000000003","created":"2026-10-03T21:15:03Z","amount":-1820,"currency":"GBP","description":"DELIVEROO",
           "category":"eating_out","settled":"","merchant":"merch_0002","metadata":{"notes":"x"},"account_id":"acc_00000000000000000000A"},
          {"id":"tx_00000000000000000000004","created":"2026-10-03T22:00:00Z","amount":-999,"currency":"GBP","description":"STEAM",
           "category":"entertainment","settled":"","decline_reason":"INSUFFICIENT_FUNDS","merchant":null,"metadata":{}}
        ]}
        """
        struct T: Decodable { let transactions: [MonzoTransactionJSON] }
        let list = try JSONDecoder().decode(T.self, from: Data(txs.utf8)).transactions
        XCTAssertEqual(list.count, 4)
        let mapped = list.map { $0.transaction(accountID: "acc_00000000000000000000A") }
        XCTAssertEqual(mapped[0].name, "Tesco")
        XCTAssertEqual(mapped[0].amountPence, -2345)
        XCTAssertFalse(mapped[0].isPending)
        XCTAssertTrue(mapped[1].isInternal)
        XCTAssertEqual(list[2].merchant?.id, "merch_0002")
        XCTAssertTrue(mapped[2].isPending)
        XCTAssertTrue(mapped[3].isDeclined)
        XCTAssertEqual(mapped[3].accountID, "acc_00000000000000000000A")
        let spend = MoneyMath.spending(mapped, categoriser: Categoriser(), from: .distantPast, to: .distantFuture)
        XCTAssertEqual(spend[.groceries], 2345)
        XCTAssertEqual(spend[.takeaway], 1820)
        XCTAssertNil(spend[.entertainment]) // declined
        XCTAssertNil(spend[.savings])
    }

    func testMonzoAuthorizeURL() {
        let config = MonzoClientConfig(clientID: "oauth2client_TEST", clientSecret: "not-a-real-secret")
        let url = config.authorizeURL(state: "abc").absoluteString
        XCTAssertTrue(url.hasPrefix("https://auth.monzo.com/?"))
        XCTAssertTrue(url.contains("redirect_uri=http://127.0.0.1:53682/monzo/callback"))
        XCTAssertTrue(url.contains("response_type=code"))
        XCTAssertTrue(url.contains("state=abc"))
    }

    func testTrading212JSONDecoding() throws {
        let cash = try JSONDecoder().decode(T212Cash.self, from: Data(#"{"blocked":0,"free":152.34,"invested":1200.5,"pieCash":0,"ppl":84.12,"result":12.3,"total":1436.96}"#.utf8))
        XCTAssertEqual(cash.free, 152.34)
        let positions = try JSONDecoder().decode([T212Position].self, from: Data("""
        [{"averagePrice":150.25,"currentPrice":171.1,"frontend":"API","fxPpl":-1.2,"initialFillDate":"2025-02-01T14:15:22.000+02:00",
          "maxBuy":10,"maxSell":2,"pieQuantity":0,"ppl":35.5,"quantity":2.0,"ticker":"AAPL_US_EQ"},
         {"averagePrice":7.9,"currentPrice":8.1,"ppl":4.0,"quantity":20,"ticker":"VUSAl_EQ"}]
        """.utf8))
        XCTAssertEqual(positions.map(\.symbol), ["AAPL", "VUSAl"])
        let orders = try JSONDecoder().decode(T212Page<T212Order>.self, from: Data("""
        {"items":[{"dateCreated":"2026-09-01T10:00:00.000Z","dateExecuted":"2026-09-01T10:00:01.000Z","fillPrice":150.25,"filledQuantity":2,
                   "filledValue":300.5,"id":123,"status":"FILLED","ticker":"AAPL_US_EQ","type":"MARKET","taxes":[]}],
         "nextPagePath":"/api/v0/equity/history/orders?limit=50&cursor=123"}
        """.utf8))
        XCTAssertEqual(orders.items.first?.status, "FILLED")
        XCTAssertNotNil(orders.nextPagePath)
        let txs = try JSONDecoder().decode(T212Page<T212Transaction>.self, from: Data("""
        {"items":[{"amount":1000,"dateTime":"2026-01-01T09:00:00Z","reference":"ref","type":"DEPOSIT"},
                  {"amount":-200,"dateTime":"2026-02-01T09:00:00Z","reference":"ref2","type":"WITHDRAW"}],"nextPagePath":null}
        """.utf8))
        let snap = InvestmentSnapshot(fetchedAt: Date(), currency: "GBP", cash: cash, positions: positions, transactions: txs.items)
        XCTAssertEqual(snap.totalPence, 143696)
        XCTAssertEqual(snap.unrealisedPence, 8412)
        XCTAssertEqual(snap.netDepositsPence, 80000)
        XCTAssertEqual(MoneyMath.netWorth(accounts: [], investmentsPence: snap.totalPence).totalPence, 143696)
    }

    func testTrading212AuthHeaderAndClientRequests() async throws {
        XCTAssertEqual(Trading212Credentials(apiKey: "KEY").authorization, "KEY")
        XCTAssertEqual(Trading212Credentials(apiKey: "k", apiSecret: "s").authorization, "Basic " + Data("k:s".utf8).base64EncodedString())

        let transport = FeatureStubTransport { req in
            let path = req.url!.path
            if path.hasSuffix("equity/account/cash") { return (200, #"{"free":1,"total":2,"ppl":0,"result":0,"invested":1}"#) }
            if path.hasSuffix("equity/portfolio") { return (200, "[]") }
            if path.hasSuffix("equity/account/info") { return (200, #"{"currencyCode":"GBP","id":1}"#) }
            return (429, "slow down")
        }
        let limiter = RateLimiter(intervals: [:], defaultInterval: 0, sleep: { _ in })
        let client = Trading212Client(credentials: Trading212Credentials(apiKey: "KEY"), http: HTTPClient(transport: transport), limiter: limiter)
        let snap = try await client.snapshot(now: Date(), includeHistory: true)
        XCTAssertEqual(snap.totalPence, 200)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "KEY")
        XCTAssertTrue(transport.requests.first!.url!.absoluteString.hasPrefix("https://live.trading212.com/api/v0/"))
        do { _ = try await client.orders(); XCTFail("expected rate limit") } catch Trading212Error.rateLimited {}
    }

    func testRateLimiterSpacesCalls() async {
        let limiter = RateLimiter(intervals: ["cash": 2], sleep: { _ in })
        let t0 = Date(timeIntervalSince1970: 1000)
        let a = await limiter.reserve("cash", now: t0)
        let b = await limiter.reserve("cash", now: t0.addingTimeInterval(0.5))
        let c = await limiter.reserve("other", now: t0)
        XCTAssertEqual(a, 0)
        XCTAssertEqual(b, 1.5, accuracy: 0.001)
        XCTAssertEqual(c, 0)
    }
}

/// Minimal stub for feature tests.
final class FeatureStubTransport: HTTPTransport, @unchecked Sendable {
    let handler: (URLRequest) -> (Int, String)
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    init(_ handler: @escaping (URLRequest) -> (Int, String)) { self.handler = handler }

    private func record(_ r: URLRequest) { lock.lock(); _requests.append(r); lock.unlock() }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let (status, body) = handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
