import AppKit
import Foundation
import Observation
import OrbitCore

/// Everything money: Monzo (developer API, CSV import), manual accounts, Trading 212,
/// categories, budgets, safe-to-spend and net worth. All data stays on this Mac in
/// Application Support/Orbit/Money (owner-only files); secrets live in the Keychain.
/// Nothing here is synced to iCloud or sent to a cloud AI.
@MainActor
@Observable
final class MoneyService {
    enum MonzoState: Equatable {
        case notConnected
        case waitingForBrowser
        case awaitingApproval
        case importing(String)
        case connected
        case error(String)

        var label: String {
            switch self {
            case .notConnected: "Not connected"
            case .waitingForBrowser: "Finish signing in to Monzo in your browser…"
            case .awaitingApproval: "Approve Orbit in your Monzo app (check your notifications)…"
            case .importing(let s): s
            case .connected: "Connected"
            case .error(let e): e
            }
        }
    }

    @ObservationIgnored weak var hub: FeatureHub?
    @ObservationIgnored let files = FeatureFiles(subdirectory: "Money")
    @ObservationIgnored private var receiver: LoopbackCallbackReceiver?

    var data = MoneyData()
    var monzoState: MonzoState = .notConnected
    var t212Status = ""
    var busy = false
    private(set) var hasMonzoClient = false
    private(set) var hasMonzoToken = false
    private(set) var hasT212Key = false

    // MARK: Persistence

    func load() {
        data = files.load(MoneyData.self, "money.json") ?? MoneyData()
        refreshSecretFlags()
        if hasMonzoToken { monzoState = .connected }
    }

    func save() { files.save(data, "money.json") }

    private func refreshSecretFlags() {
        hasMonzoClient = SecretVault.load(MonzoClientConfig.self, .monzoClient) != nil
        hasMonzoToken = SecretVault.load(MonzoToken.self, .monzoToken) != nil
        hasT212Key = SecretVault.load(Trading212Credentials.self, .trading212) != nil
    }

    var timeZone: TimeZone { hub?.prefs.timeZone ?? TimeZone(identifier: "Europe/London")! }

    // MARK: Schedule

    func syncIfDue(now: Date) async {
        if hasMonzoToken, monzoState == .connected || isError, now.timeIntervalSince(data.lastMonzoSync ?? .distantPast) > 30 * 60 {
            await syncMonzo()
        }
        if hasT212Key, now.timeIntervalSince(data.lastT212Sync ?? .distantPast) > 15 * 60 {
            await syncTrading212()
        }
        if now.timeIntervalSince(data.lastAICategorise ?? .distantPast) > 6 * 3600 {
            data.lastAICategorise = now
            await categoriseUnknownWithLocalAI()
        }
    }

    private var isError: Bool { if case .error = monzoState { return true }; return false }

    // MARK: Monzo (developer API)

    var monzoClientID: String { SecretVault.load(MonzoClientConfig.self, .monzoClient)?.clientID ?? "" }

