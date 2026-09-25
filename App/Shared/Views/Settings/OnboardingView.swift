import SwiftUI
import OrbitCore

/// First-run tour. On the Mac it connects every account and checks the AI;
/// on the iPhone it explains that the Mac does the heavy lifting.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    var onFinish: () -> Void

    enum Step: Hashable {
        case welcome, google, microsoft, ele, notes, ai, iphone, notifications, prefs, done
    }

    private var steps: [Step] {
        #if os(macOS)
        [.welcome, .google, .microsoft, .ele, .notes, .ai, .prefs, .done]
        #else
        [.welcome, .iphone, .notifications, .prefs, .done]
        #endif
    }

    @State private var index = 0
    @State private var prefs = UserPrefs()
    @State private var name = ""

    private var step: Step { steps[min(index, steps.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i <= index ? Theme.accent : Theme.border)
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 24).padding(.top, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .padding(28)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
            }

            HStack {
                if index > 0 {
                    Button("Back") { withAnimation(Theme.spring) { index -= 1 } }
                        .buttonStyle(SoftButtonStyle(color: Theme.textSecondary))
                }
                Spacer()
                if step != .welcome && step != .done && step != .prefs {
                    Button("Skip for now") { next() }.buttonStyle(.borderless).foregroundStyle(Theme.textSecondary)
                }
                Button(step == .done ? "Start using Orbit" : "Continue") { next() }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .background(.bar)
        }
        .orbitBackground()
        .onAppear {
            prefs = app.prefs
            name = app.firstName
        }
        .haptic(index)
    }

    private func next() {
        if step == .prefs {
            app.setFirstName(name)
            app.savePrefs(prefs)
        }
        if step == .done {
            onFinish()
            return
        }
        withAnimation(Theme.spring) { index = min(index + 1, steps.count - 1) }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            hero(symbol: "circle.hexagongrid.circle", title: "Hi, I'm Orbit",
                 text: "Your calendar, to-dos, email, ELE deadlines and lecture notes in one calm place, planned around you so you can aim for a First without the stress.")
            TextField("What should I call you?", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            Label("Everything runs on free tools: OpenCode and Ollama on your Mac, and your own iCloud.", systemImage: "lock.shield")
                .font(Theme.callout).foregroundStyle(Theme.textSecondary)

        #if os(macOS)
        case .google:
            hero(symbol: "envelope.badge", title: "Connect Google",
                 text: "Gmail for your personal mail and Google Calendar for your events. Orbit only ever writes to its own “Orbit” calendar, and saves replies as drafts; it never sends email.")
            GoogleConnectRow()
        case .microsoft:
            hero(symbol: "building.columns", title: "Connect your Exeter account",
                 text: "Your Exeter Microsoft sign-in gives Orbit your uni email, calendar and OneNote. If Exeter asks for admin approval, skip this: Orbit can read Exeter mail from Apple Mail and notes from exported PDFs instead.")
            MicrosoftConnectRow()
            ExeterMailSourcePicker()
        case .ele:
            hero(symbol: "graduationcap", title: "Connect ELE",
                 text: "Orbit signs in to ELE the same way the Moodle app does, to fetch your modules, deadlines, grades and reading lists.")
            ELEConnectRow()
        case .notes:
            hero(symbol: "pencil.and.scribble", title: "Your OneNote notes",
                 text: "Orbit reads your typed notes and your handwriting, and learns your writing from the parts you type up.")
            NotesSourcePicker()
        case .ai:
            hero(symbol: "sparkles", title: "Check the AI",
                 text: "OpenCode is the main brain; Ollama is the backup that runs fully offline. Both are free.")
            AIStatusPanel()
        #endif

        case .iphone:
            hero(symbol: "desktopcomputer", title: "Your Mac does the thinking",
                 text: "Install Orbit on your Mac too and connect your accounts there. This iPhone shows everything in sync through iCloud, lets you add to-dos, accept plans and review flashcards, and sends chat to your Mac.")
            Label("Keep your Mac awake (or plugged in) for the quickest replies.", systemImage: "bolt.horizontal.circle")
                .font(Theme.callout).foregroundStyle(Theme.textSecondary)
        case .notifications:
            hero(symbol: "bell.badge", title: "Stay in the loop",
                 text: "Orbit tells you about urgent mail, new deadlines and your morning brief. Nothing else.")
            Button("Allow notifications") { Task { await Notifier.requestAuthorization() } }
                .buttonStyle(PillButtonStyle())
        case .prefs:
            hero(symbol: "slider.horizontal.3", title: "How you like to work",
                 text: "Orbit plans study around these. You can change them any time in Settings.")
            Form {
                PreferencesSections(prefs: $prefs)
            }
            .formStyle(.grouped)
            .frame(minHeight: 620)
            .scrollDisabled(true)
        case .done:
            hero(symbol: "checkmark.seal.fill", title: "You're all set",
                 text: "Orbit will sync in the background, plan your week and send your first brief tomorrow morning.")
        default:
            EmptyView()
        }
    }

    private func hero(symbol: String, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
                .symbolRenderingMode(.hierarchical)
            Text(title).font(Theme.title(30)).foregroundStyle(Theme.textPrimary)
            Text(text).font(Theme.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
