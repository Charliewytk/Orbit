import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import OrbitCore

/// First-run setup on the Mac: a full-window, multi-step flow of glass cards over
/// the ambient backdrop. Every step can be skipped and shows a tick once it's
/// done. Re-run it from Settings → General → "Run setup again".
struct MacOnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(OrbitBrain.self) private var brain
    var onFinish: () -> Void

    enum Step: Int, CaseIterable, Identifiable {
        case welcome, uni, ele, ed, google, exeter, notes, ai, money, careers, focus, routine, done
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: "Welcome to Orbit"
            case .uni: "Your uni"
            case .ele: "Connect ELE"
            case .ed: "Ed Discussion"
            case .google: "Gmail and Google Calendar"
            case .exeter: "Exeter mail and timetable"
            case .notes: "Your lecture notes"
            case .ai: "The assistant"
            case .money: "Money (optional)"
            case .careers: "Careers"
            case .focus: "Focus and notifications"
            case .routine: "Your routine and goals"
            case .done: "You're all set"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome: "Your calendar, to-dos, uni deadlines, email, notes and money on one dashboard, planned around you."
            case .uni: "Orbit knows Exeter's term dates, so it can say “Week 2” and plan around reading weeks."
            case .ele: "Sign in once. Orbit reads your modules, each week's slides and readings, homework and assessments."
            case .ed: "Posts from staff, announcements and deadline mentions from your Ed courses."
            case .google: "Orbit writes only to its own “Orbit” calendar and saves replies as drafts. It never sends email."
            case .exeter: "Three quick steps on this Mac. No IT tickets, no app registration."
            case .notes: "GoodNotes auto-backup is best: Orbit reads every page, handwriting too, checks it against the slides and makes flashcards."
            case .ai: "OpenCode answers first; Ollama runs fully offline as the backup. Both free."
            case .money: "Connect Monzo or Trading 212 to see what's safe to spend. Skip it if you like."
            case .careers: "Spring weeks, internships and insight days from Trackr, with alerts the moment they open."
            case .focus: "Do Not Disturb while you focus, and a nudge when something needs you."
            case .routine: "Orbit plans study inside these hours. The rings on Home track your daily goals."
            case .done: "Orbit syncs in the background and plans your week. Close your rings, keep the streak."
            }
        }

        var symbol: String {
            switch self {
            case .welcome: "circle.circle.fill"
            case .uni: "graduationcap.fill"
            case .ele: "building.columns.fill"
            case .ed: "bubble.left.and.bubble.right.fill"
            case .google: "envelope.fill"
            case .exeter: "calendar.badge.clock"
            case .notes: "pencil.and.scribble"
            case .ai: "cpu.fill"
            case .money: "sterlingsign"
            case .careers: "briefcase.fill"
            case .focus: "moon.fill"
            case .routine: "sun.horizon.fill"
            case .done: "checkmark.seal.fill"
            }
        }

        var color: Color {
            switch self {
            case .welcome: Theme.accent
            case .uni: Destination.uni.color
            case .ele: Color(hex: 0x0E7C86)
            case .ed: Color(hex: 0x7C5CFF)
            case .google: Color(hex: 0xEA4335)
            case .exeter: Color(hex: 0x006B3F)
            case .notes: Destination.notes.color
            case .ai: Destination.chat.color
            case .money: Destination.money.color
            case .careers: Destination.careers.color
            case .focus: Destination.focus.color
            case .routine: Color(hex: 0xFF9F0A)
            case .done: Theme.success
            }
        }
    }

    @State private var step: Step = .welcome
    @State private var forward = true
    @State private var name = ""
    @State private var prefs = UserPrefs()
    @State private var loaded = false
    @State private var notificationsAllowed = false
    @State private var celebrate = 0

    var body: some View {
        ZStack {
            AmbientBackdrop().ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    card
                        .id(step)
                        .transition(.asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                        .padding(.horizontal, Theme.Space.xxl)
                        .padding(.vertical, Theme.Space.l)
                        .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never)
                bottomBar
            }
        }
        .onAppear(perform: load)
        .task { await refreshNotificationStatus() }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: Theme.Space.m) {
            HStack(spacing: 6) {
                ForEach(Step.allCases) { s in
                    Button {
                        go(to: s)
                    } label: {
                        ZStack {
                            Capsule()
                                .fill(s == step ? AnyShapeStyle(Theme.accentGradient)
                                      : isDone(s) ? AnyShapeStyle(Theme.success) : AnyShapeStyle(Theme.pressed))
                                .frame(width: s == step ? 28 : 10, height: 10)
                            if isDone(s) && s != step {
                                Image(systemName: "checkmark").font(.system(size: 6, weight: .heavy)).foregroundStyle(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(s.title)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 8)
            .orbitGlass(in: Capsule())
            .animation(Motion.snappy, value: step)
            Spacer()
            Text("\(step.rawValue + 1) of \(Step.allCases.count)")
                .font(Theme.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .contentTransition(.numericText())
            if step != .done {
                Button("Skip setup") { finish() }
                    .buttonStyle(SoftButtonStyle(color: Theme.textSecondary))
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.l)
    }

    private var bottomBar: some View {
        HStack(spacing: Theme.Space.m) {
            if step != .welcome {
                Button {
                    back()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .orbitGlassButton()
                .keyboardShortcut(.leftArrow, modifiers: [.command])
            }
            Spacer()
            if step != .welcome && step != .done && !isDone(step) {
                Button("Skip this step") { next() }
                    .buttonStyle(SoftButtonStyle(color: Theme.textSecondary))
            }
            Button {
                next()
            } label: {
                Text(step == .done ? "Start using Orbit" : (step == .welcome ? "Let's go" : "Continue"))
                    .font(Theme.large.weight(.bold))
                    .padding(.horizontal, Theme.Space.m)
            }
            .orbitGlassProminentButton()
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.l)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .center, spacing: Theme.Space.l) {
                IconTile(symbol: step.symbol, color: step.color, size: 64)
                    .shadow(color: step.color.opacity(0.4), radius: 16, y: 6)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: Theme.Space.s) {
                        Text(step.title)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        if isDone(step) && step != .done && step != .welcome {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(Theme.success)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    Text(step.subtitle)
                        .font(Theme.large)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: 760, alignment: .leading)
        .orbitGlassCard(radius: Theme.Radius.xl)
        .animation(Motion.bouncy, value: isDone(step))
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .uni: OnboardingUniStep()
        case .ele: ELEConnectRow()
        case .ed: EdConnectRow()
        case .google:
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                GoogleConnectRow()
                Text("No Google account? Skip this: Orbit can use the calendars on this Mac (next step).")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        case .exeter:
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ExeterSetupPanel()
                ExeterAdvancedOptions()
            }
        case .notes: OnboardingNotesStep()
        case .ai: AIStatusPanel()
        case .money: OnboardingMoneyStep()
        case .careers: OnboardingCareersStep()
        case .focus: focusStep
        case .routine: routineStep
        case .done: doneStep
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What should Orbit call you?")
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                TextField("First name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.m)
                    .background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                    .frame(maxWidth: 360)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
                feature("house.fill", Theme.accent, "One dashboard", "Today, tomorrow, to-dos and deadlines at a glance.")
                feature("calendar.badge.clock", Destination.calendar.color, "Plans your week", "Study blocks fitted around lectures.")
                feature("graduationcap.fill", Destination.uni.color, "Knows your course", "ELE, Ed, slides, homework, marks.")
                feature("flame.fill", .orange, "Keeps you going", "Daily rings, streaks and a heatmap.")
                feature("tray.full.fill", Destination.inbox.color, "Tames email", "Urgent mail first, drafts ready.")
                feature("lock.fill", Theme.success, "Private and free", "Runs on your Mac. No server.")
            }
        }
    }

    private func feature(_ symbol: String, _ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            IconTile(symbol: symbol, color: color, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body.weight(.bold)).foregroundStyle(Theme.textPrimary)
                Text(text).font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
    }

    private var focusStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            OnboardingRow(symbol: "bell.badge.fill", color: Theme.danger, title: "Notifications",
                          detail: notificationsAllowed ? "Allowed" : "Urgent mail, new deadlines, spring weeks opening, your morning brief.",
                          done: notificationsAllowed) {
                if !notificationsAllowed {
                    Button("Allow notifications") {
                        Task {
                            _ = await Notifier.requestAuthorization()
                            await refreshNotificationStatus()
                        }
                    }
                    .orbitGlassProminentButton(Theme.danger)
                }
            }
            OnboardingRow(symbol: "moon.fill", color: Destination.focus.color, title: "Do Not Disturb while focusing",
                          detail: "macOS only lets apps switch Focus through two tiny Shortcuts.", done: false) {
                Toggle("", isOn: Binding(
                    get: { FeatureSettings.bool(FeatureSettings.focusUseShortcuts, default: true) },
                    set: { FeatureSettings.defaults.set($0, forKey: FeatureSettings.focusUseShortcuts) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            OnboardingShortcutCheck()
            OnboardingRow(symbol: "keyboard", color: Theme.indigo, title: "Quick capture anywhere",
                          detail: "A global shortcut opens a floating quick add over any app.", done: false) {
                Toggle("", isOn: Binding(
                    get: { FeatureSettings.bool(FeatureSettings.quickCaptureEnabled, default: true) },
                    set: {
                        FeatureSettings.defaults.set($0, forKey: FeatureSettings.quickCaptureEnabled)
                        FeatureHub.shared.capture.registerFromSettings()
                    }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }

    private var routineStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            OnboardingGoals()
            Form {
                PreferencesSections(prefs: $prefs)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(minHeight: 640)
        }
    }

    private var doneStep: some View {
        HStack(spacing: Theme.Space.xl) {
            ZStack {
                ActivityRings(study: 1, tasks: 1, reviews: 1, size: 150)
                CheckBurst(trigger: celebrate)
                    .scaleEffect(3)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(name.isEmpty ? "Ready when you are." : "Ready when you are, \(name).")
                    .font(Theme.title(22))
                    .foregroundStyle(Theme.textPrimary)
                ForEach(Step.allCases.filter { $0 != .welcome && $0 != .done && $0 != .routine && $0 != .uni }) { s in
                    HStack(spacing: 6) {
                        Image(systemName: isDone(s) ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(isDone(s) ? Theme.success : Theme.textTertiary)
                        Text(s.title).font(Theme.body).foregroundStyle(isDone(s) ? Theme.textPrimary : Theme.textSecondary)
                    }
                }
                Text("Anything you skipped is in Settings, or run this setup again from Settings → General.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .padding(.top, Theme.Space.xs)
            }
        }
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.4))
                celebrate += 1
                try? await Task.sleep(for: .seconds(0.5))
                celebrate += 1
            }
        }
    }

    // MARK: Status

    private func isDone(_ s: Step) -> Bool {
        let accounts = brain.accounts
        switch s {
        case .welcome: return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .uni: return UserDefaults.standard.string(forKey: OnboardingUniStep.programmeKey) != nil
        case .ele: return accounts.eleConnected && !accounts.eleNeedsSignIn
        case .ed: return FeatureHub.shared.ed.connected && !FeatureHub.shared.ed.needsSignIn
        case .google: return accounts.googleConnected
        case .exeter: return MacCalendarAccess.shared.granted || ExeterMailStatus.shared.fullDiskAccess
        case .notes: return !(MacPrefs.string(MacPrefs.notesFolderPath) ?? "").isEmpty || accounts.microsoftConnected
        case .ai: return brain.openCodeUp || brain.ollama.available
        case .money: return FeatureHub.shared.money.hasAnyData
        case .careers:
            let p = FeatureHub.shared.careers.preferences
            return !p.starredCompanies.isEmpty || !p.diversityGroups.isEmpty
        case .focus: return notificationsAllowed
        case .routine: return true
        case .done: return true
        }
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    // MARK: Navigation

    private func load() {
        guard !loaded else { return }
        loaded = true
        name = app.firstName
        prefs = app.prefs
    }

    private func save() {
        app.setFirstName(name)
        app.savePrefs(prefs)
    }

    private func go(to s: Step) {
        save()
        forward = s.rawValue > step.rawValue
        withAnimation(Motion.smooth) { step = s }
    }

    private func next() {
        if step == .done { finish(); return }
        go(to: Step(rawValue: step.rawValue + 1) ?? .done)
    }

    private func back() {
        go(to: Step(rawValue: step.rawValue - 1) ?? .welcome)
    }

    private func finish() {
        save()
        onFinish()
    }
}

// MARK: - Pieces

/// A row with a tile, text, a tick when done and a trailing control.
struct OnboardingRow<Trailing: View>: View {
    var symbol: String
    var color: Color
    var title: String
    var detail: String
    var done: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(symbol: symbol, color: color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).font(Theme.body.weight(.bold)).foregroundStyle(Theme.textPrimary)
                    if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success) }
                }
                Text(detail).font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            trailing
        }
        .padding(Theme.Space.m)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
    }
}

/// Uni: programme, year and the term dates Orbit already knows.
struct OnboardingUniStep: View {
    @Environment(OrbitBrain.self) private var brain
    static let programmeKey = "orbit.programme"
    static let yearKey = "orbit.yearOfStudy"
    @AppStorage(OnboardingUniStep.programmeKey) private var programme = "BSc Economics"
    @AppStorage(OnboardingUniStep.yearKey) private var year = 1

    var body: some View {
        let cal = brain.academic.calendar
        let day = DayCalendar(timeZone: cal.timeZone)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            OnboardingRow(symbol: "building.2.fill", color: Color(hex: 0x006B3F), title: "University of Exeter",
                          detail: "Streatham campus · UK time", done: true) { EmptyView() }
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Programme").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    TextField("BSc Economics", text: $programme)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Year").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    Picker("", selection: $year) {
                        ForEach(1...4, id: \.self) { Text("Year \($0)").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }
            .onChange(of: year) { _, new in
                FeatureHub.shared.careers.updatePreferences { $0.yearOfStudy = new }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Term dates").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                ForEach(cal.config.terms, id: \.number) { t in
                    HStack {
                        Text(t.name).font(Theme.body.weight(.medium)).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if let start = cal.termStart(t.number) {
                            Text("Week 1 starts \(day.format(start, "EEE d MMM yyyy")) · \(t.weeks) weeks")
                                .font(Theme.body.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                Text("Right now: \(brain.academic.weekLabel)")
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(Theme.Space.m)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        }
        .onAppear {
            // Mark the step as seen with the prefilled programme.
            UserDefaults.standard.set(programme, forKey: Self.programmeKey)
        }
    }
}

/// Notes: GoodNotes auto-backup (recommended), OneNote, or (not) Apple Notes.
struct OnboardingNotesStep: View {
    enum Source: String, CaseIterable, Identifiable {
        case goodnotes, onenote, apple
        var id: String { rawValue }
        var title: String {
            switch self {
            case .goodnotes: "GoodNotes (recommended)"
            case .onenote: "OneNote"
            case .apple: "Apple Notes"
            }
        }
    }

    @State private var source: Source = .goodnotes

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            GlassSegmented(options: Source.allCases.map { ($0, $0.title) }, selection: $source)
            switch source {
            case .goodnotes:
                GoodNotesFolderPicker()
            case .onenote:
                explainer("Sign in with Microsoft to read OneNote directly (Exeter may block it), or export notebooks as PDF into a folder and pick it.")
                MicrosoftConnectRow()
                NotesSourcePicker()
            case .apple:
                explainer("Not supported: Apple Notes has no export Orbit can read. Use GoodNotes auto-backup instead.")
            }
        }
    }

    private func explainer(_ text: String) -> some View {
        Text(text)
            .font(Theme.body)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Finds GoodNotes auto-backup folders in OneDrive / Google Drive and lets the
/// student pick one (or any folder).
struct GoodNotesFolderPicker: View {
    @Environment(OrbitBrain.self) private var brain
    @AppStorage(MacPrefs.noteSource) private var noteSource = ""
    @AppStorage(MacPrefs.notesFolderPath) private var folderPath = ""
    @State private var found: [GoodNotesBackup.Folder] = []
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text("In GoodNotes: Settings → Auto-backup → OneDrive (or Google Drive), format PDF.")
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("OneDrive (Exeter) or Google Drive both work. Orbit watches the folder, reads each page (handwriting too), matches notebooks to modules and only re-reads pages that changed.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if found.isEmpty {
                Label("No GoodNotes backup folder found yet in OneDrive or Google Drive on this Mac.", systemImage: "magnifyingglass")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(found) { f in
                let selected = folderPath == f.url.path
                HStack(spacing: Theme.Space.m) {
                    IconTile(symbol: f.service == .googleDrive ? "externaldrive.fill.badge.icloud" : "cloud.fill",
                             color: f.service == .googleDrive ? Color(hex: 0x1FA463) : Color(hex: 0x0A6CD6), size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.label).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        Text(f.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if selected {
                        Label("In use", systemImage: "checkmark.circle.fill").font(Theme.caption.weight(.bold))
                            .foregroundStyle(Theme.success)
                    } else {
                        Button("Use this folder") { use(f.url) }
                            .orbitGlassProminentButton()
                    }
                }
                .padding(Theme.Space.m)
                .background(selected ? Theme.success.opacity(0.1) : Theme.hover,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            }
            HStack(spacing: Theme.Space.s) {
                Button("Look again") { refresh() }
                    .orbitGlassButton()
                Button(folderPath.isEmpty ? "Pick a folder…" : "Pick a different folder…") { choosing = true }
                    .orbitGlassButton()
                if brain.running.contains(.notes) {
                    ProgressView().controlSize(.small)
                    Text("Reading your notebooks…").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            if !folderPath.isEmpty && !found.contains(where: { $0.url.path == folderPath }) {
                Text("Using \(folderPath)").font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .onAppear(perform: refresh)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { use(url) }
        }
    }

    private func refresh() {
        found = GoodNotesBackup.candidateFolders()
        // Exactly one backup folder and nothing chosen yet: use it.
        if folderPath.isEmpty, found.count == 1 { use(found[0].url) }
    }

    private func use(_ url: URL) {
        folderPath = url.path
        noteSource = "folder"
        OrbitLog.log("notes", "Notes folder: \(url.path)")
        Task { await brain.syncNotes() }
    }
}

/// Money: status and a sheet with the full Money settings.
struct OnboardingMoneyStep: View {
    @State private var showSettings = false
    private var money: MoneyService { FeatureHub.shared.money }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            OnboardingRow(symbol: "building.columns.fill", color: Color(hex: 0xFF4F64), title: "Monzo",
                          detail: money.monzoState.label, done: money.data.lastMonzoSync != nil) { EmptyView() }
            OnboardingRow(symbol: "chart.line.uptrend.xyaxis", color: Color(hex: 0x1FA1F2), title: "Trading 212",
                          detail: money.t212Status.isEmpty ? "Optional: investments in your net worth" : money.t212Status,
                          done: money.data.investments != nil) { EmptyView() }
            Button("Set up Monzo, Trading 212 or a CSV…") { showSettings = true }
                .orbitGlassButton()
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                MoneySettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
            }
            .frame(minWidth: 560, minHeight: 600)
        }
    }
}

/// Careers: year, diversity programmes and a wall of firms to star.
struct OnboardingCareersStep: View {
    private var careers: CareersService { FeatureHub.shared.careers }

    var body: some View {
        let prefs = careers.preferences
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                Stepper("Year of study: \(prefs.yearOfStudy)", value: Binding(
                    get: { careers.preferences.yearOfStudy },
                    set: { v in careers.updatePreferences { $0.yearOfStudy = v } }), in: 1...4)
                Spacer()
                Toggle("Watch every spring week I'm eligible for", isOn: Binding(
                    get: { careers.preferences.watchAllSpringWeeks },
                    set: { v in careers.updatePreferences { $0.watchAllSpringWeeks = v } }))
                    .toggleStyle(.switch)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Programmes for specific groups you belong to")
                    .font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                Flow(spacing: 6) {
                    ForEach(DiversityGroup.allCases) { g in
                        let on = prefs.diversityGroups.contains(g)
                        Button {
                            careers.updatePreferences { if on { $0.diversityGroups.remove(g) } else { $0.diversityGroups.insert(g) } }
                        } label: {
                            Label(g.label, systemImage: on ? "checkmark.circle.fill" : "circle")
                                .font(Theme.caption.weight(.semibold))
                                .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(on ? Theme.accent.opacity(0.14) : Theme.hover, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Stays on this Mac. Only used to show programmes you can apply to.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Star the firms you care about").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    ForEach(FirmDomains.popular, id: \.name) { firm in
                        let on = prefs.starredCompanies.contains(firm.name.lowercased())
                        Button {
                            withAnimation(Motion.bouncy) { careers.toggleCompanyStar(firm.name) }
                        } label: {
                            VStack(spacing: 6) {
                                FirmLogo(company: firm.name, size: 36)
                                Text(firm.name)
                                    .font(Theme.caption.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(on ? Theme.accent.opacity(0.16) : Theme.hover,
                                        in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                if on {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.yellow)
                                        .padding(6)
                                        .transition(.scale)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                                .strokeBorder(on ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// The daily goals behind the rings.
struct OnboardingGoals: View {
    private var stats: StatsService { FeatureHub.shared.stats }

    var body: some View {
        let g = stats.goals
        HStack(spacing: Theme.Space.l) {
            ActivityRings(study: 0.8, tasks: 0.6, reviews: 0.45, size: 96)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Stepper(value: Binding(get: { stats.goals.studyMinutes }, set: { stats.goals.studyMinutes = $0 }),
                        in: 30...480, step: 15) {
                    goal("Study", "\(Fmt.duration(g.studyMinutes)) a day", Theme.ringStudy)
                }
                Stepper(value: Binding(get: { stats.goals.tasks }, set: { stats.goals.tasks = $0 }), in: 1...20) {
                    goal("To-dos", "\(g.tasks) a day", Theme.ringTasks)
                }
                Stepper(value: Binding(get: { stats.goals.reviews }, set: { stats.goals.reviews = $0 }), in: 5...200, step: 5) {
                    goal("Flashcard reviews", "\(g.reviews) a day", Theme.ringReviews)
                }
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
    }

    private func goal(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            Text(value).font(Theme.body.monospacedDigit()).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Whether the two Focus shortcuts exist.
struct OnboardingShortcutCheck: View {
    @State private var names: Set<String>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FocusShortcutStatus(names: names)
            Button("Check shortcuts") { Task { names = await FocusShortcuts.installed() ?? [] } }
                .orbitGlassButton()
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .task { names = await FocusShortcuts.installed() }
    }
}
