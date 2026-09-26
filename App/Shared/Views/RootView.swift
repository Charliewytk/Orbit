import SwiftUI
import SwiftData
import OrbitCore

/// Sidebar / tab destinations.
enum Destination: String, CaseIterable, Identifiable, Hashable {
    case today, calendar, inbox, tasks, uni, notes, plans, chat, settings
    // Mac-only feature screens (App/macOS/Features).
    case review, progress, focus, money, careers

    var id: String { rawValue }

    var title: String {
        switch self {
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
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .calendar: "calendar"
        case .inbox: "tray"
        case .tasks: "checklist"
        case .uni: "graduationcap"
        case .notes: "note.text"
        case .plans: "map"
        case .chat: "bubble.left.and.text.bubble.right"
        case .settings: "gearshape"
        case .review: "rectangle.on.rectangle.angled"
        case .progress: "chart.bar.xaxis"
        case .focus: "timer"
        case .money: "sterlingsign.circle"
        case .careers: "briefcase"
        }
    }

    /// The Mac sidebar order; ⌘1…⌘8 follow it.
    static let macSidebar: [Destination] = [.today, .calendar, .inbox, .tasks, .uni, .notes, .plans, .chat]

    /// The screen's content. Callers wrap it in a `NavigationStack`
    /// (or push it onto an existing one), so screens never nest stacks.
    @MainActor @ViewBuilder
    var screen: some View {
        switch self {
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
        #else
        case .review, .progress, .focus, .money, .careers: EmptyState(systemImage: "desktopcomputer", title: "On your Mac", message: "Open Orbit on your Mac for this.")
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
                OnboardingView { withAnimation(Motion.quick) { onboardingDone = true } }
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
    @State private var selection: Destination? = .today
    @State private var showPalette = false
    @State private var showQuickAdd = false
    @Query private var plans: [StoredPlan]
    @Query(filter: #Predicate<StoredTask> { $0.completedAt == nil }) private var openTasks: [StoredTask]
    @Query(filter: #Predicate<StoredEmailDigest> { !$0.handled }) private var unhandledMail: [StoredEmailDigest]

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                (selection ?? .today).screen
            }
            .id(selection ?? .today)
            .transition(.opacity)
            .environment(\.dedicatedTaskIDs, homeworkTaskIDs)
            .frame(minWidth: 560, minHeight: 480)
            .toolbar { toolbarContent }
        }
        .animation(Motion.fade, value: selection)
        .overlay { paletteOverlay }
        .onReceive(NotificationCenter.default.publisher(for: .orbitNavigate)) { note in
            if let d = note.object as? Destination, d != .settings { selection = d }
        }
        .onReceive(NotificationCenter.default.publisher(for: .orbitCommandPalette)) { _ in
            withAnimation(Motion.quick) { showPalette.toggle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .orbitQuickAdd)) { _ in
            showQuickAdd = true
        }
    }

    /// Homework has its own section on Today, so Due soon leaves those tasks out.
    private var homeworkTaskIDs: Set<String> {
        Set(brain.academic.homework.map { $0.taskID.uuidString })
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let now = Date()
        let cal = app.calendar
        let dueToday = openTasks.filter { t in t.deadline.map { cal.days(from: now, to: $0) <= 0 } ?? false }.count
        let recentMail = unhandledMail.filter { $0.date > now.addingTimeInterval(-7 * 86400) && $0.category != .ignore }.count
        let pendingPlans = plans.filter { $0.status == .pending && $0.start > now }.count

        return List(selection: $selection) {
            Section {
                item(.today)
                item(.calendar)
                item(.inbox, count: recentMail)
                item(.tasks, count: dueToday)
            }
            Section("University") {
                item(.uni)
                item(.notes)
            }
            Section("Personal") {
                item(.plans, count: pendingPlans)
                item(.chat)
            }
            Section("Study") {
                item(.review)
                item(.progress)
                item(.focus)
            }
            Section("Life") {
                item(.money)
                item(.careers)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BrainStatusFooter()
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
        }
    }

    private func item(_ d: Destination, count: Int = 0) -> some View {
        SidebarItem(title: d.title, systemImage: d.symbol, count: count)
            .tag(d)
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
                .frame(width: 420)
                .padding(Theme.Space.s)
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
                    .transition(.scale(scale: 0.98, anchor: .top).combined(with: .opacity))
            }
            .transition(.opacity)
        }
    }
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
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 480)
            .padding(.vertical, Theme.Space.m)
            Hairline()
            Group {
                switch tab {
                case .report: WeeklyReportView()
                case .reading: ReadingPlanView()
                case .deadlines: DeadlinesView()
                case .feedback: FeedbackThemesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
                        Image(systemName: d.symbol).frame(width: 24).foregroundStyle(Theme.textSecondary)
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
