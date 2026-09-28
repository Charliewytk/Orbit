import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OrbitCore

// MARK: - Account rows (used by Settings and onboarding)

private struct AccountRow<Actions: View>: View {
    var title: String
    var symbol: String
    var connected: Bool
    var detail: String?
    var busy: Bool
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body)
                HStack(spacing: 5) {
                    if connected { StatusDot(color: Theme.success) }
                    Text(detail ?? (connected ? "Connected" : "Not connected"))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            actions
        }
    }
}

/// Status line under a Connect button: progress, then the result or the problem.
private struct ConnectFeedback: View {
    var progress: String?
    var error: String?

    var body: some View {
        if let progress {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(progress).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
        } else if let error {
            Label {
                Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(Theme.caption)
            .foregroundStyle(Theme.danger)
        }
    }
}

struct GoogleConnectRow: View {
    @Environment(OrbitBrain.self) private var brain

    var body: some View {
        let accounts = brain.accounts
        VStack(alignment: .leading, spacing: 6) {
            AccountRow(title: "Google (Gmail + Calendar)", symbol: "envelope.badge", connected: accounts.googleConnected,
                       detail: accounts.googleConnected ? "Connected as \(accounts.googleEmail ?? "your Google account")" : nil,
                       busy: accounts.busy == "google") {
                if accounts.googleConnected {
                    Button("Disconnect") { Task { await accounts.disconnectGoogle() } }
                } else {
                    Button(accounts.busy == "google" ? "Connecting…" : "Connect") {
                        Task { await brain.connectGoogleAndSync() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(accounts.busy != nil)
                }
            }
            ConnectFeedback(progress: accounts.googleProgress, error: accounts.googleError)
            if accounts.googleConnected, brain.running.contains(.calendar) || brain.running.contains(.gmail) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Syncing your mail and calendar…").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

/// Optional Microsoft Graph sign-in. Only shown when this build has a Microsoft client ID.
struct MicrosoftConnectRow: View {
    @Environment(OrbitBrain.self) private var brain

    var body: some View {
        let accounts = brain.accounts
        if accounts.microsoftAvailable {
            VStack(alignment: .leading, spacing: 6) {
                AccountRow(title: "Microsoft sign-in (Exeter, optional)", symbol: "building.columns",
                           connected: accounts.microsoftConnected,
                           detail: accounts.microsoftConnected ? "Connected as \(accounts.microsoftEmail ?? "your Exeter account")" : nil,
                           busy: accounts.busy == "microsoft") {
                    if accounts.microsoftConnected {
                        Button("Disconnect") { Task { await accounts.disconnectMicrosoft() } }
                    } else {
                        Button("Connect") { Task { await brain.connectMicrosoftAndSync() } }
                            .disabled(accounts.busy != nil)
                    }
                }
                ConnectFeedback(progress: accounts.microsoftProgress, error: accounts.microsoftError)
                Text("Only needed for OneNote syncing. Exeter may ask for admin approval; if so, ignore this and use Apple Mail and Calendar.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// "Advanced" disclosure holding the Microsoft sign-in and the Exeter mail source picker.
struct ExeterAdvancedOptions: View {
    @Environment(OrbitBrain.self) private var brain
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Advanced", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                MicrosoftConnectRow()
                ExeterMailSourcePicker()
            }
            .padding(.top, 6)
        }
    }
}

struct ExeterMailSourcePicker: View {
    @Environment(OrbitBrain.self) private var brain
    @AppStorage(MacPrefs.exeterMailSource) private var source = ""

    var body: some View {
        Picker("Read Exeter email from", selection: $source) {
            Text("Automatic").tag("")
            Text("Apple Mail on this Mac").tag("appleMail")
            if brain.accounts.microsoftAvailable {
                Text("Microsoft sign-in").tag("graph")
            }
            Text("Don't read Exeter email").tag("none")
        }
    }
}

/// Plain-English Exeter setup: add the account to the Mac, allow Full Disk
/// Access and Calendars, with live ticks. No Microsoft registration needed.
struct ExeterSetupPanel: View {
    @Environment(OrbitBrain.self) private var brain
    @Environment(\.scenePhase) private var scenePhase
    private var calendars: MacCalendarAccess { .shared }
    private var mail: ExeterMailStatus { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            step(1, "Add your Exeter account to your Mac",
                 "Open Internet Accounts, click Add Account → Microsoft Exchange, and sign in with your @exeter.ac.uk email and password. When it asks which apps to use, tick Mail and Calendars.") {
                Button("Open Internet Accounts") { MacCalendarAccess.openInternetAccounts() }
                    .buttonStyle(.bordered)
            }
            step(2, "Let Orbit read your mail",
                 "Orbit reads Exeter email from the Mail app on this Mac. Click the button, switch Orbit on in the list (use + to add it if it isn't there), then come back. Open the Mail app once so it downloads your mail.") {
                Button("Grant Full Disk Access") { OrbitBrain.openFullDiskAccessSettings() }
                    .buttonStyle(.bordered)
            }
            step(3, "Let Orbit see your calendars",
                 "This brings in your Exeter timetable and any other calendars on this Mac.") {
                if calendars.denied {
                    Button("Open Calendar privacy settings") { MacCalendarAccess.openCalendarPrivacySettings() }
                        .buttonStyle(.bordered)
                } else if !calendars.granted {
                    Button("Allow calendar access") {
                        Task {
                            if await calendars.requestAccess() { await brain.syncCalendar() }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                tick(mail.fullDiskAccess, "Full Disk Access allowed", missing: "Full Disk Access not allowed yet")
                tick(mail.exeterMailFound, "Exeter mail found",
                     missing: mail.fullDiskAccess ? "No Exeter mail in the Mail app yet (open Mail and wait for it to download)" : "Exeter mail not found yet")
                tick(calendars.granted, "Calendar access allowed", missing: "Calendar access not allowed yet")
                tick(calendars.exeterCalendarFound, "Exeter calendar found",
                     missing: calendars.granted ? "No Exeter calendar yet (did you tick Calendars in step 1?)" : "Exeter calendar not found yet")
                if let error = calendars.lastError {
                    Text(error).font(Theme.caption).foregroundStyle(Theme.danger)
                }
            }
            .padding(.leading, 34)

            HStack {
                Button("Check again") { Task { await recheck(sync: true) } }
                if mail.checking { ProgressView().controlSize(.small) }
            }
        }
        .task { await recheck(sync: false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await recheck(sync: false) } }
        }
    }

    private func recheck(sync: Bool) async {
        calendars.refresh()
        await mail.check()
        if sync && (mail.exeterMailFound || calendars.granted) {
            await brain.syncAfterConnecting()
        }
    }

    private func step<Actions: View>(_ number: Int, _ title: String, _ text: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(Theme.body.weight(.medium).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.body.weight(.medium)).foregroundStyle(Theme.textPrimary)
                Text(text).font(Theme.callout).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
        }
    }

    private func tick(_ ok: Bool, _ done: String, missing: String) -> some View {
        Label {
            Text(ok ? done : missing)
        } icon: {
            Image(systemName: ok ? "checkmark.circle" : "circle")
                .foregroundStyle(ok ? Theme.success : Theme.textTertiary)
        }
        .font(Theme.callout)
        .foregroundStyle(ok ? Theme.textPrimary : Theme.textSecondary)
    }
}

/// Calendar permission row for Settings.
struct MacCalendarsRow: View {
    @Environment(OrbitBrain.self) private var brain
    private var calendars: MacCalendarAccess { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AccountRow(title: "Calendars on this Mac", symbol: "calendar", connected: calendars.granted,
                       detail: calendars.granted
                           ? "\(calendars.calendarNames.count) calendars\(calendars.exeterCalendarFound ? " · Exeter found" : "")"
                           : (calendars.denied ? "Not allowed (turn on in System Settings)" : "Not allowed yet"),
                       busy: false) {
                if calendars.denied {
                    Button("Open Settings") { MacCalendarAccess.openCalendarPrivacySettings() }
                } else if !calendars.granted {
                    Button("Allow") {
                        Task { if await calendars.requestAccess() { await brain.syncCalendar() } }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if let error = calendars.lastError {
                Text(error).font(Theme.caption).foregroundStyle(Theme.danger)
            }
        }
        .onAppear { calendars.refresh() }
    }
}

struct ELEConnectRow: View {
    @Environment(OrbitBrain.self) private var brain
    @AppStorage(MacPrefs.eleCalendarURL) private var calendarURL = ""

    var body: some View {
        let accounts = brain.accounts
        let syncing = brain.running.contains(.ele)
        VStack(alignment: .leading, spacing: 10) {
            if accounts.busy == "ele" {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in the ELE window (Exeter Microsoft sign-in and MFA)…")
                        .font(Theme.callout).foregroundStyle(Theme.textSecondary)
                }
            } else if !accounts.eleConnected || accounts.eleNeedsSignIn {
                if accounts.eleNeedsSignIn {
                    Label("ELE signed you out. Sign in again to keep your modules and deadlines up to date.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.callout).foregroundStyle(Theme.warning)
                }
                Button {
                    Task { if await accounts.connectELE() { await brain.syncELE() } }
                } label: {
                    Text(accounts.eleNeedsSignIn ? "Sign in to ELE again" : "Sign in to ELE")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("Opens ele.exeter.ac.uk in a window. Sign in as usual; Orbit stays signed in and reads your modules, weeks, readings and assessments like your browser does.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "graduationcap").frame(width: 20).foregroundStyle(Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(syncing ? "Reading ELE…" : (accounts.eleSummary ?? "Signed in to ELE"))
                            .font(Theme.body).foregroundStyle(Theme.textPrimary)
                        Text(accounts.eleWebSignedIn ? "ele.exeter.ac.uk · syncs every hour" : "Signed in with the Moodle app method")
                            .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if syncing { ProgressView().controlSize(.small) }
                    Button("Sync now") { Task { await brain.syncELE() } }
                        .disabled(syncing)
                    Button("Sign out") { accounts.disconnectELE() }
                        .buttonStyle(.borderless).foregroundStyle(Theme.textSecondary)
                }
            }
            if !accounts.eleConnected {
                TextField("Or paste your ELE calendar export link (ELE → Calendar → Export calendar)", text: $calendarURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await brain.syncELE() } }
            }
            if let error = accounts.lastError, error.contains("ELE") {
                Text(error).font(Theme.caption).foregroundStyle(Theme.warning)
            }
        }
    }
}

struct NotesSourcePicker: View {
    @Environment(OrbitBrain.self) private var brain
    @AppStorage(MacPrefs.noteSource) private var source = ""
    @AppStorage(MacPrefs.notesFolderPath) private var folderPath = ""
    @AppStorage(MacPrefs.typedNotesRoot) private var typedRoot = ""
    @State private var choosing = false
    @State private var choosingTyped = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if brain.accounts.microsoftAvailable {
                Picker("Read notes from", selection: $source) {
                    Text("Automatic").tag("")
                    Text("OneNote (Microsoft sign-in)").tag("graph")
                    Text("My notes folder (PDFs)").tag("folder")
                    Text("Don't read notes").tag("none")
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notes folder").font(Theme.body.weight(.medium))
                    Text(folderPath.isEmpty ? "No folder picked yet" : folderPath)
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button(folderPath.isEmpty ? "Pick your notes folder…" : "Change…") { choosing = true }
            }
            Text("Your Notability auto-backup: Google Drive → My Drive → Notability (found automatically with Google Drive for Mac, or synced from Drive in Notes). Orbit reads typed text and your handwriting, and notices new files by itself.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Typed notes folder").font(Theme.body.weight(.medium))
                    Text(typedRoot.isEmpty ? TypedNotesStore.defaultRoot().path : typedRoot)
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if !typedRoot.isEmpty {
                    Button("Use default") { typedRoot = ""; Task { await brain.refreshLibrary() } }
                }
                Button("Change…") { choosingTyped = true }
            }
            Text("Notes you type in Orbit are rich-text notes here, one folder per subject (Introduction to Statistics/Week 1.rtfd), with pasted images kept inside each note.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Read notes now") { Task { await brain.syncNotes() } }
                    .disabled(brain.running.contains(.notes))
                if brain.running.contains(.notes) { ProgressView().controlSize(.small); Text("Reading…").font(Theme.caption) }
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                folderPath = url.path
                if source.isEmpty || !brain.accounts.microsoftAvailable { source = "folder" }
                OrbitLog.log("notes", "Notes folder picked: \(url.path)")
                Task { await brain.syncNotes() }
            }
        }
        .background {
            // A second importer on the same view is ignored by SwiftUI; hang it on a background view.
            Color.clear.fileImporter(isPresented: $choosingTyped, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    typedRoot = url.path
                    Task { await brain.syncNotes() }
                }
            }
        }
    }
}

struct IMessageToggle: View {
    @Environment(OrbitBrain.self) private var brain
    @AppStorage(MacPrefs.iMessageEnabled) private var enabled = false

    var body: some View {
        HStack {
            Toggle("Watch iMessage for plans", isOn: $enabled)
                .onChange(of: enabled) { _, on in if on { Task { await brain.syncIMessage() } } }
            Spacer()
            Button("Full Disk Access…") { OrbitBrain.openFullDiskAccessSettings() }
                .buttonStyle(.link)
                .font(Theme.caption)
        }
    }
}

// MARK: - CleanAPIs cloud brain

struct CleanAPIsStatusPanel: View {
    @Environment(OrbitBrain.self) private var brain
    @AppStorage(MacPrefs.cleanapisEnabled) private var enabled = true
    @AppStorage(MacPrefs.cleanapisModel) private var model = "claude-opus-5.5"
    @AppStorage(MacPrefs.cleanapisKey) private var storedKey = ""
    @State private var showKey = false
    @State private var checking = false
    @State private var reachable: Bool?
    @State private var keyPreview: String?

    var resolvedKey: String? {
        let t = storedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return CleanAPIsProvider.keyFromAuthFile()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                StatusDot(color: (reachable == true) ? Theme.success : (reachable == false ? Theme.danger : Theme.textSecondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text("CleanAPIs (cloud brain)").font(Theme.body.weight(.medium))
                    Text(statusLine).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                Spacer()
                Toggle("Enabled", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in brain.rebuildRouter(); Task { await check() } }
            }
            if enabled {
                Picker("Model", selection: $model) {
                    Text("claude-opus-5.5").tag("claude-opus-5.5")
                    Text("claude-sonnet-4.5").tag("claude-sonnet-4.5")
                    Text("deepseek-v4").tag("deepseek-v4")
                }
                .onChange(of: model) { _, _ in brain.rebuildRouter() }
                .disabled(checking)

                HStack(spacing: 8) {
                    Group {
                        if showKey { TextField("cc_…", text: $storedKey).textFieldStyle(.roundedBorder) }
                        else { SecureField("API key (or leave empty to use ~/.local/share/opencode/auth.json)", text: $storedKey).textFieldStyle(.roundedBorder) }
                    }
                    Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                    Button("Paste") {
                        if let s = NSPasteboard.general.string(forType: .string) { storedKey = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                }
                .onChange(of: storedKey) { _, _ in brain.rebuildRouter(); Task { await check() } }

                if let kp = keyPreview {
                    Text("Key: \(kp) · from \(storedKey.isEmpty ? "~/.local/share/opencode/auth.json" : "Settings")")
                        .font(.caption2).foregroundStyle(Theme.textTertiary).textSelection(.enabled)
                } else if resolvedKey == nil {
                    Text("No key found. Add one above, or run `opencode auth` / put it in ~/.local/share/opencode/auth.json under \"cleanapis\".")
                        .font(Theme.caption).foregroundStyle(Theme.warning)
                }
                Text("Private data (full email, full notes, handwriting) never leaves your Mac — only summaries go to CleanAPIs. Bulk & vision stay local.")
                    .font(.caption2).foregroundStyle(Theme.textTertiary)
                HStack {
                    Button(checking ? "Checking…" : "Test") { Task { await check() } }.disabled(checking)
                    if checking { ProgressView().controlSize(.small) }
                    if let r = reachable { Text(r ? "Reachable ✓" : "Not reachable").font(Theme.caption).foregroundStyle(r ? Theme.success : Theme.danger) }
                }
            }
        }
        .task { await check() }
    }

    var statusLine: String {
        if !enabled { return "Off — chat uses OpenCode → Ollama." }
        if checking { return "Checking…" }
        if let r = reachable { return r ? "Online · \(model) · chat & reasoning use cloud first, fallback to local" : "Key or network issue — will fall back to OpenCode/Ollama" }
        return "\(model) · checking…"
    }

    func check() async {
        checking = true; defer { checking = false }
        let base: URL = {
            if let s = MacPrefs.string(MacPrefs.cleanapisBaseURL), let u = URL(string: s) { return u }
            return URL(string: "https://cleanapis.com/v1")!
        }()
        let p = CleanAPIsProvider(baseURL: base, model: model, apiKey: storedKey.isEmpty ? nil : storedKey)
        keyPreview = p.keyPreview
        reachable = await p.isAvailable()
        brain.rebuildRouter()
    }
}

// MARK: - AI

struct AIStatusPanel: View {
    @Environment(OrbitBrain.self) private var brain
    @AppStorage(MacPrefs.openCodeModel) private var openCodeModel = ""
    @AppStorage(MacPrefs.openCodeVariant) private var openCodeVariant = OpenCodeModelResolver.preferredVariant
    struct ModelOption: Identifiable, Hashable {
        var id: String
        var name: String
        var free: Bool
        var variants: [String] = []
    }

    @State private var models: [ModelOption] = []
    @State private var loadingModels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                StatusDot(color: brain.openCodeUp ? Theme.success : Theme.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenCode").font(Theme.body.weight(.medium))
                    Text(brain.launcher.status.label + (brain.launcher.binaryPath.map { " · \($0)" } ?? ""))
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Restart") { Task { await brain.launcher.restart(); await brain.checkAI() } }
            }
            if brain.launcher.status == .notInstalled {
                Text("Install OpenCode (opencode.ai), then press Restart. Orbit will run `opencode serve` for you.")
                    .font(Theme.caption).foregroundStyle(Theme.warning)
            }
            if !models.isEmpty || loadingModels {
                Picker("OpenCode model", selection: $openCodeModel) {
                    Text("Automatic (\(OpenCodeModelResolver.preferredName))").tag("")
                    ForEach(models) { m in
                        Text("\(m.name)\(m.free ? " · free" : "")").tag(m.id)
                    }
                }
                .onChange(of: openCodeModel) { _, _ in applyModelChoice() }
                Picker("Reasoning effort", selection: $openCodeVariant) {
                    ForEach(variantChoices, id: \.self) { v in
                        Text(v == "none" ? "Model default" : v).tag(v)
                    }
                }
                .onChange(of: openCodeVariant) { _, _ in applyModelChoice() }
            }

            Divider()

            HStack(spacing: 12) {
                StatusDot(color: brain.ollama.available ? Theme.success : Theme.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ollama (offline backup)").font(Theme.body.weight(.medium))
                    Text(brain.ollama.available ? "\(brain.ollama.installed.count) models installed" : "Not running. Install from ollama.com and open it.")
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            ForEach(OllamaManager.recommended) { item in
                HStack {
                    Image(systemName: brain.ollama.isInstalled(item.model) ? "checkmark.circle" : "arrow.down.circle")
                        .foregroundStyle(brain.ollama.isInstalled(item.model) ? Theme.success : Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.model).font(Theme.mono)
                        Text(item.why).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    if brain.ollama.pulling.contains(item.model) {
                        ProgressView().controlSize(.small)
                        Text("Downloading…").font(Theme.caption)
                    } else if !brain.ollama.isInstalled(item.model) {
                        Button("Download") { Task { await brain.ollama.pull(item.model) } }
                            .disabled(!brain.ollama.available)
                    }
                }
            }
            if let error = brain.ollama.lastError {
                Text(error).font(Theme.caption).foregroundStyle(Theme.danger)
            }
        }
        .task { await loadModels() }
    }

    /// Variants the selected model offers (or the usual ones when OpenCode doesn't list them).
    private var variantChoices: [String] {
        let id = openCodeModel.isEmpty ? (MacPrefs.string(MacPrefs.openCodeResolvedModel) ?? "") : openCodeModel
        let listed = models.first { $0.id == id }?.variants ?? []
        var out = listed.isEmpty ? ["low", "medium", "high", "xhigh"] : listed
        if !out.contains(openCodeVariant) && openCodeVariant != "none" { out.append(openCodeVariant) }
        return out + ["none"]
    }

    private func applyModelChoice() {
        Task {
            await brain.resolveOpenCodeModel()
            brain.rebuildRouter()
        }
    }

    private func loadModels() async {
        loadingModels = true
        defer { loadingModels = false }
        await brain.checkAI()
        guard brain.openCodeUp else { return }
        let list = (try? await brain.launcher.provider(model: nil).modelOptions()) ?? []
        models = list.map { ModelOption(id: $0.ref.string, name: "\($0.ref.providerID)/\($0.name)", free: $0.free, variants: $0.variants) }
    }
}

// MARK: - Settings sections

struct MacAccountsSection: View {
    @Environment(OrbitBrain.self) private var brain
    @AppStorage(MacPrefs.timetableURL) private var timetableURL = ""
    @AppStorage(MacPrefs.useExeterCalendar) private var useExeterCalendar = true

    var body: some View {
        Section {
            GoogleConnectRow()
            MacCalendarsRow()
            ELEConnectRow()
            TextField("Timetable calendar link (optional .ics)", text: $timetableURL)
                .textFieldStyle(.roundedBorder)
        } header: {
            Text("Accounts")
        } footer: {
            Text("Orbit writes only to its own “Orbit” calendar and saves email replies as drafts. It never sends email or edits your own events.")
        }
        .task { await brain.accounts.refreshStatus() }

        Section {
            GoodNotesFolderPicker()
            DisclosureGroup("Other sources (OneNote, any PDF folder)") {
                NotesSourcePicker().padding(.top, 6)
            }
        } header: {
            Text("Lecture notes")
        }

        Section {
            DisclosureGroup("Set up Exeter email and calendar") {
                ExeterSetupPanel().padding(.vertical, 6)
            }
            ExeterAdvancedOptions()
            if brain.accounts.microsoftConnected {
                Toggle("Use the Microsoft sign-in for my Exeter calendar", isOn: $useExeterCalendar)
            }
        } header: {
            Text("University of Exeter")
        }
    }
}

struct MacAISection: View {
    @Environment(OrbitBrain.self) private var brain
    @AppStorage(MacPrefs.shareAIWithPhone) private var share = false

    var body: some View {
        Section {
            CleanAPIsStatusPanel()
            Divider()
            AIStatusPanel()
            Toggle("Share AI with iPhone (Tailscale / home Wi-Fi)", isOn: $share)
                .onChange(of: share) { _, _ in
                    brain.configureAISharing()
                    Task { await brain.checkAI() }
                }
            if share, let password = brain.context.existingSettings?.macServerPassword {
                LabeledContent("iPhone password", value: password)
                    .textSelection(.enabled)
                Text("On the iPhone: Settings → iPhone instant chat → enter this Mac's Tailscale address and this password. For Ollama too, run `launchctl setenv OLLAMA_HOST 0.0.0.0` and restart Ollama.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
        } header: {
            Text("AI")
        } footer: {
            Text("Chat & reasoning prefer CleanAPIs (cloud) when enabled, then OpenCode, then Ollama. Bulk, vision & private data stay on this Mac. Toggle CleanAPIs off for fully offline — nothing breaks.")
        }
    }
}

struct MacSystemSection: View {
    @Environment(OrbitBrain.self) private var brain
    @State private var loginItem = false

    var body: some View {
        Section("Mac") {
            Toggle("Open Orbit when I log in", isOn: $loginItem)
                .onChange(of: loginItem) { _, on in
                    if on != brain.launchesAtLogin { brain.setLaunchAtLogin(on) }
                }
            IMessageToggle()
            HStack {
                Text("Full Disk Access lets Orbit read Apple Mail and Messages.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Open Full Disk Access") { OrbitBrain.openFullDiskAccessSettings() }
            }
            HStack {
                Button("Sync everything now") { Task { await brain.syncNow() } }
                Button("Morning brief now") { Task { await brain.generateMorningBrief() } }
                Button("Weekly review now") { Task { await brain.generateWeeklyReview() } }
            }
            Button("Show Orbit's files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([brain.local.root]) }
        }
        .onAppear { loginItem = brain.launchesAtLogin }
    }
}

struct MacDiagnosticsSection: View {
    @Environment(OrbitBrain.self) private var brain
    @State private var copied = false

    var body: some View {
        Section {
            HStack {
                Button("Reveal log in Finder") {
                    OrbitLog.log("diagnostics", "Log revealed in Finder")
                    let url = OrbitLog.fileURL
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.open(url.deletingLastPathComponent())
                    }
                }
                Button(copied ? "Copied" : "Copy log") {
                    let text = OrbitLog.contents()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text.isEmpty ? "(The Orbit log is empty.)" : text, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
            }
            Text("If something doesn't work, click Copy log and paste it to us. It lists what Orbit tried and any errors; it never contains passwords.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
        } header: {
            Text("Orbit log")
        }

        Section("AI on this Mac") {
            LabeledContent("OpenCode", value: brain.launcher.status.label)
            LabeledContent("Ollama", value: brain.ollama.available ? "Running" : "Not running")
            LabeledContent("Last answer from", value: brain.lastProviderName ?? "–")
            LabeledContent("Indexed notes", value: "\(brain.noteIndex.noteIDs.count)")
            LabeledContent("Handwriting pages learned", value: "\(brain.handwritingProfile.pagesLearned)")
            DisclosureGroup("OpenCode log") {
                ScrollView {
                    Text(brain.launcher.logTail())
                        .font(Theme.mono)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 180)
            }
        }
    }
}

/// Bottom of the sidebar: what the brain is doing.
struct BrainStatusFooter: View {
    @Environment(OrbitBrain.self) private var brain

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: brain.openCodeUp || brain.ollama.available ? Theme.success : Theme.danger)
            if let source = brain.running.first {
                ProgressView().controlSize(.mini)
                Text("Syncing \(source.title.lowercased())…")
            } else {
                Text(brain.openCodeUp ? "OpenCode ready" : brain.ollama.available ? "Ollama ready" : "Assistant offline")
            }
            Spacer()
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.textSecondary)
    }
}
