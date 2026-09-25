import SwiftUI
import SwiftData

/// Sidebar / tab destinations.
enum Destination: String, CaseIterable, Identifiable, Hashable {
    case today, inbox, tasks, uni, notes, plans, chat, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .inbox: "Inbox"
        case .tasks: "Tasks"
        case .uni: "Uni"
        case .notes: "Notes"
        case .plans: "Plans"
        case .chat: "Chat"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.horizon"
        case .inbox: "tray"
        case .tasks: "checklist"
        case .uni: "graduationcap"
        case .notes: "pencil.and.scribble"
        case .plans: "person.2"
        case .chat: "bubble.left.and.bubble.right"
        case .settings: "gearshape"
        }
    }

    /// The screen's content. Callers wrap it in a `NavigationStack`
    /// (or push it onto an existing one), so screens never nest stacks.
    @MainActor @ViewBuilder
    var screen: some View {
        switch self {
        case .today: TodayView()
        case .inbox: InboxView()
        case .tasks: TasksView()
        case .uni: UniView()
        case .notes: NotesView()
        case .plans: PlansView()
        case .chat: ChatView()
        case .settings: SettingsView()
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
                OnboardingView { withAnimation(Theme.spring) { onboardingDone = true } }
            }
        }
        .tint(Theme.accent)
        .banner(app.banner)
    }
}

#if os(macOS)
struct MacRootView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: Destination? = .today
    @Query private var plans: [StoredPlan]

    private var pendingPlans: Int { plans.filter { $0.status == .pending }.count }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach([Destination.today, .inbox, .tasks, .uni, .notes, .plans, .chat]) { d in
                        Label(d.title, systemImage: d.symbol)
                            .badge(d == .plans ? pendingPlans : 0)
                            .tag(d)
                    }
                }
                Section {
                    Label(Destination.settings.title, systemImage: Destination.settings.symbol).tag(Destination.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { BrainStatusFooter().padding(10) }
        } detail: {
            NavigationStack {
                (selection ?? .today).screen
            }
            .id(selection ?? .today)
            .frame(minWidth: 520, minHeight: 480)
        }
        .onReceive(NotificationCenter.default.publisher(for: .orbitNavigate)) { note in
            if let d = note.object as? Destination { selection = d }
        }
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
        Card {
            VStack(spacing: 0) {
                ForEach([Destination.notes, .plans, .settings]) { d in
                    NavigationLink {
                        d.screen
                    } label: {
                        HStack {
                            Image(systemName: d.symbol).frame(width: 26).foregroundStyle(Theme.accent)
                            Text(d.title).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if d != .settings { Divider() }
                }
            }
        }
    }
}