    func saveMonzoClient(id: String, secret: String) {
        let config = MonzoClientConfig(clientID: id.trimmingCharacters(in: .whitespacesAndNewlines),
                                       clientSecret: secret.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !config.clientID.isEmpty, !config.clientSecret.isEmpty else { return }
        SecretVault.save(config, .monzoClient)
        refreshSecretFlags()
        OrbitLog.log("money", "Monzo client saved")
    }

    /// OAuth in the browser → code on the loopback redirect → token → approval in the app → full import.
    func connectMonzo() async {
        guard let config = SecretVault.load(MonzoClientConfig.self, .monzoClient) else {
            monzoState = .error("Add your Monzo client ID and secret first.")
            return
        }
        let state = UUID().uuidString
        let receiver = LoopbackCallbackReceiver()
        self.receiver = receiver
        monzoState = .waitingForBrowser
        OrbitLog.log("money", "Monzo sign-in started")
        do {
            let url = config.authorizeURL(state: state)
            let query = try await receiver.wait(ready: { DispatchQueue.main.async { NSWorkspace.shared.open(url) } })
            guard query["state"] == state, let code = query["code"], !code.isEmpty else {
                monzoState = .error(query["error_description"] ?? query["error"] ?? "Monzo didn't return a sign-in code.")
                return
            }
            let token = try await MonzoAPI.exchange(code: code, config: config)
            SecretVault.save(token, .monzoToken)
            refreshSecretFlags()
            OrbitLog.log("money", "Monzo token received; waiting for approval in the app")
            await waitForApprovalThenImport(token: token)
        } catch {
            monzoState = .error(error.localizedDescription)
            OrbitLog.log("money", "Monzo sign-in failed: \(Self.redact(error))")
        }
        self.receiver = nil
    }

    func cancelMonzoConnect() {
        receiver?.cancel()
        receiver = nil
        if monzoState == .waitingForBrowser || monzoState == .awaitingApproval { monzoState = hasMonzoToken ? .connected : .notConnected }
    }

    /// Paste-a-token option (API playground). Short-lived (~6 h), no refresh; good for a one-off full import.
    func usePlaygroundToken(_ raw: String, userID: String?) async {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        let api = MonzoAPI(token: token)
        do {
            let me = try await api.whoami()
            guard me.authenticated else { monzoState = .error("Monzo says that token isn't signed in."); return }
            let saved = MonzoToken(accessToken: token, expiresAt: Date().addingTimeInterval(6 * 3600),
                                   userID: userID ?? me.user_id, isPlayground: true)
            SecretVault.save(saved, .monzoToken)
            refreshSecretFlags()
            OrbitLog.log("money", "Monzo playground token accepted")
            await waitForApprovalThenImport(token: saved)
        } catch {
            monzoState = .error(error.localizedDescription)
            OrbitLog.log("money", "Monzo playground token rejected: \(Self.redact(error))")
        }
    }

    /// Polls until the student approves Orbit in the Monzo app (403 until then), then
    /// imports every transaction straight away: after 5 minutes Monzo only returns the last 90 days.
    private func waitForApprovalThenImport(token: MonzoToken) async {
        let api = MonzoAPI(token: token.accessToken)
        monzoState = .awaitingApproval
        var accounts: [MonzoAccountJSON]?
        for _ in 0..<180 { // up to 15 minutes
            do {
                accounts = try await api.accounts()
                break
            } catch MonzoError.awaitingApproval {
                try? await Task.sleep(for: .seconds(5))
            } catch {
                monzoState = .error(error.localizedDescription)
                return
            }
        }
        guard let accounts else { monzoState = .error("Orbit wasn't approved in the Monzo app in time. Try Connect again."); return }
        await importMonzo(api: api, accounts: accounts, full: true)
    }

    /// Returns a usable token, refreshing (and storing the new single-use refresh token) if needed.
    private func validToken() async -> MonzoToken? {
        guard var token = SecretVault.load(MonzoToken.self, .monzoToken) else { return nil }
        guard token.isExpired(at: Date()) else { return token }
        guard let refresh = token.refreshToken, let config = SecretVault.load(MonzoClientConfig.self, .monzoClient) else {
            monzoState = .error(token.isPlayground ? "The pasted Monzo token has expired. Use Connect for ongoing sync."
                                                   : "Monzo sign-in expired. Connect again.")
            return nil
        }
        do {
            token = try await MonzoAPI.refresh(refresh, config: config)
            SecretVault.save(token, .monzoToken)
            OrbitLog.log("money", "Monzo token refreshed")
            return token
        } catch {
            monzoState = .error("Monzo needs you to connect again (every 90 days).")
            OrbitLog.log("money", "Monzo refresh failed: \(Self.redact(error))")
            return nil
        }
    }

    func syncMonzo() async {
        guard !busy, let token = await validToken() else { return }
        busy = true
        defer { busy = false }
        let api = MonzoAPI(token: token.accessToken)
        do {
            let accounts = try await api.accounts()
            await importMonzo(api: api, accounts: accounts, full: false)
        } catch MonzoError.unauthorised {
            // Maybe revoked or replaced: try one refresh on the next run.
            if var t = SecretVault.load(MonzoToken.self, .monzoToken) { t.expiresAt = Date(); SecretVault.save(t, .monzoToken) }
            monzoState = .error("Monzo sign-in expired. Orbit will try to refresh it; if that fails, connect again.")
        } catch MonzoError.awaitingApproval {
            monzoState = .awaitingApproval
        } catch {
            monzoState = .error(error.localizedDescription)
            OrbitLog.log("money", "Monzo sync failed: \(Self.redact(error))")
        }
    }

    private func importMonzo(api: MonzoAPI, accounts: [MonzoAccountJSON], full: Bool) async {
        let own = Set(accounts.map(\.id))
        var added = 0
        var sawFlex = false
        do {
            for (i, acc) in accounts.enumerated() {
                monzoState = .importing("Importing \(acc.label) (\(i + 1) of \(accounts.count))…")
                let balance = try await api.balance(accountID: acc.id)
                if acc.isFlex {
                    sawFlex = true
                    upsert(MoneyAccount(id: acc.id, name: acc.label, kind: .flex, balancePence: abs(balance.balance),
                                        currency: balance.currency ?? "GBP", source: .monzoAPI))
                } else {
                    upsert(MoneyAccount(id: acc.id, name: acc.label, kind: (acc.type ?? "").contains("joint") ? .joint : .current,
                                        balancePence: balance.balance, currency: balance.currency ?? "GBP", source: .monzoAPI))
                    for pot in (try? await api.pots(accountID: acc.id)) ?? [] {
                        upsert(MoneyAccount(id: pot.id, name: pot.name, kind: .pot, balancePence: pot.balance,
                                            currency: pot.currency ?? "GBP", source: .monzoAPI))
                    }
                }
                // Full history right after approval; afterwards since the last transaction id
                // (or 89 days back, the most Monzo allows later on).
                let since: String
                if !full, let last = data.monzoLastTxID[acc.id] { since = last }
                else if full { since = acc.created ?? "2015-01-01T00:00:00Z" }
                else { since = MonzoAPI.rfc3339(Date().addingTimeInterval(-89 * 86400)) }
                let raw = try await api.allTransactions(accountID: acc.id, since: since, pause: {
                    try? await Task.sleep(for: .milliseconds(250))
                })
                let txs = raw.map { $0.transaction(accountID: acc.id, ownAccountIDs: own) }
                let merged = TransactionLedger.merge(data.transactions, with: txs)
                data.transactions = merged.all
                added += merged.added
                // Keep the cursor on the newest settled transaction so pending ones are re-read.
                if let last = raw.last(where: { !($0.settled ?? "").isEmpty })?.id ?? raw.last?.id { data.monzoLastTxID[acc.id] = last }
            }
            data.flexNotAvailable = !sawFlex
            data.lastMonzoSync = Date()
            monzoState = .connected
            save()
            OrbitLog.log("money", "Monzo sync: \(accounts.count) account(s), \(added) new transaction(s)\(full ? " (full import)" : "")")
            if full { hub?.toast("Monzo imported: \(added) transactions") }
        } catch MonzoError.awaitingApproval {
            monzoState = .awaitingApproval
        } catch {
            monzoState = .error(error.localizedDescription)
            save()
            OrbitLog.log("money", "Monzo import stopped: \(Self.redact(error))")
        }
    }

    func disconnectMonzo() async {
        if let token = SecretVault.load(MonzoToken.self, .monzoToken) { await MonzoAPI(token: token.accessToken).logout() }
        SecretVault.delete(.monzoToken)
        refreshSecretFlags()
        monzoState = .notConnected
        OrbitLog.log("money", "Monzo disconnected (data kept on this Mac)")
    }

    func forgetMonzoClient() {
        SecretVault.delete(.monzoClient)
        refreshSecretFlags()
    }

    // MARK: Trading 212

    func saveTrading212(key: String, secret: String?) async {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        let s = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        SecretVault.save(Trading212Credentials(apiKey: k, apiSecret: (s ?? "").isEmpty ? nil : s), .trading212)
        refreshSecretFlags()
        OrbitLog.log("money", "Trading 212 key saved")
        await syncTrading212()
    }

    func removeTrading212() {
        SecretVault.delete(.trading212)
        data.investments = nil
        refreshSecretFlags()
        save()
    }

    func syncTrading212() async {
        guard let creds = SecretVault.load(Trading212Credentials.self, .trading212) else { return }
        t212Status = "Updating…"
        do {
            let snap = try await Trading212Client(credentials: creds).snapshot(includeHistory: data.investments == nil
                || Date().timeIntervalSince(data.lastT212History ?? .distantPast) > 6 * 3600)
            var merged = snap
            if merged.orders.isEmpty, let old = data.investments { merged.orders = old.orders; merged.transactions = old.transactions }
            else { data.lastT212History = Date() }
            data.investments = merged
            data.lastT212Sync = Date()
            t212Status = "Updated \(DayCalendar(timeZone: timeZone).time(Date()))"
            save()
            OrbitLog.log("money", "Trading 212 updated: \(snap.positions.count) position(s)")
        } catch {
            data.lastT212Sync = Date() // back off until the next slot
            t212Status = (error as? Trading212Error)?.description ?? error.localizedDescription
            OrbitLog.log("money", "Trading 212 failed: \(Self.redact(error))")
        }
    }

    // MARK: CSV import

    enum ImportOutcome {
        case imported(added: Int, total: Int, warnings: [String])
        case needsMapping(headers: [String], text: String)
        case failed(String)
    }

    /// Monzo exports import straight away; other banks need a column mapping first.
    func importCSV(url: URL, accountID: String = "monzo-current") -> ImportOutcome {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let raw = try? Data(contentsOf: url) else { return .failed("Couldn't read that file.") }
        let text = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1) ?? ""
        guard let headers = CSVReader.rows(text, delimiter: CSVReader.detectDelimiter(text)).first else { return .failed("The file is empty.") }
        guard MonzoCSVImporter.looksLikeMonzo(headers) else { return .needsMapping(headers: headers, text: text) }
        ensureAccount(id: accountID, name: "Monzo", kind: .current, source: .monzoCSV)
        let result = MonzoCSVImporter.parse(text, accountID: accountID, timeZone: timeZone)
        return finishImport(result)
    }

