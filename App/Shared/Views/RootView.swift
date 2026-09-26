import SwiftUI
import SwiftData
import OrbitCore

/// Sidebar / tab destinations.
enum Destination: String, CaseIterable, Identifiable, Hashable {
    case home, today, calendar, inbox, tasks, uni, notes, plans, chat, settings
    // Mac-only feature screens (App/macOS/Features).
    case review, progress, focus, money, careers, study

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .today: "Today"
        case .calendar: "Calendar"
        case .inbox: "Inbox"
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
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .today: "sun.max.fill"
        case .calendar: "calendar"
        case .inbox: "tray.full.fill"
        case .tasks: "checklist"
        case .uni: "graduationcap.fill"
        case .notes: "note.text"
        case .plans: "map.fill"
        case .chat: "bubble.left.and.text.bubble.right.fill"
        case .settings: "gearshape.fill"
        case .review: "rectangle.on.rectangle.angled.fill"
        case .progress: "chart.bar.xaxis"
        case .focus: "timer"
        case .money: "sterlingsign"
        case .careers: "briefcase.fill"
        case .study: "point.3.connected.trianglepath.dotted"
        }
    }

    /// The icon tile colour (macOS Settings style).
    var color: Color {
        switch self {
        case .home: Theme.accent
        case .today: Color(hex: 0xFF9F0A)
        case .calendar: Color(hex: 0xFF3B5C)
        case .inbox: Color(hex: 0x0A84FF)
        case .tasks: Color(hex: 0xFF8A00)
        case .uni: Color(hex: 0x8B5CF6)
        case .notes: Color(hex: 0xF5B400)
        case .plans: Color(hex: 0x30C75E)
        case .chat: Color(hex: 0xEC4899)
        case .settings: Color(hex: 0x8E8E93)
        case .review: Color(hex: 0x06B6D4)
        case .progress: Color(hex: 0x14B8A6)
        case .focus: Color(hex: 0x5E5CE6)
        case .money: Color(hex: 0x22C55E)
        case .careers: Color(hex: 0xB7791F)
        case .study: Color(hex: 0x6366F1)
        }
    }

    /// The Mac sidebar order; ⌘1…⌘8 follow it.
    static let macSidebar: [Destination] = [.home, .calendar, .inbox, .tasks, .uni, .study, .notes, .plans, .chat]

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
        #else
        case .review, .progress, .focus, .money, .careers, .study: EmptyState(systemImage: "desktopcomputer", title: "On your Mac", message: "Open Orbit on your Mac for this.")
        #endif
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("onboardingDone") private var onboardingDone = false

    var body: some View {
        Group {
            if onboardingDone {
                #if os(macOS)
                MacRootView()
                #else
                PhoneRootView()
                #endif
            } else {
                #if os(macOS)
                MacOnboardingView { withAnimation(Motion.smooth) { onboardingDone = true } }
                #else
                OnboardingView { withAnimation(Motion.quick) { onboardingDone = true } }
                #endif
            }
        }
        .tint(Theme.accent)
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
    @Query(filter: #Predicate<StoredTask> { $0.completedAt == nil }) private var openTasks: [StoredTask]
    @Query(filter: #Predicate<StoredEmailDigest> { !$0.handled }) private var unhandledMail: [StoredEmailDigest]

    var body: some View {
        NavigationSplitView {
            GlassSidebar(selection: $selection, counts: counts)
                .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 290)
        } detail: {
            NavigationStack {
                (selection ?? .home).screen
            }
            .id(selection ?? .home)
            .transition(.opacity.combined(with: .scale(scale: 0.995)))
            .environment(\.dedicatedTaskIDs, homeworkTaskIDs)
            .frame(minWidth: 620, minHeight: 520)
            .toolbar { toolbarContent }
        }
        .animation(Motion.fade, value: selection)
        .overlay { paletteOverlay }
        .onReceive(NotificationCenter.default.publisher(for: .orbitNavigate)) { note in
            guard let d = note.object as? Destination, d != .settings else { return }
            // Today lives on the Home dashboard on the Mac.
            selection = d == .today ? .home : d
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

    private var counts: [Destination: Int] {
        let now = Date()
        let cal = app.calendar
        let dueToday = openTasks.filter { t in t.deadline.map { cal.days(from: now, to: $0) <= 0 } ?? false }.count
        let recentMail = unhandledMail.filter { $0.date > now.addingTimeInterval(-7 * 86400) && $0.category != .ignore }.count
        let pendingPlans = plans.filter { $0.status == .pending && $0.start > now }.count
        let dueCards = FeatureHub.shared.dailyReviewPlan(now: now).dueCount
        return [.inbox: recentMail, .tasks: dueToday, .plans: pendingPlans, .review: dueCards]
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                withAnimation(Motion.quick) { showPalette = true }
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .help("Search and commands (⌘K)")

            Button {
                showQuickAdd = true
            } label: {
                Label("Add task", systemImage: "plus")
            }
            .help("Add a task (⌘N)")
            .popover(isPresented: $showQuickAdd, arrowEdge: .bottom) {
                QuickAddField(placeholder: "Add a task, e.g. “essay plan BEM2031 2h by Fri”", autofocus: true) { _ in
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
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(Motion.quick) { showPalette = false } }
                CommandPalette(isPresented: $showPalette)
                    .padding(.top, 88)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
            .transition(.opacity)
        }
    }
}

/// The Mac sidebar: grouped rows with colour icon tiles and a sliding glass
/// capsule for the selection (no heavy accent-filled row).
struct GlassSidebar: View {
    @Binding var selection: Destination?
    var counts: [Destination: Int]
    @Namespace private var ns
    @FocusState private var focused: Bool

    static let sections: [(title: String?, items: [Destination])] = [
        (nil, [.home, .calendar, .inbox, .tasks]),
        ("University", [.uni, .notes, .review, .progress]),
        ("Focus and life", [.focus, .plans, .money, .careers]),
        ("Assistant", [.chat]),
    ]

    private var flat: [Destination] { Self.sections.flatMap(\.items) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Self.sections.indices, id: \.self) { i in
                    let section = Self.sections[i]
                    if let title = section.title {
                        Text(title.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, Theme.Space.l)
                            .padding(.bottom, 4)
                    }
                    ForEach(section.items) { d in row(d) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, Theme.Space.s)
        }
        .scrollIndicators(.never)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BrainStatusFooter()
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 8)
                .orbitGlass(in: Capsule())
                .padding(.horizontal, Theme.Space.m)
                .padding(.bottom, Theme.Space.m)
        }
    }

    private func row(_ d: Destination) -> some View {
        let selected = selection == d
        return Button {
            withAnimation(Motion.snappy) { selection = d }
        } label: {
            SidebarItem(title: d.title, systemImage: d.symbol, color: d.color, count: counts[d] ?? 0, selected: selected)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    if selected {
                        Color.clear
                            .orbitGlass(in: Capsule(), tint: d.color)
                            .matchedGeometryEffect(id: "selection", in: ns)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(SidebarRowStyle(selected: selected))
        .help(d.title)
    }

    private func move(_ delta: Int) {
        let list = flat
        let index = list.firstIndex(of: selection ?? .home) ?? 0
        let next = min(max(0, index + delta), list.count - 1)
        withAnimation(Motion.snappy) { selection = list[next] }
    }
}

/// Hover fill for sidebar rows that aren't selected.
private struct SidebarRowStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        SidebarRowBody(configuration: configuration, selected: selected)
    }

    private struct SidebarRowBody: View {
        var configuration: ButtonStyleConfiguration
        var selected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(Capsule().fill(!selected && hovering ? Theme.hover : .clear))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .onHover { hovering = $0 }
                .animation(Motion.fade, value: hovering)
        }
    }
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
