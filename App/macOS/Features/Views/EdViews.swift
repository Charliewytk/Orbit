import AppKit
import SwiftUI
import OrbitCore

/// Ed Discussion activity for the student's modules (opened from Uni).
struct EdView: View {
    @State private var importantOnly = false
    @State private var course: String?
    private var ed: EdService { FeatureHub.shared.ed }

    var body: some View {
        let items = ed.state.items.filter { item in
            (!importantOnly || item.importance.isImportant) && (course == nil || item.courseCode == course)
        }
        Group {
            if !ed.connected {
                ContentUnavailableView {
                    Label("Ed Discussion isn't connected", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Sign in once with your Exeter account. Orbit checks your Ed courses every 30 minutes and tells you about staff posts, announcements and replies.")
                } actions: {
                    Button("Connect Ed Discussion") { Task { await ed.signIn() } }
                        .disabled(ed.signingIn)
                }
            } else if items.isEmpty {
                ContentUnavailableView(ed.syncing ? "Reading Ed…" : "Nothing new on Ed", systemImage: "bubble.left.and.bubble.right",
                                       description: Text(importantOnly ? "No important posts. Turn off “Important” to see everything." : "New threads will show up here."))
            } else {
                List {
                    ForEach(items) { item in
                        EdItemRow(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture { if let url = URL(string: item.url) { NSWorkspace.shared.open(url) } }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if ed.needsSignIn || ed.lastError != nil {
                HStack(spacing: Theme.Space.s) {
                    Label(ed.lastError ?? "Ed needs you to sign in again.", systemImage: "exclamationmark.triangle")
                        .font(Theme.caption).foregroundStyle(Theme.warning)
                    Spacer()
                    if ed.needsSignIn { Button("Sign in again") { Task { await ed.signIn() } } }
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.s)
                .background(.bar)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Course", selection: $course) {
                    Text("All courses").tag(String?.none)
                    ForEach(ed.state.courses) { c in Text(c.moduleCode.map { ModuleLabel.title($0) } ?? c.code).tag(String?.some(c.code)) }
                }
                Toggle(isOn: $importantOnly) { Label("Important", systemImage: "exclamationmark.circle") }
                    .toggleStyle(.button)
                Button { Task { await ed.sync() } } label: { Label("Check Ed now", systemImage: "arrow.clockwise") }
                    .disabled(!ed.connected || ed.syncing)
            }
        }
        .navigationTitle("Ed Discussion")
    }
}

private struct EdItemRow: View {
    let item: EdItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            ModuleDot(code: item.moduleCode)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                HStack(spacing: Theme.Space.xs) {
                    if item.kind == .reply { Text("New reply:").foregroundStyle(Theme.textSecondary) }
                    Text(item.title).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if item.importance.isImportant {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warning)
                            .help(item.importance.reasons.joined(separator: "; "))
                    }
                }
                .font(Theme.body)
                Text(meta).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                if item.kind != .reply && !item.snippet.isEmpty {
                    Text(item.snippet).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.xs)
    }

    private var meta: String {
        var parts = [item.moduleCode ?? item.courseCode]
        if let c = item.category, !c.isEmpty { parts.append(c) }
        if let a = item.author { parts.append(item.authorIsStaff ? "\(a) (staff)" : a) }
        parts.append(Fmt.relative(item.date))
        return parts.joined(separator: " · ")
    }
}

/// Settings → Uni: connect or disconnect Ed.
struct EdConnectRow: View {
    @State private var apiToken = ""
    @State private var checkingToken = false
    private var ed: EdService { FeatureHub.shared.ed }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if ed.connected && !ed.needsSignIn {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right").frame(width: 20).foregroundStyle(Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ed.state.userName.map { "Ed Discussion · \($0)" } ?? "Ed Discussion connected")
                            .font(Theme.body).foregroundStyle(Theme.textPrimary)
                        Text("\(ed.state.courses.count) course\(ed.state.courses.count == 1 ? "" : "s") · checks every 30 minutes"
                             + (ed.state.lastSync.map { " · last \(Fmt.relative($0))" } ?? ""))
                            .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if ed.syncing { ProgressView().controlSize(.small) }
                    Button("Check now") { Task { await ed.sync() } }.disabled(ed.syncing)
                    Button("Disconnect") { ed.disconnect() }
                        .buttonStyle(.borderless).foregroundStyle(Theme.textSecondary)
                }
                Toggle("Summarise long posts with the AI on this Mac", isOn: Binding(
                    get: { FeatureSettings.bool(EdService.summariesKey, default: false) },
                    set: { FeatureSettings.defaults.set($0, forKey: EdService.summariesKey) }))
            } else {
                if ed.needsSignIn {
                    Label("Ed signed you out. Connect again to keep getting updates.", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.callout).foregroundStyle(Theme.warning)
                }
                Button(ed.signingIn ? "Finish signing in in the Ed window…" : "Connect Ed Discussion") {
                    Task { await ed.signIn() }
                }
                .disabled(ed.signingIn)
                EdRegionPicker()
                Text("Opens \(EdWeb.region.webBase.host ?? "edstem.org")\(EdWeb.region.webBase.path) in a window. Sign in with your Exeter account; Orbit keeps Ed's sign-in token in your Keychain and reads your course threads.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                DisclosureGroup("Use an Ed API token instead") {
                    HStack {
                        SecureField("Token from edstem.org/\(EdWeb.region.rawValue)/settings/api-tokens", text: $apiToken)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            checkingToken = true
                            Task {
                                if await ed.useAPIToken(apiToken) { apiToken = "" }
                                checkingToken = false
                            }
                        }
                        .disabled(apiToken.isEmpty || checkingToken)
                    }
                    .padding(.top, 4)
                }
                .font(Theme.caption)
            }
            if let error = ed.lastError, !ed.needsSignIn {
                Text(error).font(Theme.caption).foregroundStyle(Theme.warning)
            }
        }
    }
}

/// Which Ed site to sign in to. Exeter uses the US one; the EU site says
/// "Could not find that account" for Exeter logins.
struct EdRegionPicker: View {
    @AppStorage(EdWeb.regionKey) private var region = EdRegion.default.rawValue

    var body: some View {
        Picker("Ed region", selection: $region) {
            ForEach(EdRegion.allCases) { r in Text(r.label).tag(r.rawValue) }
        }
        .frame(maxWidth: 360)
        .help("Exeter's Ed courses are on the US site.")
    }
}
