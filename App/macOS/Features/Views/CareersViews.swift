import AppKit
import SwiftUI
import OrbitCore

/// Careers: finance programmes from Trackr, with a watchlist and "when things drop" alerts.
struct CareersView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case open = "Open now", soon = "Opening soon", watchlist = "Watchlist", all = "All"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .open
    @State private var search = ""
    @State private var category: OpportunityCategory?
    @State private var selection: Opportunity.ID?
    @State private var showInspector = false
    @State private var showSettings = false
    private var careers: CareersService { FeatureHub.shared.careers }

    var body: some View {
        let rows = visibleRows
        Group {
            if careers.opportunities.isEmpty {
                ContentUnavailableView {
                    Label(careers.syncing ? "Reading Trackr…" : "No programmes yet", systemImage: "briefcase")
                } description: {
                    Text("Orbit checks Trackr's UK finance lists every two hours and tells you when spring weeks and internships open.")
                } actions: {
                    Button("Check now") { Task { await careers.sync() } }
                        .disabled(careers.syncing)
                }
            } else if rows.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "briefcase", description: Text(emptyMessage))
            } else {
                table(rows)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .searchable(text: $search, prompt: "Company, programme or test")
        .toolbar {
            ToolbarItemGroup {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Type", selection: $category) {
                    Text("All types").tag(OpportunityCategory?.none)
                    ForEach(OpportunityCategory.allCases) { Text($0.label).tag(OpportunityCategory?.some($0)) }
                }
                Button { Task { await careers.sync() } } label: { Label("Check Trackr now", systemImage: "arrow.clockwise") }
                    .disabled(careers.syncing)
                Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.trailing") }
                Button { showSettings = true } label: { Label("Careers settings", systemImage: "gearshape") }
            }
        }
        .inspector(isPresented: $showInspector) {
            Group {
                if let id = selection, let o = careers.opportunities.first(where: { $0.id == id }) {
                    OpportunityDetail(opportunity: o)
                } else {
                    ContentUnavailableView("Select a programme", systemImage: "briefcase")
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
        }
        .onChange(of: selection) { _, new in if new != nil { showInspector = true } }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                CareersSettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
            }
            .frame(minWidth: 480, minHeight: 520)
        }
        .navigationTitle("Careers")
    }

    private var visibleRows: [Opportunity] {
        let t = careers.tracker
        var list: [Opportunity]
        switch tab {
        case .open: list = t.openNow(careers.opportunities)
        case .soon: list = t.openingSoon(careers.opportunities, withinDays: 60)
        case .watchlist:
            list = careers.opportunities.filter { careers.preferences.isWatched($0) && !$0.isClosed(now: t.now) }
                .sorted { (t.expectedOpening($0)?.date ?? .distantFuture) < (t.expectedOpening($1)?.date ?? .distantFuture) }
        case .all: list = careers.opportunities.sorted { ($0.company, $0.programme) < ($1.company, $1.programme) }
        }
        if let category { list = list.filter { $0.category == category } }
        if !search.isEmpty { list = t.search(list, query: search) }
        return list
    }

    private var emptyTitle: String {
        switch tab {
        case .open: "Nothing open right now"
        case .soon: "Nothing expected soon"
        case .watchlist: "Your watchlist is empty"
        case .all: "No matches"
        }
    }

    private var emptyMessage: String {
        switch tab {
        case .watchlist: "Star programmes or companies, or turn on “Watch all spring weeks” in Careers settings."
        default: search.isEmpty ? "Orbit will tell you when something opens." : "Try another search."
        }
    }

    private func table(_ rows: [Opportunity]) -> some View {
        let t = careers.tracker
        let prefs = careers.preferences
        return Table(rows, selection: $selection) {
            TableColumn("") { o in
                Button { careers.toggleStar(o) } label: {
                    Image(systemName: prefs.isStarred(o) ? "star.fill" : "star")
                        .foregroundStyle(prefs.isStarred(o) ? Theme.accent : Theme.textTertiary)
                }
                .buttonStyle(.borderless)
                .help(prefs.isStarred(o) ? "Unstar" : "Star: notify me when it opens")
            }
            .width(22)
            TableColumn("Company") { o in
                Text(o.company).foregroundStyle(Theme.textPrimary)
            }
            .width(min: 110, ideal: 140)
            TableColumn("Programme") { o in
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.programme).lineLimit(1)
                    if let e = o.eligibility {
                        Text(e).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .width(min: 180, ideal: 260)
            TableColumn("Opens") { o in
                if let e = t.expectedOpening(o) {
                    Text(e.predicted ? "~\(CareersDay.short(e.date))" : CareersDay.short(e.date))
                        .monospacedDigit()
                        .foregroundStyle(e.predicted ? Theme.textTertiary : (o.isOpen(now: t.now) ? Theme.success : Theme.textPrimary))
                        .help(e.predicted ? "Predicted from last year's opening" : "")
                } else {
                    Text("—").foregroundStyle(Theme.textTertiary)
                }
            }
            .width(min: 70, ideal: 80)
            TableColumn("Closes") { o in
                if let c = o.closingDate {
                    let days = o.daysToClose(now: t.now) ?? 99
                    Text(CareersDay.short(c)).monospacedDigit()
                        .foregroundStyle(o.isOpen(now: t.now) && days <= 7 ? Theme.danger : Theme.textPrimary)
                } else {
                    Text(o.rolling ? "Rolling" : "—").foregroundStyle(Theme.textTertiary)
                }
            }
            .width(min: 70, ideal: 80)
            TableColumn("Stage") { o in
                Text(o.latestStage ?? "").foregroundStyle(Theme.textSecondary)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Process") { o in
                Text(CareersPrep.testName(o) ?? o.process.joined(separator: ", ")).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .width(min: 70, ideal: 110)
            TableColumn("Acceptance") { o in
                Text(o.acceptanceRate ?? "").monospacedDigit().foregroundStyle(Theme.textSecondary)
            }
            .width(min: 70, ideal: 110)
        }
        .contextMenu(forSelectionType: Opportunity.ID.self) { ids in
            if let id = ids.first, let o = careers.opportunities.first(where: { $0.id == id }) {
                Button(prefs.isStarred(o) ? "Unstar" : "Star") { careers.toggleStar(o) }
                Button(prefs.starredCompanies.contains(o.company.lowercased()) ? "Stop watching \(o.company)" : "Watch everything from \(o.company)") {
                    careers.toggleCompanyStar(o.company)
                }
                Button(prefs.muted.contains(o.id) ? "Unmute" : "Mute") { careers.toggleMute(o) }
                Divider()
                Button("Add “Apply” to-do") { careers.addApplyTask(o) }
                if let url = o.url.flatMap(URL.init(string:)) {
                    Button("Open application page") { NSWorkspace.shared.open(url) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let o = careers.opportunities.first(where: { $0.id == id }),
               let url = o.url.flatMap(URL.init(string:)) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            if careers.syncing { ProgressView().controlSize(.small) }
            Text(footerText).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Spacer()
            Link("Data from Trackr", destination: (category ?? .springWeeks).pageURL)
                .font(Theme.caption)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .background(.bar)
    }

    private var footerText: String {
        if !careers.status.isEmpty { return careers.status }
        guard let last = careers.lastSync else { return "Not checked yet" }
        return "\(careers.opportunities.count) programmes · checked \(Fmt.relative(last)) · every 2 hours"
    }
}

/// The inspector: everything Trackr knows, plus notes and actions.
private struct OpportunityDetail: View {
    let opportunity: Opportunity
    private var careers: CareersService { FeatureHub.shared.careers }

    var body: some View {
        let o = opportunity
        let t = careers.tracker
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(o.company).font(Theme.title(Theme.Size.title3))
                    Text(o.programme).font(Theme.body).foregroundStyle(Theme.textSecondary)
                    Text(o.category.label + (o.sectors.isEmpty ? "" : " · " + o.sectors.joined(separator: ", ")))
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }

                HStack(spacing: Theme.Space.s) {
                    if let url = o.url.flatMap(URL.init(string:)) {
                        Button("Open application page") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button { careers.toggleStar(o) } label: {
                        Label(careers.preferences.isStarred(o) ? "Starred" : "Star",
                              systemImage: careers.preferences.isStarred(o) ? "star.fill" : "star")
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
                    row("Status", status(o, t))
                    if let e = o.eligibility { row("Eligibility", e) }
                    if let d = o.openingDate { row("Opens", CareersDay.short(d)) }
                    if let d = o.closingDate { row("Closes", CareersDay.short(d)) }
                    row("Rolling", o.rolling ? "Yes — apply early" : "No")
                    if let d = o.lastYearOpening { row("Last year", "opened \(CareersDay.short(d))") }
                    if let s = o.latestStage { row("Latest stage", s) }
                    if !o.process.isEmpty { row("Process", o.process.joined(separator: " → ")) }
                    if let a = o.acceptanceRate { row("Acceptance", a) }
                    if let c = o.conversionRate { row("Conversion", c) }
                }

                if let test = CareersPrep.testName(o) {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("Test: \(test)").font(Theme.headline)
                        Text(CareersPrep.suggestion(for: test)).font(Theme.body).foregroundStyle(Theme.textSecondary)
                    }
                }

                if let notes = o.notes {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("Notes").font(Theme.headline)
                        Text(notes).font(Theme.body).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    }
                }

                if careers.hasApplyTask(o) {
                    Label("“Apply” to-do added", systemImage: "checkmark.circle").font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else if o.isOpen(now: t.now) {
                    Button("Add “Apply” to-do") { careers.addApplyTask(o) }
                }
                if !careers.preferences.isEligible(o) {
                    Text("Hidden from your watchlist: limited to groups you haven't selected in Careers settings.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.l)
        }
    }

    private func status(_ o: Opportunity, _ t: CareersTracker) -> String {
        if o.isOpen(now: t.now) {
            if let d = o.daysToClose(now: t.now) { return d == 0 ? "Open — closes today" : "Open — \(d) days left" }
            return "Open"
        }
        if o.isClosed(now: t.now) { return "Closed" }
        if let e = t.expectedOpening(o) {
            return e.predicted ? "Expected around \(CareersDay.short(e.date))" : "Opens \(CareersDay.short(e.date))"
        }
        return "Not open yet"
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(Theme.caption).foregroundStyle(Theme.textTertiary).gridColumnAlignment(.leading)
            Text(value).font(Theme.body).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
        }
    }
}

/// Eligibility, watchlist and alert settings.
struct CareersSettingsView: View {
    private var careers: CareersService { FeatureHub.shared.careers }

    var body: some View {
        let prefs = careers.preferences
        Form {
            Section {
                Toggle("Check Trackr every 2 hours", isOn: Binding(get: { careers.enabled }, set: { careers.enabled = $0 }))
                Toggle("Notify me when watched programmes open or close soon",
                       isOn: binding(\.notificationsEnabled))
                Toggle("Add an “Apply” to-do when a watched programme opens", isOn: binding(\.createApplyTasks))
            } header: {
                Text("Alerts")
            }

            Section {
                Stepper("Year of study: \(prefs.yearOfStudy)", value: binding(\.yearOfStudy), in: 1...4)
                Toggle("Watch every spring week I'm eligible for", isOn: binding(\.watchAllSpringWeeks))
                ForEach(OpportunityCategory.allCases) { c in
                    Toggle(c.label, isOn: Binding(
                        get: { careers.preferences.categories.contains(c) },
                        set: { on in careers.updatePreferences { if on { $0.categories.insert(c) } else { $0.categories.remove(c) } } }))
                }
            } header: {
                Text("What to track")
            } footer: {
                Text("UK finance lists. Spring weeks are for first years; star anything else you want alerts for.")
            }

            Section {
                ForEach(DiversityGroup.allCases) { g in
                    Toggle(g.label, isOn: Binding(
                        get: { careers.preferences.diversityGroups.contains(g) },
                        set: { on in careers.updatePreferences { if on { $0.diversityGroups.insert(g) } else { $0.diversityGroups.remove(g) } } }))
                }
            } header: {
                Text("Programmes limited to specific groups")
            } footer: {
                Text("Some programmes are only for certain groups. Turn on the ones that apply to you and they join your watchlist. This stays on this Mac.")
            }

            if !prefs.starredCompanies.isEmpty {
                Section("Watched companies") {
                    ForEach(prefs.starredCompanies.sorted(), id: \.self) { c in
                        HStack {
                            Text(c.capitalized)
                            Spacer()
                            Button("Remove") { careers.toggleCompanyStar(c) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Careers")
    }

    private func binding<T>(_ key: WritableKeyPath<CareersPreferences, T>) -> Binding<T> {
        Binding(get: { careers.preferences[keyPath: key] },
                set: { value in careers.updatePreferences { $0[keyPath: key] = value } })
    }
}
