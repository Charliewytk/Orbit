import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OrbitCore

/// Money setup: Monzo (developer API first, then playground token and CSV import),
/// manual accounts, Trading 212, pay/loan dates. Secrets go to the Keychain only.
struct MoneySettingsView: View {
    private var money: MoneyService { FeatureHub.shared.money }

    // Monzo client
    @State private var clientID = ""
    @State private var clientSecret = ""
    // Playground token
    @State private var playgroundToken = ""
    @State private var playgroundUser = ""
    // Trading 212
    @State private var t212Key = ""
    @State private var t212Secret = ""
    // Manual account
    @State private var newAccountName = ""
    @State private var newAccountKind: AccountKind = .flex
    @State private var newAccountBalance = ""
    // Income
    @State private var incomeLabel = "Student loan"
    @State private var incomeDate = Date()
    @State private var incomeAmount = ""
    @State private var buffer = ""
    // CSV
    @State private var importMessage: String?
    @State private var mapping: PendingMapping?
    @State private var dropTargeted = false

    struct PendingMapping: Identifiable {
        let id = UUID()
        let headers: [String]
        let text: String
    }

    var body: some View {
        Form {
            monzoSection
            playgroundSection
            csvSection
            accountsSection
            trading212Section
            incomeSection
            Section {
                Text("Money data stays on this Mac (Application Support/Orbit/Money). Keys and tokens are in your Keychain. Nothing is synced to iCloud or sent to a cloud AI; only the AI running on this Mac ever sees it, and only when you ask.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Money settings")
        .onAppear {
            clientID = money.monzoClientID
            buffer = String(format: "%.0f", Double(money.data.bufferPence) / 100)
        }
        .sheet(item: $mapping) { pending in
            CSVMappingSheet(headers: pending.headers, text: pending.text) { message in
                importMessage = message
                mapping = nil
            }
        }
    }

    // MARK: Monzo

    private var monzoSection: some View {
        Section {
            LabeledContent("Status", value: money.monzoState.label)
            if let last = money.data.lastMonzoSync {
                LabeledContent("Last sync", value: DayCalendar(timeZone: money.timeZone).format(last, "EEE d MMM HH:mm"))
            }
            TextField("Client ID", text: $clientID)
            SecureField(money.hasMonzoClient ? "Client secret (saved)" : "Client secret", text: $clientSecret)
            LabeledContent("Redirect URL") {
                HStack {
                    Text(MonzoClientConfig.redirectURI).textSelection(.enabled).font(.system(size: 12, design: .monospaced))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(MonzoClientConfig.redirectURI, forType: .string)
                    }
                }
            }
            HStack {
                Button("Save client") {
                    money.saveMonzoClient(id: clientID, secret: clientSecret)
                    clientSecret = ""
                }
                .disabled(clientID.isEmpty || clientSecret.isEmpty)
                Button("Connect Monzo") { Task { await money.connectMonzo() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!money.hasMonzoClient)
                if money.monzoState == .waitingForBrowser || money.monzoState == .awaitingApproval {
                    Button("Cancel") { money.cancelMonzoConnect() }
                }
                Spacer()
                if money.hasMonzoToken {
                    Button("Sync now") { Task { await money.syncMonzo() } }
                    Button("Disconnect") { Task { await money.disconnectMonzo() } }
                }
            }
        } header: {
            Text("Monzo")
        } footer: {
            Text("""
            One-off setup: go to developers.monzo.com and sign in → Clients → New OAuth Client. \
            Name: Orbit. Redirect URL: \(MonzoClientConfig.redirectURI). Confidentiality: Confidential (so Orbit can stay signed in). \
            Copy the Client ID and Client secret here, save, then Connect. Approve Orbit in the Monzo app when it asks: \
            Orbit then imports your full history straight away (Monzo only allows that in the first 5 minutes). \
            Orbit only reads; it never moves money. Monzo asks you to reconnect every 90 days.
            """)
        }
    }

    private var playgroundSection: some View {
        Section {
            DisclosureGroup("Paste a playground token instead") {
                SecureField("Access token", text: $playgroundToken)
                TextField("User ID (optional)", text: $playgroundUser)
                Button("Check and import") {
                    let token = playgroundToken
                    playgroundToken = ""
                    Task { await money.usePlaygroundToken(token, userID: playgroundUser.isEmpty ? nil : playgroundUser) }
                }
                .disabled(playgroundToken.isEmpty)
                Text("From the API playground at developers.monzo.com. It expires in about 6 hours and can't refresh, so use it for a one-off import; use the OAuth client above for ongoing sync. Approve the playground in the Monzo app first.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: CSV

    private var csvSection: some View {
        Section {
            HStack {
                Button("Import CSV…") { chooseCSV() }
                Text("or drop a file here").foregroundStyle(.secondary)
                Spacer()
            }
            .padding(6)
            .background(dropTargeted ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 6))
            .onDrop(of: [UTType.commaSeparatedText, UTType.fileURL], isTargeted: $dropTargeted) { providers in
                loadDropped(providers)
                return true
            }
            if let importMessage { Text(importMessage).font(.system(size: 11)).foregroundStyle(.secondary) }
        } header: {
            Text("Import a statement")
        } footer: {
            Text("Monzo app → your account → Statements (or Export transactions) → CSV. Re-importing is safe: transactions already here are skipped. Other banks' CSVs work too; you pick which column is which.")
        }
    }

    private func chooseCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText, UTType.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        handleImport(url)
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in handleImport(url) }
        }
    }

    private func handleImport(_ url: URL) {
        switch money.importCSV(url: url) {
        case .imported(let added, let total, let warnings):
            importMessage = "Imported \(added) new of \(total) transactions." + (warnings.isEmpty ? "" : " " + warnings.joined(separator: " "))
        case .needsMapping(let headers, let text):
            mapping = PendingMapping(headers: headers, text: text)
        case .failed(let message):
            importMessage = message
        }
    }

    // MARK: Accounts

    private var accountsSection: some View {
        Section {
            ForEach(money.data.accounts) { account in
                ManualAccountRow(account: account)
            }
            HStack {
                TextField("Name", text: $newAccountName)
                Picker("Kind", selection: $newAccountKind) {
                    ForEach(AccountKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                TextField("£", text: $newAccountBalance).frame(width: 80)
                Button("Add") {
                    let name = newAccountName.isEmpty ? newAccountKind.label : newAccountName
                    money.upsert(MoneyAccount(id: "manual-\(UUID().uuidString)", name: name, kind: newAccountKind,
                                              balancePence: MoneyFormat.parsePence(newAccountBalance) ?? 0))
                    money.save()
                    newAccountName = ""
                    newAccountBalance = ""
                }
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Add Monzo Flex (what you owe), cash, savings elsewhere or a credit card by hand, and update the amounts when they change.")
        }
    }

    // MARK: Trading 212

    private var trading212Section: some View {
        Section {
            SecureField(money.hasT212Key ? "API key (saved)" : "API key", text: $t212Key)
            SecureField("API secret (if your key has one)", text: $t212Secret)
            HStack {
                Button("Save and test") {
                    let key = t212Key, secret = t212Secret
                    t212Key = ""; t212Secret = ""
                    Task { await money.saveTrading212(key: key, secret: secret) }
                }
                .disabled(t212Key.isEmpty)
                if money.hasT212Key {
                    Button("Refresh") { Task { await money.syncTrading212() } }
                    Button("Remove key") { money.removeTrading212() }
                }
                Spacer()
                Text(money.t212Status).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } header: {
            Text("Trading 212")
        } footer: {
            Text("In the Trading 212 app: Settings → API (Beta) → Generate API key. Read-only permissions are enough (account data, portfolio, history). Orbit keeps under Trading 212's rate limits.")
        }
    }

    // MARK: Income

    private var incomeSection: some View {
        Section {
            ForEach(money.data.income) { event in
                HStack {
                    Text(event.label)
                    Spacer()
                    Text(DayCalendar(timeZone: money.timeZone).shortDay(event.date)).foregroundStyle(.secondary)
                    if let a = event.amountPence { Text(MoneyFormat.pounds(a)).monospacedDigit() }
                    Button(role: .destructive) { money.removeIncome(event.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("What", text: $incomeLabel)
                DatePicker("Date", selection: $incomeDate, displayedComponents: .date).labelsHidden()
                TextField("£ (optional)", text: $incomeAmount).frame(width: 90)
                Button("Add") {
                    money.addIncome(IncomeEvent(label: incomeLabel, date: incomeDate, amountPence: MoneyFormat.parsePence(incomeAmount)))
                    incomeAmount = ""
                }
            }
            LabeledContent("Keep aside") {
                TextField("£", text: $buffer)
                    .frame(width: 80)
                    .onSubmit {
                        money.data.bufferPence = max(0, MoneyFormat.parsePence(buffer) ?? 0)
                        money.save()
                    }
            }
        } header: {
            Text("Loan and pay dates")
        } footer: {
            Text("“Safe to spend” spreads your current-account money until the next date here, after subscriptions due before then and the amount you keep aside.")
        }
    }
}

private struct ManualAccountRow: View {
    let account: MoneyAccount
    @State private var text = ""
    private var money: MoneyService { FeatureHub.shared.money }

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(account.name)
                Text("\(account.kind.label) · \(account.source == .manual ? "manual" : "synced")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if account.source == .manual || account.source == .monzoCSV || account.source == .csv {
                TextField("£", text: $text)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { money.setBalance(account.id, pence: MoneyFormat.parsePence(text) ?? 0) }
                Button(role: .destructive) { money.deleteAccount(account.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            } else {
                Text(MoneyFormat.pounds(account.balancePence, currency: account.currency)).monospacedDigit()
            }
        }
        .onAppear { text = String(format: "%.2f", Double(account.balancePence) / 100) }
    }
}

/// Column mapping for a non-Monzo CSV.
struct CSVMappingSheet: View {
    let headers: [String]
    let text: String
    let done: (String) -> Void
    @State private var mapping: CSVColumnMapping
    @State private var accountName = "Bank account"
    @State private var useSeparateColumns = false
    private var money: MoneyService { FeatureHub.shared.money }

    init(headers: [String], text: String, done: @escaping (String) -> Void) {
        self.headers = headers
        self.text = text
        self.done = done
        let suggested = GenericCSVImporter.suggestMapping(headers) ?? CSVColumnMapping(date: 0, name: min(1, max(0, headers.count - 1)))
        _mapping = State(initialValue: suggested)
        _useSeparateColumns = State(initialValue: suggested.amount == nil)
    }

    var body: some View {
        Form {
            Section("Which column is which?") {
                TextField("Account name", text: $accountName)
                column("Date", required: $mapping.date)
                column("Payee / description", required: $mapping.name)
                if useSeparateColumns {
                    column("Money out", optional: $mapping.moneyOut)
                    column("Money in", optional: $mapping.moneyIn)
                } else {
                    column("Amount", optional: $mapping.amount)
                    Toggle("Spending is shown as positive numbers", isOn: $mapping.invertAmounts)
                }
                Toggle("Separate money in / out columns", isOn: $useSeparateColumns)
                column("Category (optional)", optional: $mapping.category)
            }
            HStack {
                Button("Cancel") { done("Import cancelled.") }
                Spacer()
                Button("Import") {
                    var m = mapping
                    if useSeparateColumns { m.amount = nil } else { m.moneyIn = nil; m.moneyOut = nil }
                    let id = "csv-" + MD5.hex(accountName.lowercased())
                    switch money.importGeneric(text: text, mapping: m, accountID: id, accountName: accountName) {
                    case .imported(let added, let total, let warnings):
                        done("Imported \(added) new of \(total) transactions." + (warnings.isEmpty ? "" : " " + warnings.joined(separator: " ")))
                    case .failed(let message): done(message)
                    case .needsMapping: done("Couldn't read that file.")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(useSeparateColumns ? (mapping.moneyIn == nil && mapping.moneyOut == nil) : mapping.amount == nil)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 420)
    }

    private func column(_ title: String, required: Binding<Int>) -> some View {
        Picker(title, selection: required) {
            ForEach(headers.indices, id: \.self) { i in Text(headers[i]).tag(i) }
        }
    }

    private func column(_ title: String, optional: Binding<Int?>) -> some View {
        Picker(title, selection: optional) {
            Text("None").tag(Int?.none)
            ForEach(headers.indices, id: \.self) { i in Text(headers[i]).tag(Int?.some(i)) }
        }
    }
}
