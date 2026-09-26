import SwiftUI
import SwiftData
import OrbitCore
import UserNotifications

/// The fresh onboarding (shown once per `OnboardingFlow.version`): seven short,
/// skippable steps on the light pastel look. Welcome → your modules in plain
/// English → connect accounts (with ticks) → notes folder → routine basics →
/// AI check → done (with confetti).
struct WelcomeFlow: View {
    var onFinish: () -> Void
    @Environment(AppModel.self) private var app

    enum Step: Int, CaseIterable, Identifiable {
        case welcome, modules, accounts, notes, routine, ai, done
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: "Welcome to Orbit"
            case .modules: "Your modules"
            case .accounts: "Connect your accounts"
            case .notes: "Your notes folder"
            case .routine: "Your day"
            case .ai: "Your assistant"
            case .done: "You're all set"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome: "Calendar, to-dos, uni, mail and notes on one calm dashboard, planned around you."
            case .modules: "Orbit uses plain names everywhere. Check these look right."
            case .accounts: "Connect what you use. Everything stays on this Mac, and you can skip any of them."
            case .notes: "Point Orbit at where your lecture notes back up, and it'll match them to modules and weeks."
            case .routine: "Orbit plans study inside these hours and never before you're up."
            case .ai: "Orbit's assistant runs through OpenCode, with Muse Spark as the preferred model."
            case .done: "Orbit syncs in the background. Close your rings and keep your streak going."
            }
        }

        var symbol: String {
            switch self {
            case .welcome: "hand.wave.fill"
            case .modules: "books.vertical.fill"
            case .accounts: "person.crop.circle.badge.checkmark"
            case .notes: "folder.fill"
            case .routine: "sunrise.fill"
            case .ai: "sparkles"
            case .done: "party.popper.fill"
            }
        }

        var fill: Color {
            switch self {
            case .welcome: Theme.butter
            case .modules: Theme.lavender
            case .accounts: Theme.sky
            case .notes: Theme.peach
            case .routine: Theme.sage
            case .ai: Theme.lavender
            case .done: Theme.blush
            }
        }
    }

    @State private var step: Step = .welcome
    @State private var forward = true
    @State private var name = ""
    @State private var prefs = UserPrefs()
    @State private var loaded = false
    @State private var confetti = 0

    var body: some View {
        VStack(spacing: 0) {
            WelcomeTopBar(step: step, onSkipAll: finish)
            ScrollView {
                stepCard
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .opacity))
                    .padding(.horizontal, 28)
                    .padding(.vertical, Theme.Space.l)
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            WelcomeBottomBar(step: step, onBack: back, onNext: next)
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay { ConfettiView(trigger: confetti).ignoresSafeArea() }
        .onAppear(perform: load)
    }

    private var stepCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: Theme.Space.l) {
                IconCircle(symbol: step.symbol, size: 60, fill: step.fill)
                VStack(alignment: .leading, spacing: 6) {
                    Text(step.title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text(step.subtitle)
                        .font(Theme.large)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(32)
        .frame(maxWidth: 720, alignment: .leading)
        .softCard(radius: Theme.Radius.xl)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: WelcomeNameStep(name: $name)
        case .modules: WelcomeModulesStep()
        case .accounts: WelcomeAccountsStep()
        case .notes: OnboardingNotesStep()
        case .routine: WelcomeRoutineStep(prefs: $prefs)
        case .ai: WelcomeAIStep()
        case .done: WelcomeDoneStep(name: name)
        }
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
        if s == .done {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.35))
                confetti += 1
                OrbitSound.celebrate()
            }
        }
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

// MARK: - Chrome

private struct WelcomeTopBar: View {
    var step: WelcomeFlow.Step
    var onSkipAll: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            OrbitMark(size: 30)
            HStack(spacing: 6) {
                ForEach(WelcomeFlow.Step.allCases) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Theme.accent : Theme.pressed)
                        .frame(width: s == step ? 26 : 8, height: 8)
                }
            }
            .animation(Motion.snappy, value: step)
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue + 1) of \(WelcomeFlow.Step.allCases.count)")
            Spacer()
            if step != .done {
                Button("Skip setup", action: onSkipAll)
                    .buttonStyle(SoftButtonStyle(color: Theme.textSecondary))
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, Theme.Space.l)
    }
}

