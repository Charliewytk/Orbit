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
        return [.welcome, .google, .microsoft, .ele, .notes, .ai, .prefs, .done]
        #else
        return [.welcome, .iphone, .notifications, .prefs, .done]
        #endif
    }

    @State private var index = 0
    @State private var prefs = UserPrefs()
    @State private var name = ""

    private var step: Step { steps[min(index, steps.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    Text("\(index + 1) of \(steps.count)")
                        .font(Theme.caption.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .contentTransition(.numericText())
                    content
                }
                .padding(.horizontal, Theme.Space.xxxl)
                .padding(.top, Theme.Space.xxxl)
                .padding(.bottom, Theme.Space.xl)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
                .id(step)
                .transition(.opacity)
            }

            HStack(spacing: Theme.Space.m) {
                if index > 0 {
                    Button("Back") { withAnimation(Motion.quick) { index -= 1 } }
                        .buttonStyle(SoftButtonStyle(color: Theme.textSecondary))
                }
                Spacer()
                if step != .welcome && step != .done && step != .prefs {
                    Button("Skip for now") { next() }
                        .buttonStyle(SoftButtonStyle(color: Theme.textSecondary))
                }
                Button(step == .done ? "Start using Orbit" : "Continue") { next() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.l)
            .overlay(alignment: .top) { Hairline() }
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
        withAnimation(Motion.quick) { index = min(index + 1, steps.count - 1) }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            hero(symbol: "", title: "Welcome to Orbit",
                 text: "Your calendar, tasks, email, ELE deadlines and lecture notes in one place, planned around you.")
            TextField("What should I call you?", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(Theme.large)
                .frame(maxWidth: 320)
            Text("Everything runs on free tools: OpenCode and Ollama on your Mac, and your own iCloud.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)

        #if os(macOS)
        case .google:
            hero(symbol: "envelope.badge", title: "Connect Google",
                 text: "Click Connect and sign in with your Google account in the window that opens. Orbit then brings in your Gmail and Google Calendar. It only ever writes to its own “Orbit” calendar and saves replies as drafts; it never sends email.")
            GoogleConnectRow()
            Text("No Google account? Skip this: Orbit can use the calendars on your Mac instead (next step).")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
        case .microsoft:
            hero(symbol: "building.columns", title: "Your Exeter email and timetable",
                 text: "Three quick steps. You don't need to register anything: your Mac signs in to Exeter for you, and Orbit reads from there.")
            ExeterSetupPanel()
            ExeterAdvancedOptions()
        case .ele:
            hero(symbol: "graduationcap", title: "Connect ELE",
                 text: "Sign in to ELE once, just like in your browser. Orbit then reads your modules, each week's slides, readings and tutorials, and your assessments with their weights and deadlines.")
            ELEConnectRow()
        case .notes:
            hero(symbol: "pencil.and.scribble", title: "Your OneNote notes",
                 text: "Export your OneNote notes as PDFs into one folder, then pick that folder here. Orbit reads your typed notes and your handwriting.")
            NotesSourcePicker()
        case .ai:
            hero(symbol: "", title: "Check the assistant",
                 text: "OpenCode answers first; Ollama is the backup that runs fully offline. Both are free.")
            AIStatusPanel()
        #endif

        case .iphone:
            hero(symbol: "desktopcomputer", title: "Your Mac does the thinking",
                 text: "Install Orbit on your Mac too and connect your accounts there. This iPhone shows everything in sync through iCloud, lets you add to-dos, accept plans and review flashcards, and sends chat to your Mac.")
            Text("Keep your Mac awake (or plugged in) for the quickest replies.")
                .font(Theme.body).foregroundStyle(Theme.textSecondary)
        case .notifications:
            hero(symbol: "bell.badge", title: "Stay in the loop",
                 text: "Orbit tells you about urgent mail, new deadlines and your morning brief. Nothing else.")
            Button("Allow notifications") { Task { await Notifier.requestAuthorization() } }
                .buttonStyle(.bordered)
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

    /// A big title and one short paragraph. (`symbol` is kept for call sites but not drawn.)
    private func hero(symbol: String, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.pageTitle)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(text)
                .font(Theme.large)
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Theme.Space.s)
    }
}
