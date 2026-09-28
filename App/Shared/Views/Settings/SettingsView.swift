import SwiftUI
import SwiftData
import OrbitCore

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \StoredModule.id) private var modules: [StoredModule]
    @AppStorage("onboardingDone") private var onboardingDone = true
    @State private var prefs = UserPrefs()
    @State private var name = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section("You") {
                TextField("First name", text: $name)
            }

            #if os(macOS)
            MacAccountsSection()
            MacAISection()
            #endif

            PreferencesSections(prefs: $prefs)
            ImportantSendersSection(prefs: $prefs)

            Section {
                Toggle("Local-only mode", isOn: $prefs.localOnlyMode)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Everything goes to Ollama on your Mac; nothing is sent to OpenCode's cloud models. Slower, fully private.")
            }

            if !modules.isEmpty {
                Section {
                    ForEach(modules) { m in
                        Stepper(value: Binding(get: { m.credits }, set: { app.setCredits(m, $0) }), in: 0...60, step: 15) {
                            HStack {
                                ModuleChip(code: m.id)
                                Text(m.name).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                Spacer()
                                Text("\(m.credits) credits").foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                } header: {
                    Text("Module credits")
                } footer: {
                    Text("ELE doesn't publish credits. Most modules are 15; year-long ones are often 30.")
                }
            }

            PhoneLinkSection()

            #if os(macOS)
            MacSystemSection()
            #else
            PhoneSystemSection()
            #endif

            Section {
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
                Button("Show the welcome tour again") { onboardingDone = false }
                LabeledContent("Version", value: AppConfig.appVersion)
                LabeledContent("Storage", value: OrbitStore.mode.rawValue)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .orbitBackground()
        .navigationTitle("Settings")
        .onAppear {
            guard !loaded else { return }
            app.reloadSettings()
            prefs = app.prefs
            name = app.firstName
            loaded = true
        }
        .onChange(of: prefs) { _, new in if loaded { app.savePrefs(new) } }
        .onChange(of: name) { _, new in if loaded { app.setFirstName(new) } }
    }
}

/// Mac address for instant chat from the iPhone (synced, so it can be set on either device).
struct PhoneLinkSection: View {
    @Environment(AppModel.self) private var app
    @State private var address = ""
    @State private var password = ""
    @State private var loaded = false

    var body: some View {
        Section {
            TextField("Mac address, e.g. 100.101.102.103 or my-mac", text: $address)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            SecureField("Password (shown on the Mac)", text: $password)
        } header: {
            Text("iPhone instant chat")
        } footer: {
            Text("Optional. With Tailscale (free) on both devices, your iPhone can talk to your Mac's AI directly instead of waiting for sync. Turn on “Share AI with iPhone” on the Mac first.")
        }
        .onAppear {
            guard !loaded else { return }
            let s = app.context.existingSettings
            address = s?.macAddress ?? ""
            password = s?.macServerPassword ?? ""
            loaded = true
        }
        .onChange(of: address) { _, _ in save() }
        .onChange(of: password) { _, _ in save() }
    }

    private func save() {
        guard loaded else { return }
        let s = app.context.settingsForWriting()
        let a = address.trimmingCharacters(in: .whitespaces)
        s.macAddress = a.isEmpty ? nil : a
        s.macServerPassword = password.isEmpty ? nil : password
        s.updatedAt = Date()
        app.context.saveQuietly()
    }
}

#if os(iOS)
struct PhoneSystemSection: View {
    @State private var notificationsAllowed: Bool?

    var body: some View {
        Section("Notifications") {
            Button("Allow notifications") {
                Task { notificationsAllowed = await Notifier.requestAuthorization() }
            }
            if let allowed = notificationsAllowed {
                Text(allowed ? "Notifications are on." : "Turn notifications on in the Settings app.")
                    .foregroundStyle(allowed ? Theme.success : Theme.warning)
            }
            Button("Open iPhone Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openExternal(url) }
            }
        }
    }
}
#endif

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var app
    @Query private var settings: [StoredSettings]
    @Query private var chat: [StoredChatMessage]

    var body: some View {
        let status = settings.first(where: { $0.syncStatusData != nil })?.syncStatus ?? [:]
        let queued = chat.filter { $0.status == .queued }.count
        Form {
            Section {
                ForEach(SyncSource.allCases) { source in
                    let entry = status[source.rawValue]
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: source.symbol).frame(width: 22).foregroundStyle(Theme.textSecondary)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(source.title).font(Theme.body)
                                Spacer()
                                StatusDot(color: color(entry))
                            }
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
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Sync (reported by your Mac)")
            }

            Section("This device") {
                LabeledContent("Storage", value: OrbitStore.mode.rawValue)
                if let err = OrbitStore.setupError {
                    Text(err).font(Theme.caption).foregroundStyle(Theme.warning).textSelection(.enabled)
                }
                LabeledContent("Chat messages waiting for the Mac", value: "\(queued)")
                LabeledContent("Role", value: app.backend.isBrain ? "Brain (does the work)" : "Remote (asks the Mac)")
            }

            #if os(macOS)
            MacDiagnosticsSection()
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnostics")
    }

    private func color(_ e: SyncStatusEntry?) -> Color {
        guard let e else { return Theme.textTertiary }
        if e.lastError != nil { return e.lastSuccess == nil ? Theme.danger : Theme.warning }
        return e.lastSuccess == nil ? Theme.textTertiary : Theme.success
    }
}