private struct WelcomeBottomBar: View {
    var step: WelcomeFlow.Step
    var onBack: () -> Void
    var onNext: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            if step != .welcome {
                Button(action: onBack) { Label("Back", systemImage: "chevron.left") }
                    .orbitGlassButton()
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
            }
            Spacer()
            if step != .welcome && step != .done {
                Button("Skip this step", action: onNext)
                    .buttonStyle(SoftButtonStyle(color: Theme.textSecondary))
            }
            Button(action: onNext) {
                HStack(spacing: 6) {
                    Text(step == .done ? "Start using Orbit" : (step == .welcome ? "Let's go" : "Continue"))
                    Image(systemName: "arrow.right")
                }
                .font(Theme.large.weight(.semibold))
                .padding(.horizontal, 6)
            }
            .buttonStyle(PillButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, Theme.Space.l)
    }
}

/// A pastel row with an icon, text, a tick when done and a trailing control.
struct WelcomeRow<Trailing: View>: View {
    var symbol: String
    var title: String
    var detail: String
    var done: Bool
    var fill: Color = Theme.sky
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            IconCircle(symbol: symbol, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            trailing
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(done ? Theme.sageInk : Theme.textTertiary)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityLabel(done ? "Connected" : "Not connected")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(fill))
        .animation(Motion.bouncy, value: done)
    }
}

// MARK: - Steps

private struct WelcomeNameStep: View {
    @Binding var name: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What should Orbit call you?").font(Theme.body.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                TextField("First name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.m)
                    .background(Capsule().fill(Theme.hover))
                    .frame(maxWidth: 360)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                feature("house.fill", Theme.butter, "One calm dashboard", "Today, to-dos and deadlines at a glance.")
                feature("calendar.badge.clock", Theme.blush, "Plans your week", "Study fitted around lectures.")
                feature("graduationcap.fill", Theme.lavender, "Knows your course", "ELE, Ed, slides and homework.")
                feature("flame.fill", Theme.peach, "Keeps you going", "Rings, streaks, XP and badges.")
            }
        }
    }

    private func feature(_ symbol: String, _ fill: Color, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IconCircle(symbol: symbol, size: 34)
            Text(title).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textPrimary)
            Text(text).font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(fill))
    }
}

/// The modules, by their English names (ELE's plus the four defaults).
private struct WelcomeModulesStep: View {
    @Query(sort: \StoredModule.id) private var stored: [StoredModule]