    func importGeneric(text: String, mapping: CSVColumnMapping, accountID: String, accountName: String) -> ImportOutcome {
        ensureAccount(id: accountID, name: accountName, kind: .current, source: .csv)
        return finishImport(GenericCSVImporter.parse(text, mapping: mapping, accountID: accountID, timeZone: timeZone))
    }

    private func finishImport(_ result: MonzoCSVImporter.Result) -> ImportOutcome {
        let merged = TransactionLedger.merge(data.transactions, with: result.transactions)
        data.transactions = merged.all
        save()
        OrbitLog.log("money", "CSV import: \(merged.added) new of \(result.transactions.count)")
        return .imported(added: merged.added, total: result.transactions.count, warnings: result.warnings)
    }

    private func ensureAccount(id: String, name: String, kind: AccountKind, source: MoneySource) {
        guard !data.accounts.contains(where: { $0.id == id }) else { return }
        data.accounts.append(MoneyAccount(id: id, name: name, kind: kind, balancePence: 0, source: source))
    }

    // MARK: Accounts, budgets, income

    func upsert(_ account: MoneyAccount) {
        if let i = data.accounts.firstIndex(where: { $0.id == account.id }) { data.accounts[i] = account } else { data.accounts.append(account) }
    }

    func setBalance(_ accountID: String, pence: Int) {
        guard let i = data.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        data.accounts[i].balancePence = pence
        data.accounts[i].updatedAt = Date()
        save()
    }

