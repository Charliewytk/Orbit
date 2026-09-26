import SwiftUI
import SwiftData
import OrbitCore

/// Sidebar / tab destinations.
enum Destination: String, CaseIterable, Identifiable, Hashable {
    case home, today, calendar, inbox, tasks, uni, notes, plans, chat, settings
    // Mac-only feature screens (App/macOS/Features).
    case review, progress, focus, money, careers, study
    // Companion screens (App/macOS/Companion).
    case grades, lectures, groups, briefing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .today: "Today"
        case .calendar: "Calendar"
        case .inbox: "Mail"
        case .tasks: "Tasks"
        case .uni: "Uni"
        case .notes: "Notes"
        case .plans: "Plans"
        case .chat: "Ask Orbit"
        case .settings: "Settings"
        case .review: "Flashcards"
        case .progress: "Progress"
        case .focus: "Focus"
        case .money: "Money"
        case .careers: "Careers"
        case .study: "Study Lab"
        case .grades: "Grades"
        case .lectures: "Lectures"
        case .groups: "Group work"
        case .briefing: "Briefing"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .today: "sun.max.fill"
        case .calendar: "calendar"
        case .inbox: "envelope.fill"
        case .tasks: "checklist"
        case .uni: "graduationcap.fill"
        case .notes: "note.text"
        case .plans: "map.fill"
        case .chat: "bubble.left.and.text.bubble.right.fill"
        case .settings: "gearshape.fill"
        case .review: "rectangle.on.rectangle.angled.fill"
        case .progress: "chart.bar.xaxis"
        case .focus: "timer"
        case .money: "sterlingsign.circle.fill"
        case .careers: "briefcase.fill"
        case .study: "flask.fill"
        case .grades: "chart.line.uptrend.xyaxis"
        case .lectures: "play.rectangle.fill"
        case .groups: "person.3.fill"
        case .briefing: "sunrise.fill"
        }
    }

    /// The pastel family for the screen's icon tiles and cards (ink colour).
    var color: Color {
        switch self {
        case .home, .settings: Theme.textSecondary
        case .today, .briefing, .notes: Theme.butterInk
        case .calendar, .lectures: Theme.blushInk
        case .inbox, .grades: Theme.skyInk
        case .tasks, .money, .plans: Theme.sageInk
        case .uni, .study, .review, .chat: Theme.lavenderInk
        case .progress, .focus: Theme.skyInk
        case .careers, .groups: Theme.peachInk
        }
    }

    /// The matching pastel fill.
    var pastel: Color {
        switch self {
        case .home, .settings: Theme.surface
        case .today, .briefing, .notes: Theme.butter
        case .calendar, .lectures: Theme.blush
        case .inbox, .grades, .progress, .focus: Theme.sky
        case .tasks, .money, .plans: Theme.sage
        case .uni, .study, .review, .chat: Theme.lavender
        case .careers, .groups: Theme.peach
        }
    }

    /// The Mac rail order; ⌘1…⌘8 follow it. (Ask Orbit lives on Home now.)
    static let macSidebar: [Destination] = [.home, .calendar, .tasks, .inbox, .uni, .study, .notes, .review]

    /// The screen's content. Callers wrap it in a `NavigationStack`
    /// (or push it onto an existing one), so screens never nest stacks.
    @MainActor @ViewBuilder
    var screen: some View {
        switch self {
        #if os(macOS)
        case .home: HomeView()
        #else
        case .home: TodayView()
        #endif
        case .today: TodayView()
        case .calendar: CalendarView()
        case .inbox: InboxView()
        case .tasks: TasksView()
        case .uni: UniView()
        case .notes: NotesView()
        case .plans: PlansView()
        case .chat: ChatView()
        case .settings: SettingsView()
        #if os(macOS)
        case .review: FlashcardsView()
        case .progress: ProgressScreen()
        case .focus: FocusView()
        case .money: MoneyView()
        case .careers: CareersView()
        case .study: StudyLabView()
        case .grades: GradesView()
        case .lectures: LecturesView()
        case .groups: GroupsView()
        case .briefing: BriefingView()
        #else
        case .review, .progress, .focus, .money, .careers, .study, .grades, .lectures, .groups, .briefing: EmptyState(systemImage: "desktopcomputer", title: "On your Mac", message: "Open Orbit on your Mac for this.")
        #endif
        }
    }
}

