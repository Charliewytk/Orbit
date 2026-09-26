import SwiftUI
import SwiftData
import OrbitCore

/// The Mac's native Settings window (⌘,): tabs of grouped forms.
struct MacSettingsView: View {
    enum Tab: String, Hashable { case general, accounts, ai, uni, routine, extras, money, health, backups, advanced }
    /// UserDefaults key for the selected tab (other screens set it to open Settings on a tab).
    static let tabKey = "settings.tab"
    @AppStorage(MacSettingsView.tabKey) private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            AccountsSettingsTab()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(Tab.accounts)
            AISettingsTab()
                .tabItem { Label("Assistant", systemImage: "bubble.left.and.text.bubble.right") }
                .tag(Tab.ai)
            UniSettingsTab()
                .tabItem { Label("Uni", systemImage: "graduationcap") }
                .tag(Tab.uni)
            RoutineSettingsTab()
                .tabItem { Label("Routine", systemImage: "fork.knife") }
                .tag(Tab.routine)
            FeatureSettingsView()
                .tabItem { Label("Extras", systemImage: "puzzlepiece.extension") }
                .tag(Tab.extras)
            MoneySettingsView()
                .tabItem { Label("Money", systemImage: "sterlingsign.circle") }
                .tag(Tab.money)
            HealthSettingsTab()
                .tabItem { Label("Health", systemImage: "stethoscope") }
                .tag(Tab.health)
            BackupSettingsTab()
                .tabItem { Label("Backups", systemImage: "externaldrive.badge.timemachine") }
                .tag(Tab.backups)
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag(Tab.advanced)
        }
        .frame(width: 720, height: 680)
        .tint(Theme.accent)
    }
}

/// Loads the synced preferences once and saves every change.
private struct PrefsEditor<Content: View>: View {
    @Environment(AppModel.self) private var app
    @ViewBuilder var content: (Binding<UserPrefs>) -> Content
    @State private var prefs = UserPrefs()
    @State private var loaded = false

    var body: some View {
        content($prefs)
            .onAppear {
                // Reload every time a tab appears, so tabs never save stale copies.
                app.reloadSettings()
                prefs = app.prefs
                loaded = true
            }
            .onChange(of: prefs) { _, new in if loaded { app.savePrefs(new) } }
    }
}

private struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @AppStorage("onboardingDone") private var onboardingDone = false
    @State private var name = ""
    @State private var loaded = false

    var body: some View {
        PrefsEditor { prefs in
            Form {
                Section("You") {
                    TextField("First name", text: $name)
                    Button("Run setup again…") {
                        onboardingDone = false
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                Section {
                    OnboardingGoals()
                } header: {
                    Text("Daily goals")
                } footer: {
                    Text("The three rings on Home: study minutes, to-dos done and flashcard reviews.")
                }
                PreferencesSections(prefs: prefs)
                Section {
                    Toggle("Local-only mode", isOn: prefs.localOnlyMode)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Everything goes to Ollama on this Mac; nothing is sent to OpenCode's cloud models. Slower, fully private.")
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            guard !loaded else { return }
            name = app.firstName
            loaded = true
        }
        .onChange(of: name) { _, new in if loaded { app.setFirstName(new) } }
    }
}

private struct AccountsSettingsTab: View {
    var body: some View {
        PrefsEditor { prefs in
            Form {
                MacAccountsSection()
                ImportantSendersSection(prefs: prefs)
            }
            .formStyle(.grouped)
        }
    }
}

private struct AISettingsTab: View {
    var body: some View {
        Form {
            MacAISection()
            PhoneLinkSection()
        }
        .formStyle(.grouped)
    }
}

private struct UniSettingsTab: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \StoredModule.id) private var modules: [StoredModule]

    var body: some View {
        Form {
            Section {
                if modules.isEmpty {
                    Text("Modules appear here after the first ELE sync.")
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(modules) { m in
                    Stepper(value: Binding(get: { m.credits }, set: { app.setCredits(m, $0) }), in: 0...60, step: 15) {
                        HStack(spacing: Theme.Space.s) {
                            ModuleDot(code: m.id)
                            Text(m.id).monospacedDigit()
                            Text(m.name).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            Spacer()
                            Text("\(m.credits) credits").foregroundStyle(Theme.textSecondary).monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("Module credits")
            } footer: {
                Text("ELE doesn't publish credits. Most modules are 15; year-long ones are often 30.")
            }

            Section {
                EdConnectRow()
            } header: {
                Text("Ed Discussion")
            } footer: {
                Text("Staff posts, announcements and replies to your threads on edstem.org, checked every 30 minutes.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettingsTab: View {
    @Environment(AppModel.self) private var app
    @AppStorage("onboardingDone") private var onboardingDone = true
    @Query private var settings: [StoredSettings]

    var body: some View {
        let status = settings.first(where: { $0.syncStatusData != nil })?.syncStatus ?? [:]
        Form {
            MacSystemSection()

            Section("Sync") {
                ForEach(SyncSource.allCases) { source in
                    SyncStatusRow(source: source, entry: status[source.rawValue])
                }
            }

            MacDiagnosticsSection()

            Section {
                LabeledContent("Version", value: AppConfig.appVersion)
                LabeledContent("Storage", value: OrbitStore.mode.rawValue)
                if let err = OrbitStore.setupError {
                    Text(err).font(Theme.caption).foregroundStyle(Theme.warning).textSelection(.enabled)
                }
                Button("Show the welcome tour again") { onboardingDone = false }
            }
        }
        .formStyle(.grouped)
    }
}

/// One sync source: name, last result and any error.
struct SyncStatusRow: View {
    var source: SyncSource
    var entry: SyncStatusEntry?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            StatusDot(color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title).font(Theme.body)
                if let ok = entry?.lastSuccess {
                    Text("Last OK \(ok.formatted(date: .abbreviated, time: .shortened))" + (entry?.detail.map { " · \($0)" } ?? ""))
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    Text(entry?.lastAttempt == nil ? "Not run yet" : "Never succeeded")
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
                if let err = entry?.lastError {
                    Text(err).font(Theme.caption).foregroundStyle(Theme.danger).textSelection(.enabled)
                }
            }
        }
    }

    private var color: Color {
        guard let e = entry else { return Theme.textTertiary }
        if e.lastError != nil { return e.lastSuccess == nil ? Theme.danger : Theme.warning }
        return e.lastSuccess == nil ? Theme.textTertiary : Theme.success
    }
}