    private var codes: [String] {
        var set = Set(ModuleNames.overrides.keys)
        for m in stored where !m.id.isEmpty { set.insert(m.id) }
        return set.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(codes.enumerated()), id: \.element) { i, code in
                HStack(spacing: Theme.Space.m) {
                    IconCircle(symbol: ModuleNames.symbol(for: code), size: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ModuleNames.title(for: code))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Text(code).font(Theme.caption.monospaced()).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.sageInk)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.pastel(i)))
            }
            Text("New modules from ELE get their names automatically. You'll see these names on every screen.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

/// Google, ELE, Ed and Exeter mail, each with a status tick; the full controls expand in place.
private struct WelcomeAccountsStep: View {
    @Environment(OrbitBrain.self) private var brain
    @State private var open: String?

    var body: some View {
        let accounts = brain.accounts
        let ed = FeatureHub.shared.ed
        VStack(alignment: .leading, spacing: 10) {
            account("google", "envelope.fill", "Google", "Gmail and Google Calendar",
                    done: accounts.googleConnected, fill: Theme.blush) { GoogleConnectRow() }
            account("ele", "building.columns.fill", "ELE", "Modules, slides, homework and assessments",
                    done: accounts.eleConnected && !accounts.eleNeedsSignIn, fill: Theme.lavender) { ELEConnectRow() }
            account("ed", "bubble.left.and.bubble.right.fill", "Ed Discussion", "Staff posts and announcements",
                    done: ed.connected && !ed.needsSignIn, fill: Theme.sky) { EdConnectRow() }
            account("exeter", "tray.full.fill", "Exeter mail", "Outlook mail and timetable on this Mac",
                    done: ExeterMailStatus.shared.fullDiskAccess || MacCalendarAccess.shared.granted, fill: Theme.sage) {
                ExeterSetupPanel()
            }
        }
    }

    private func account<Detail: View>(_ id: String, _ symbol: String, _ title: String, _ detail: String, done: Bool,
                                        fill: Color, @ViewBuilder panel: () -> Detail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WelcomeRow(symbol: symbol, title: title, detail: detail, done: done, fill: fill) {
                Button(open == id ? "Hide" : (done ? "Details" : "Connect")) {
                    withAnimation(Motion.smooth) { open = open == id ? nil : id }
                }
                .buttonStyle(done ? AnyButtonStyle(GlassCapsuleButtonStyle()) : AnyButtonStyle(PillButtonStyle()))
            }
            if open == id {
                panel()
                    .padding(.horizontal, Theme.Space.s)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Wake-up (07:35 by default), bedtime and study hours.
private struct WelcomeRoutineStep: View {
    @Binding var prefs: UserPrefs
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            timeRow("sunrise.fill", "I wake up at", Theme.butter, routineBinding(\.wakeTime))
            timeRow("moon.zzz.fill", "Bedtime", Theme.lavender, routineBinding(\.bedtime))
            timeRow("book.fill", "Study from", Theme.sage, prefsBinding(\.dayStart))
            timeRow("checkmark.seal.fill", "Wrap up by", Theme.blush, prefsBinding(\.dayEnd))
            OnboardingGoals()
                .padding(.top, Theme.Space.s)
        }
    }

    private func timeRow(_ symbol: String, _ title: String, _ fill: Color, _ minutes: Binding<MinuteOfDay>) -> some View {
        HStack(spacing: Theme.Space.m) {
            IconCircle(symbol: symbol, size: 36)
            Text(title).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textPrimary)
            Spacer()
            DatePicker("", selection: dateBinding(minutes), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.field)
                .frame(width: 90)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(fill))
    }

    private func routineBinding(_ key: WritableKeyPath<RoutineSettings, MinuteOfDay>) -> Binding<MinuteOfDay> {
        Binding(get: { prefs.effectiveRoutine[keyPath: key] },
                set: { value in
                    var r = prefs.effectiveRoutine
                    r[keyPath: key] = value
                    prefs.routine = r
                })
    }

    private func prefsBinding(_ key: WritableKeyPath<UserPrefs, MinuteOfDay>) -> Binding<MinuteOfDay> {
        Binding(get: { prefs[keyPath: key] }, set: { prefs[keyPath: key] = $0 })
    }

    private func dateBinding(_ minutes: Binding<MinuteOfDay>) -> Binding<Date> {
        let cal = app.calendar
        return Binding(get: { cal.date(minute: minutes.wrappedValue, of: Date()) },
                       set: { minutes.wrappedValue = cal.minuteOfDay($0) })
    }
}

/// Is OpenCode up, and which model will answer?
private struct WelcomeAIStep: View {
    @Environment(OrbitBrain.self) private var brain
    @State private var checking = false
    @State private var showDetails = false

    var body: some View {
        let model = MacPrefs.string(MacPrefs.openCodeModel) ?? MacPrefs.string(MacPrefs.openCodeResolvedModel)
        VStack(alignment: .leading, spacing: 10) {
            WelcomeRow(symbol: "sparkles", title: "OpenCode",
                       detail: brain.openCodeUp ? "Running and ready." : "Not running yet. Install OpenCode (opencode.ai), then check again.",
                       done: brain.openCodeUp, fill: Theme.lavender) {
                Button(checking ? "Checking…" : "Check again") { check() }
                    .buttonStyle(GlassCapsuleButtonStyle())
                    .disabled(checking)
            }
            WelcomeRow(symbol: "brain.head.profile", title: OpenCodeModelResolver.preferredName,
                       detail: model.map { $0.isEmpty ? "Picked automatically when OpenCode offers it." : "Using \($0)." }
                           ?? "Picked automatically when OpenCode offers it.",
                       done: brain.openCodeUp, fill: Theme.sky) { EmptyView() }
            WelcomeRow(symbol: "lock.shield.fill", title: "Offline backup",
                       detail: brain.ollama.available ? "Ollama is ready on this Mac." : "Optional: Ollama runs fully offline.",
                       done: brain.ollama.available, fill: Theme.sage) { EmptyView() }
            DisclosureGroup("Details", isExpanded: $showDetails) {
                AIStatusPanel().padding(.top, Theme.Space.s)
            }
            .font(Theme.body.weight(.medium))
            .foregroundStyle(Theme.textSecondary)
        }
        .task { check() }
    }

    private func check() {
        guard !checking else { return }
        checking = true
        Task { @MainActor in
            await brain.checkAI()
            await brain.resolveOpenCodeModel()
            checking = false
        }
    }
}

private struct WelcomeDoneStep: View {
    var name: String

    var body: some View {
        HStack(spacing: 28) {
            ActivityRings(study: 1, tasks: 1, reviews: 1, size: 140)
            VStack(alignment: .leading, spacing: 10) {
                Text(name.isEmpty ? "Ready when you are." : "Ready when you are, \(name).")
                    .font(Theme.title(22))
                    .foregroundStyle(Theme.textPrimary)
                Label("Earn XP for to-dos, focus and reviews", systemImage: "star.fill")
                Label("Keep a daily streak going", systemImage: "flame.fill")
                Label("Unlock badges along the way", systemImage: "rosette")
                Text("Anything you skipped is in Settings, where you can also run this again.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, Theme.Space.xs)
            }
            .font(Theme.body)
            .foregroundStyle(Theme.textSecondary)
        }
    }
}