/// Light (default), dark or following the system.
enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark, system
    static let key = "orbit.appearance"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "Automatic"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
}

/// The onboarding shown once per redesign: bump `version` to show it again.
enum OnboardingFlow {
    static let versionKey = "onboardingVersion"
    static let version = 2
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("onboardingDone") private var onboardingDone = false
    @AppStorage(OnboardingFlow.versionKey) private var onboardingVersion = 0
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.light.rawValue

    var body: some View {
        Group {
            #if os(macOS)
            if onboardingVersion >= OnboardingFlow.version {
                MacRootView()
            } else {
                WelcomeFlow { withAnimation(Motion.smooth) { onboardingVersion = OnboardingFlow.version; onboardingDone = true } }
            }
            #else
            if onboardingDone {
                PhoneRootView()
            } else {
                OnboardingView { withAnimation(Motion.quick) { onboardingDone = true } }
            }
            #endif
        }
        .tint(Theme.accent)
        .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .light).scheme)
        .toastOverlay()
    }
}

#if os(macOS)
struct MacRootView: View {
    @Environment(AppModel.self) private var app
    @Environment(OrbitBrain.self) private var brain
    @State private var selection: Destination? = .home
    @State private var showPalette = false
    @State private var showQuickAdd = false
    @Query private var plans: [StoredPlan]
    @Query private var modules: [StoredModule]
    @Query(filter: #Predicate<StoredTask> { $0.completedAt == nil }) private var openTasks: [StoredTask]
    @Query(filter: #Predicate<StoredEmailDigest> { !$0.handled }) private var unhandledMail: [StoredEmailDigest]

    var body: some View {
        HStack(spacing: 0) {
            IconRail(selection: $selection, counts: counts)
            NavigationStack {
                (selection ?? .home).screen
            }
            .id(selection ?? .home)
            .transition(.opacity)
            .environment(\.dedicatedTaskIDs, homeworkTaskIDs)
            .frame(minWidth: 560, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
            .toolbar { toolbarContent }
        }
        .background(Theme.background)
        .animation(Motion.fade, value: selection)
        .overlay { paletteOverlay }
        .task(id: moduleNamesKey) { registerModuleNames() }
        .onReceive(NotificationCenter.default.publisher(for: .orbitNavigate)) { note in
            guard let d = note.object as? Destination, d != .settings else { return }
            switch d {
            case .today:
                // Today lives on the Home dashboard on the Mac.
                selection = .home
            case .chat:
                // Ask Orbit lives in Home's "Ask or tell" bar.
                selection = .home
                DispatchQueue.main.async { NotificationCenter.default.post(name: .orbitOpenAsk, object: nil) }
            default:
                selection = d
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .orbitCommandPalette)) { _ in
            withAnimation(Motion.quick) { showPalette.toggle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .orbitQuickAdd)) { _ in
            if selection == .home {
                NotificationCenter.default.post(name: .orbitFocusHomeQuickAdd, object: nil)
            } else {
                showQuickAdd = true
            }
        }
    }

    /// Homework has its own section on Home, so Due soon leaves those tasks out.
    private var homeworkTaskIDs: Set<String> {
        Set(brain.academic.homework.map { $0.taskID.uuidString })
    }

    private var moduleNamesKey: String { modules.map { "\($0.id)=\($0.name)" }.sorted().joined(separator: "|") }

    /// Teaches ModuleNames the ELE course names (English titles everywhere).
    private func registerModuleNames() {
        var names: [String: String] = [:]
        for m in modules where !m.id.isEmpty && !m.name.isEmpty { names[m.id] = m.name }
        ModuleNames.register(names)
    }

    private var counts: [Destination: Int] {
        let now = Date()
        let cal = app.calendar
        let dueToday = openTasks.filter { t in t.deadline.map { cal.days(from: now, to: $0) <= 0 } ?? false }.count
        let recentMail = unhandledMail.filter { $0.date > now.addingTimeInterval(-7 * 86400) && $0.category != .ignore }.count
        let pendingPlans = plans.filter { !$0.isTicketDrop && $0.status == .pending && $0.start > now }.count
        return [.inbox: recentMail, .tasks: dueToday, .plans: pendingPlans]
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(Motion.quick) { showPalette = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                    Text("⌘K").foregroundStyle(Theme.textTertiary)
                }
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(minWidth: 150, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Search and commands (⌘K)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showQuickAdd = true
            } label: {
                Label("Add task", systemImage: "plus")
            }
            .help("Add a task (⌘N)")
            .popover(isPresented: $showQuickAdd, arrowEdge: .bottom) {
                QuickAddField(placeholder: "Add a task, e.g. “essay plan 2h by Fri”", autofocus: true) { _ in
                    showQuickAdd = false
                }
                .frame(width: 440)
                .padding(Theme.Space.m)
            }
        }
    }

    // MARK: Command palette

    @ViewBuilder
    private var paletteOverlay: some View {
        if showPalette {
            ZStack(alignment: .top) {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(Motion.quick) { showPalette = false } }
                CommandPalette(isPresented: $showPalette)
                    .padding(.top, 88)
                    .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            }
            .transition(.opacity)
        }
    }
}

/// The slim icon-only rail: the Orbit mark, the main screens as round icons
/// (selected = a black circle), a "More" popover for the rest, then sync
/// status and Settings at the bottom. Hover for names; ↑/↓ move.
struct IconRail: View {
    @Binding var selection: Destination?
    var counts: [Destination: Int]
    @State private var showMore = false
    @FocusState private var focused: Bool