    func deleteAccount(_ id: String) {
        data.accounts.removeAll { $0.id == id }
        save()
    }

    func setBudget(_ category: SpendingCategory, pence: Int) {
        data.budgets.removeAll { $0.category == category }
        if pence > 0 { data.budgets.append(Budget(category: category, monthlyLimitPence: pence)) }
        data.budgets.sort { $0.category < $1.category }
        save()
    }

    func addIncome(_ event: IncomeEvent) {
        data.income.append(event)
        data.income.sort { $0.date < $1.date }
        save()
    }

    func removeIncome(_ id: String) {
        data.income.removeAll { $0.id == id }
        save()
    }

    // MARK: Categories

    func category(_ tx: MoneyTransaction) -> SpendingCategory { data.categoriser.categorise(tx).category }

    /// The student's correction, remembered for that merchant.
    func setCategory(_ tx: MoneyTransaction, _ category: SpendingCategory) {
        data.categoriser.learn(tx, as: category)
        save()
    }

    /// Unknown merchants → the local AI (`.privateData`: never a cloud model).
    func categoriseUnknownWithLocalAI() async {
        guard let router = hub?.router else { return }
        let unknown = data.categoriser.unknownMerchants(data.transactions)
        guard !unknown.isEmpty else { return }
        let guesses = await Categoriser.aiCategorise(unknown, router: router)
        guard !guesses.isEmpty else { return }
        for (k, v) in guesses { data.categoriser.aiGuesses[k] = v }
        save()
        OrbitLog.log("money", "local AI categorised \(guesses.count) merchant(s)")
    }

    // MARK: Numbers for the views

    func monthSpending(now: Date = Date()) -> [CategoryTotal] {
        let (start, end, _) = MoneyMath.monthBounds(now, timeZone: timeZone)
        return MoneyMath.sorted(MoneyMath.spending(data.transactions, categoriser: data.categoriser, from: start, to: end))
    }

    func budgetStatuses(now: Date = Date()) -> [BudgetStatus] {
        let (start, end, _) = MoneyMath.monthBounds(now, timeZone: timeZone)
        let spending = MoneyMath.spending(data.transactions, categoriser: data.categoriser, from: start, to: end)
        return MoneyMath.budgets(data.budgets, spending: spending, now: now, timeZone: timeZone)
    }

    func weekly(now: Date = Date()) -> WeeklySpend { MoneyMath.weekly(data.transactions, categoriser: data.categoriser, now: now) }

    func subscriptions(now: Date = Date()) -> [Subscription] { MoneyMath.subscriptions(data.transactions, now: now) }

