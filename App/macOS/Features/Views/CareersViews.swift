import AppKit
import SwiftUI
import OrbitCore

/// Careers: finance programmes from Trackr with firm logos, a watchlist and
/// "when things drop" alerts. Filtering lives in `CareersFilter` (OrbitCore).
struct CareersView: View {
    @State private var filter = CareersFilter(status: .open)
    @State private var selection: Opportunity.ID?
    @State private var showInspector = false
    @State private var showSettings = false
    private var careers: CareersService { FeatureHub.shared.careers }

    private static let categoryOptions: [(value: OpportunityCategory?, title: String)] = [
        (nil, "All"), (.springWeeks, "Spring weeks"), (.summerInternships, "Summer internships"), (.offCycle, "Off-cycle"),
        (.industrialPlacements, "Placements"), (.graduateProgrammes, "Grad schemes"), (.events, "Events"),
    ]

    var body: some View {
        let now = Date()
        let rows = filter.apply(careers.opportunities, preferences: careers.preferences, now: now)
        let counts = filter.counts(careers.opportunities, preferences: careers.preferences, now: now)
        var keyed: [OpportunityCategory?: Int] = [nil: counts.values.reduce(0, +)]
        for (k, v) in counts { keyed[k] = v }
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                PageHeader(title: "Careers", subtitle: footerText) {
                    HStack(spacing: Theme.Space.s) {
                        Button { Task { await careers.sync() } } label: {
                            Label(careers.syncing ? "Checking…" : "Check Trackr", systemImage: "arrow.clockwise")
                        }
                        .orbitGlassButton()
                        .disabled(careers.syncing)
                        Button { showSettings = true } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                            .orbitGlassButton()
                    }
                }
                ScrollView(.horizontal) {
                    GlassSegmented(options: Self.categoryOptions, selection: $filter.category, counts: keyed)
                        .padding(2)
                }
                .scrollIndicators(.never)
                HStack(spacing: Theme.Space.m) {
                    GlassSegmented(options: CareersFilter.Status.allCases.map { ($0, $0.label) }, selection: $filter.status)
                    Spacer(minLength: 0)
                    toggle("Watchlist", "star.fill", $filter.watchlistOnly)
                    toggle("Eligible for me", "person.fill.checkmark", $filter.eligibleOnly)
                    toggle("First-year", "1.circle.fill", $filter.firstYearOnly)
                    if !careers.preferences.diversityGroups.isEmpty {
                        toggle("Diversity", "heart.circle.fill", $filter.diversityOnly)
                    }
                }
                if let c = filter.category, !careers.preferences.categories.contains(c) {
                    HStack {
                        Label("You're not tracking \(c.label.lowercased()).", systemImage: "eye.slash")
                            .font(Theme.body.weight(.medium))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Track \(c.label.lowercased())") {
                            careers.updatePreferences { $0.categories.insert(c) }
                        }
                        .orbitGlassProminentButton()
                    }
                    .padding(Theme.Space.m)
                    .orbitGlassCard(radius: Theme.Radius.m, tint: Theme.warning)
                }
                if careers.opportunities.isEmpty {
                    EmptyState(systemImage: "briefcase.fill",
                               title: careers.syncing ? "Reading Trackr…" : "No programmes yet",
                               message: "Orbit checks Trackr's UK finance lists every two hours and tells you when spring weeks and internships open.",
                               actionTitle: careers.syncing ? nil : "Check now") { Task { await careers.sync() } }
                        .padding(Theme.Space.l)
                        .orbitGlassCard()
                } else if rows.isEmpty {
                    EmptyState(systemImage: "line.3.horizontal.decrease.circle", title: emptyTitle,
                               message: filter.search.isEmpty ? "Try another status or category." : "Try another search.")
                        .padding(Theme.Space.l)
                        .orbitGlassCard()
                } else {
                    LazyVStack(spacing: Theme.Space.s) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, o in
                            OpportunityRow(opportunity: o, selected: selection == o.id, now: now)
                                .onTapGesture { selection = o.id; showInspector = true }
                                .staggeredAppear(min(index, 12))
                        }
                    }
                }
                HStack {
                    Spacer()
                    Link("Data from Trackr", destination: (filter.category ?? .springWeeks).pageURL)
                        .font(Theme.caption)
                }
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.bottom, Theme.Space.xxl)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .orbitBackground()
        .searchable(text: $filter.search, prompt: "Company, programme or test")
        .inspector(isPresented: $showInspector) {
            Group {
                if let id = selection, let o = careers.opportunities.first(where: { $0.id == id }) {
                    OpportunityDetail(opportunity: o)
                } else {
                    ContentUnavailableView("Select a programme", systemImage: "briefcase")
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
        }
        .toolbar {
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.trailing") }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                CareersSettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
            }
            .frame(minWidth: 480, minHeight: 560)
        }
        .navigationTitle("Careers")
    }

    private func toggle(_ title: String, _ symbol: String, _ value: Binding<Bool>) -> some View {
        let on = value.wrappedValue
        return Button {
            withAnimation(Motion.snappy) { value.wrappedValue.toggle() }
        } label: {
            Label(title, systemImage: symbol)
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(on ? Theme.accent.opacity(0.16) : Theme.hover, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.45) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var emptyTitle: String {
        switch filter.status {
        case .open: "Nothing open right now"
        case .openingSoon: "Nothing expected soon"
        case .closed: "Nothing closed yet"
        case .all: "No matches"
        }
    }

    private var footerText: String {
        if !careers.status.isEmpty { return careers.status }
        guard let last = careers.lastSync else { return "Not checked yet" }
        return "\(careers.opportunities.count) programmes · checked \(last.formatted(date: .omitted, time: .shortened)) · every 2 hours"
    }
}

/// One programme as a glass row: logo, names, dates and a star.
private struct OpportunityRow: View {
    let opportunity: Opportunity
    var selected: Bool
    var now: Date
    private var careers: CareersService { FeatureHub.shared.careers }

    var body: some View {
        let o = opportunity
        let t = careers.tracker
        let prefs = careers.preferences
        HStack(spacing: Theme.Space.m) {
            FirmLogo(company: o.company, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(o.company).font(Theme.large.weight(.bold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Tag(text: o.category.label, color: color(o.category))
                    if let e = o.eligibility { Tag(text: e, color: Theme.pink, systemImage: "person.2.fill") }
                    if o.rolling { Tag(text: "Rolling", color: Theme.warning, systemImage: "arrow.triangle.2.circlepath") }
                }
                Text(o.programme).font(Theme.body).foregroundStyle(Theme.textSecondary).lineLimit(1)
                HStack(spacing: Theme.Space.s) {
                    if let test = CareersPrep.testName(o) { Label(test, systemImage: "checklist").lineLimit(1) }
                    if let a = o.acceptanceRate { Label(a, systemImage: "person.3.fill").lineLimit(1) }
                    if let stage = o.latestStage { Label(stage, systemImage: "flag.fill").lineLimit(1) }
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: Theme.Space.m)
            status(o, t)
            Button { withAnimation(Motion.bouncy) { careers.toggleStar(o) } } label: {
                Image(systemName: prefs.isStarred(o) ? "star.fill" : "star")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(prefs.isStarred(o) ? AnyShapeStyle(Color.yellow.gradient) : AnyShapeStyle(Theme.textTertiary))
                    .scaleEffect(prefs.isStarred(o) ? 1.1 : 1)
            }
            .buttonStyle(.plain)
            .help(prefs.isStarred(o) ? "Unstar" : "Star: notify me when it opens")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .orbitGlassCard(radius: Theme.Radius.l, tint: selected ? Theme.accent : nil)
        .hoverLift(1.006)
        .contentShape(Rectangle())
        .contextMenu {
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
        .onTapGesture(count: 2) {
            if let url = o.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
        }
    }

    @ViewBuilder
    private func status(_ o: Opportunity, _ t: CareersTracker) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if o.isOpen(now: now) {
                if let d = o.daysToClose(now: now) {
                    Text(d == 0 ? "Closes today" : "\(d)d left")
                        .font(Theme.number(15))
                        .foregroundStyle(d <= 3 ? Theme.danger : (d <= 10 ? Theme.warning : Theme.success))
                    Text("closes \(CareersDay.short(o.closingDate!))").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                } else {
                    Text("Open").font(Theme.number(15)).foregroundStyle(Theme.success)
                    Text(o.rolling ? "rolling" : "no closing date").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            } else if o.isClosed(now: now) {
                Text("Closed").font(Theme.number(15)).foregroundStyle(Theme.textTertiary)
                if let c = o.closingDate { Text(CareersDay.short(c)).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
            } else if let e = t.expectedOpening(o) {
                Text(e.predicted ? "~\(CareersDay.short(e.date))" : CareersDay.short(e.date))
                    .font(Theme.number(15))
                    .foregroundStyle(Theme.accent)
                Text(e.predicted ? "expected (last year + 1)" : "opens").font(Theme.caption).foregroundStyle(Theme.textTertiary)
            } else {
                Text("TBC").font(Theme.number(15)).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(minWidth: 96, alignment: .trailing)
    }

    private func color(_ c: OpportunityCategory) -> Color {
        switch c {
        case .springWeeks: Theme.success
        case .summerInternships: Theme.indigo
        case .offCycle: Theme.cyan
        case .industrialPlacements: Theme.violet
        case .graduateProgrammes: Theme.pink
        case .events: Theme.warning
        }
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
                FirmLogo(company: o.company, size: 56)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(o.company).font(Theme.title(Theme.Size.title2))
                    Text(o.programme).font(Theme.body).foregroundStyle(Theme.textSecondary)
                    Text(o.category.label + (o.sectors.isEmpty ? "" : " · " + o.sectors.joined(separator: ", ")))
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }

                HStack(spacing: Theme.Space.s) {
                    if let url = o.url.flatMap(URL.init(string:)) {
                        Button("Open application page") { NSWorkspace.shared.open(url) }
                            .orbitGlassProminentButton()
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
        .orbitScreen()
        .navigationTitle("Careers")
    }

    private func binding<T>(_ key: WritableKeyPath<CareersPreferences, T>) -> Binding<T> {
        Binding(get: { careers.preferences[keyPath: key] },
                set: { value in careers.updatePreferences { $0[keyPath: key] = value } })
    }
}