    static let primary: [Destination] = [.home, .calendar, .tasks, .inbox, .uni, .study, .notes]
    static let more: [Destination] = [.review, .grades, .lectures, .groups, .progress, .focus, .briefing, .plans, .money, .careers]
    static let width: CGFloat = 76

    var body: some View {
        VStack(spacing: 0) {
            OrbitMark(size: 34)
                .padding(.top, Theme.Space.m)
                .padding(.bottom, Theme.Space.l)
                .onTapGesture { select(.home) }
            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    ForEach(Self.primary) { d in
                        RailButton(symbol: d.symbol, title: d.title, selected: selection == d, badge: counts[d] ?? 0) { select(d) }
                    }
                    moreButton
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            Spacer(minLength: Theme.Space.s)
            RailStatusDot()
                .padding(.bottom, Theme.Space.s)
            SettingsLink {
                RailIcon(symbol: "gearshape.fill", selected: false)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .padding(.bottom, Theme.Space.m)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
    }

    private var moreButton: some View {
        let current = selection.flatMap { Self.more.contains($0) ? $0 : nil }
        return RailButton(symbol: current?.symbol ?? "square.grid.2x2.fill", title: current?.title ?? "More",
                          selected: current != nil, badge: 0) { showMore.toggle() }
            .popover(isPresented: $showMore, arrowEdge: .trailing) {
                RailMoreGrid(items: Self.more, selection: selection) { d in
                    showMore = false
                    select(d)
                }
            }
    }

    private func select(_ d: Destination) {
        withAnimation(Motion.snappy) { selection = d }
    }

    private func move(_ delta: Int) {
        let list = Self.primary + Self.more
        let index = list.firstIndex(of: selection ?? .home) ?? 0
        select(list[min(max(0, index + delta), list.count - 1)])
    }
}

/// One round rail icon (black circle when selected).
struct RailIcon: View {
    var symbol: String
    var selected: Bool
    var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(selected ? Theme.onAccent : Theme.textSecondary)
            .frame(width: 44, height: 44)
            .background(Circle().fill(selected ? Theme.accent : (hovering ? Theme.hover : Color.clear)))
            .contentShape(Circle())
    }
}

struct RailButton: View {
    var symbol: String
    var title: String
    var selected: Bool
    var badge: Int
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RailIcon(symbol: symbol, selected: selected, hovering: hovering)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 9, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(Theme.blush))
                            .overlay(Capsule().strokeBorder(Theme.sidebar, lineWidth: 1.5))
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(PressScaleStyle(scale: 0.9))
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
        .animation(Motion.snappy, value: selected)
        .help(title)
        .accessibilityLabel(title + (badge > 0 ? ", \(badge)" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The "More" popover: every other screen as a pastel tile.
struct RailMoreGrid: View {
    var items: [Destination]
    var selection: Destination?
    var onSelect: (Destination) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.fixed(120), spacing: 10), GridItem(.fixed(120), spacing: 10)], spacing: 10) {
            ForEach(items) { d in
                Button { onSelect(d) } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        IconCircle(symbol: d.symbol, size: 32)
                        Text(d.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(d.pastel))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(selection == d ? Theme.accent : .clear, lineWidth: 1.5))
                }
                .buttonStyle(PressScaleStyle(scale: 0.96))
            }
        }
        .padding(14)
    }
}