    func safeToSpend(now: Date = Date()) -> SafeToSpend {
        MoneyMath.safeToSpend(accounts: data.accounts, income: data.income, subscriptions: subscriptions(now: now),
                              bufferPence: data.bufferPence, now: now, timeZone: timeZone)
    }

    func netWorth() -> NetWorth { MoneyMath.netWorth(accounts: data.accounts, investmentsPence: data.investments?.totalPence) }

    var hasAnyData: Bool { !data.accounts.isEmpty || !data.transactions.isEmpty || data.investments != nil }

    /// Plain text for the assistant (only ever given to a local model).
    func summaryText(now: Date = Date()) -> String {
        guard hasAnyData else { return "No money data yet. Connect Monzo or import a CSV in Money settings." }
        let nw = netWorth()
        let safe = safeToSpend(now: now)
        var lines = ["Net worth: \(MoneyFormat.pounds(nw.totalPence)) (cash \(MoneyFormat.pounds(nw.cashPence)), pots \(MoneyFormat.pounds(nw.potsPence)), investments \(MoneyFormat.pounds(nw.investmentsPence)), owed \(MoneyFormat.pounds(nw.liabilitiesPence)))."]
        lines.append("Safe to spend: \(MoneyFormat.pounds(safe.availablePence)) until \(safe.nextIncome.map { "\($0.label) on \(DayCalendar(timeZone: timeZone).shortDay($0.date))" } ?? "month end") (\(MoneyFormat.pounds(safe.perDayPence)) a day).")
        let month = monthSpending(now: now)
        if !month.isEmpty {
            lines.append("This month: " + month.prefix(6).map { "\($0.category.label) \(MoneyFormat.pounds($0.pence))" }.joined(separator: ", ") + ".")
        }
        lines.append(weekly(now: now).summary)
        for b in budgetStatuses(now: now) where b.isOver || b.aheadOfPace {
            lines.append("\(b.category.label) budget: \(MoneyFormat.pounds(b.spentPence)) of \(MoneyFormat.pounds(b.limitPence))\(b.isOver ? " (over)" : " (ahead of pace)").")
        }
        if let inv = data.investments {
            lines.append("Trading 212: \(MoneyFormat.pounds(inv.totalPence, currency: inv.currency)), P/L \(MoneyFormat.pounds(inv.unrealisedPence, currency: inv.currency, showPlus: true)).")
        }
        return lines.joined(separator: "\n")
    }

    /// Error text safe for the log: HTTP bodies can echo tokens, so they're dropped.
    static func redact(_ error: Error) -> String {
        if let h = error as? HTTPError { return "HTTP \(h.status)" }
        if let m = error as? MonzoError {
            if case .http(let code, _) = m { return "Monzo HTTP \(code)" }
            return m.description
        }
        if let t = error as? Trading212Error {
            if case .http(let code, _) = t { return "Trading 212 HTTP \(code)" }
            return t.description
        }
        return (error as NSError).domain + " \((error as NSError).code)"
    }
}

/// Everything the money screens show, stored locally.
struct MoneyData: Codable {
    var accounts: [MoneyAccount] = []
    var transactions: [MoneyTransaction] = []
    var budgets: [Budget] = []
    var income: [IncomeEvent] = []
    var categoriser = Categoriser()
    var investments: InvestmentSnapshot?
    var bufferPence = 5000
    var monzoLastTxID: [String: String] = [:]
    var lastMonzoSync: Date?
    var lastT212Sync: Date?
    var lastT212History: Date?
    var lastAICategorise: Date?
    /// No Flex account came back from the API: show the "add it manually" note.
    var flexNotAvailable = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case accounts, transactions, budgets, income, categoriser, investments, bufferPence, monzoLastTxID, lastMonzoSync,
             lastT212Sync, lastT212History, lastAICategorise, flexNotAvailable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            do { return try c.decode(T.self, forKey: key) } catch { return fallback }
        }
        accounts = v(.accounts, [])
        transactions = v(.transactions, [])
        budgets = v(.budgets, [])
        income = v(.income, [])
        categoriser = v(.categoriser, Categoriser())
        investments = v(.investments, nil as InvestmentSnapshot?)
        bufferPence = v(.bufferPence, 5000)
        monzoLastTxID = v(.monzoLastTxID, [:])
        lastMonzoSync = v(.lastMonzoSync, nil as Date?)
        lastT212Sync = v(.lastT212Sync, nil as Date?)
        lastT212History = v(.lastT212History, nil as Date?)
        lastAICategorise = v(.lastAICategorise, nil as Date?)
        flexNotAvailable = v(.flexNotAvailable, false)
    }
}