/// A small status dot for sync and the assistant (details on hover).
struct RailStatusDot: View {
    @Environment(OrbitBrain.self) private var brain

    var body: some View {
        let ok = brain.openCodeUp || brain.ollama.available
        let syncing = brain.running.first
        ZStack {
            if syncing != nil {
                ProgressView().controlSize(.small)
            } else {
                Circle().fill(ok ? Theme.success : Theme.danger).frame(width: 8, height: 8)
            }
        }
        .frame(width: 20, height: 20)
        .help(syncing.map { "Syncing \($0.title.lowercased())…" }
              ?? (brain.openCodeUp ? "OpenCode ready" : brain.ollama.available ? "Ollama ready" : "Assistant offline"))
    }
}

/// The Orbit mark: a pastel squircle with a planet and its orbit (matches the app icon).
struct OrbitMark: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Theme.pastelGradient)
            Ellipse()
                .stroke(Color(hex: 0x151515), lineWidth: size * 0.06)
                .frame(width: size * 0.72, height: size * 0.3)
                .rotationEffect(.degrees(-24))
            Circle().fill(Color(hex: 0x151515)).frame(width: size * 0.32, height: size * 0.32)
            Circle().fill(Color(hex: 0xE8849A)).frame(width: size * 0.12, height: size * 0.12)
                .offset(x: size * 0.3, y: -size * 0.14)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Orbit")
    }
}

extension Notification.Name {
    /// Open Home's Ask Orbit panel (object: an optional String to send).
    static let orbitOpenAsk = Notification.Name("orbitOpenAsk")
    static let orbitOpenPlanner = Notification.Name("orbitOpenPlanner")
}

extension Notification.Name {
    /// Focus the Home dashboard's big quick-add bar (⌘N while Home is showing).
    static let orbitFocusHomeQuickAdd = Notification.Name("orbitFocusHomeQuickAdd")
}

/// Weekly "on track" report, reading plan, deadlines and feedback themes in one place.
struct ProgressScreen: View {
    enum Tab: String, CaseIterable, Identifiable {
        case report = "On track", reading = "Reading plan", deadlines = "Deadlines", feedback = "Feedback"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .report

    var body: some View {
        VStack(spacing: 0) {
            GlassSegmented(options: Tab.allCases.map { ($0, $0.rawValue) }, selection: $tab)
                .padding(.vertical, Theme.Space.m)
            Group {
                switch tab {
                case .report: WeeklyReportView()
                case .reading: ReadingPlanView()
                case .deadlines: DeadlinesView()
                case .feedback: FeedbackThemesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
        }
        .orbitBackground()
        .navigationTitle("Progress")
    }
}
#else
struct PhoneRootView: View {
    @State private var selection: Destination = .today

    var body: some View {
        TabView(selection: $selection) {
            ForEach([Destination.today, .inbox, .tasks, .uni, .chat]) { d in
                NavigationStack { d.screen }
                    .tabItem { Label(d.title, systemImage: d.symbol) }
                    .tag(d)
            }
        }
        .haptic(selection)
        .onReceive(NotificationCenter.default.publisher(for: .orbitNavigate)) { note in
            if let d = note.object as? Destination { selection = d }
        }
    }
}
#endif

extension Notification.Name {
    /// Post with a `Destination` as the object to switch screens (menu bar, intents).
    static let orbitNavigate = Notification.Name("orbitNavigate")
}

/// Shared "More" links used on the iPhone's Today screen.
struct MoreLinks: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach([Destination.calendar, .notes, .plans, .settings]) { d in
                NavigationLink {
                    d.screen
                } label: {
                    HStack(spacing: Theme.Space.m) {
                        IconTile(symbol: d.symbol, color: d.color, size: 26)
                        Text(d.title).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                    .font(Theme.body)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if d != .settings { Hairline() }
            }
        }
        .padding(.top, Theme.Space.xl)
    }
}
