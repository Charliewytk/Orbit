import SwiftUI
import SwiftData
import OrbitCore

/// Focus mode: a big circular timer. Pick a planned block or any to-do, run it,
/// finish to log the minutes (they fill the Study ring on Home).
struct FocusView: View {
    @Query(sort: \StoredBlock.start) private var blocks: [StoredBlock]
    @Query(sort: \StoredTask.createdAt) private var tasks: [StoredTask]
    @State private var selectedTaskID: String?
    @State private var minutes = 25
    @State private var shortcutNames: Set<String>?
    private var hub: FeatureHub { .shared }
    private var focus: FocusController { hub.focus }

    private static let presets = [15, 25, 45, 60, 90]

    var body: some View {
        let now = Date()
        let upcoming = blocks.filter { !$0.completed && !$0.skipped && $0.end > now && $0.start < now.addingTimeInterval(12 * 3600) }
        let open = tasks.filter { $0.completedAt == nil }.sorted { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }
        let taskByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        ScrollView {
            VStack(spacing: Theme.Space.l) {
                timerCard(open: open)
                    .staggeredAppear(0)
                if focus.session == nil && !upcoming.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            SectionHeader(title: "Planned now and next")
                            ForEach(upcoming.prefix(6)) { block in
                                let origin = taskByID[block.taskID]?.origin
                                HStack(spacing: Theme.Space.m) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill((origin?.color ?? Theme.moduleColor(block.moduleCode)).gradient)
                                        .frame(width: 4, height: 30)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(block.title).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                                        Text("\(hub.cal.time(block.start))–\(hub.cal.time(block.end))" + (origin.map { " · \($0.label)" } ?? ""))
                                            .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                                    }
                                    Spacer()
                                    if block.start <= now && block.end > now { DoNowBadge() }
                                    Button {
                                        focus.start(task: taskByID[block.taskID], block: block)
                                    } label: { Label("Start", systemImage: "play.fill") }
                                    .orbitGlassProminentButton(Destination.focus.color)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .staggeredAppear(1)
                }
                if let message = focus.lastMessage {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(Theme.body.weight(.medium))
                        .foregroundStyle(Theme.success)
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.vertical, Theme.Space.s)
                        .orbitGlass(in: Capsule(), tint: Theme.success)
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        SectionHeader(title: "Do Not Disturb")
                        Toggle("Turn on Do Not Disturb while focusing", isOn: Binding(
                            get: { FeatureSettings.bool(FeatureSettings.focusUseShortcuts, default: true) },
                            set: { FeatureSettings.defaults.set($0, forKey: FeatureSettings.focusUseShortcuts) }))
                            .toggleStyle(.switch)
                        FocusShortcutStatus(names: shortcutNames)
                        Button("Check shortcuts") { Task { shortcutNames = await FocusShortcuts.installed() ?? [] } }
                            .orbitGlassButton()
                    }
                }
                .staggeredAppear(2)
                let learned = hub.state.learner.summary
                if !learned.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionHeader(title: "How long things really take")
                            ForEach(learned, id: \.self) { Text($0).font(Theme.body).foregroundStyle(Theme.textSecondary) }
                        }
                    }
                    .staggeredAppear(3)
                }
            }
            .padding(Theme.Space.xxl)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .orbitBackground()
        .navigationTitle("Focus")
        .task { shortcutNames = await FocusShortcuts.installed() }
    }

    @ViewBuilder
    private func timerCard(open: [StoredTask]) -> some View {
        GlassCard(padding: Theme.Space.xxl, tint: focus.session == nil ? nil : Destination.focus.color) {
            VStack(spacing: Theme.Space.l) {
                if let session = focus.session {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let planned = Double((session.plannedMinutes ?? 0) * 60)
                        let progress = planned > 0 ? session.elapsed(at: ctx.date) / planned : 0
                        ZStack {
                            RingArc(progress: progress, start: Destination.focus.color, end: Theme.pink, lineWidth: 22)
                            VStack(spacing: 4) {
                                Text(session.clock(at: ctx.date))
                                    .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(Theme.textPrimary)
                                    .contentTransition(.numericText())
                                Text(session.isPaused ? "Paused" : (focus.dndActive ? "Do Not Disturb on" : "Focusing"))
                                    .font(Theme.body.weight(.semibold))
                                    .foregroundStyle(session.isPaused ? Theme.warning : Theme.textSecondary)
                            }
                        }
                        .frame(width: 300, height: 300)
                    }
                    Text(session.title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: Theme.Space.s) {
                        if session.isPaused {
                            Button { focus.resume() } label: { Label("Resume", systemImage: "play.fill") }
                                .orbitGlassProminentButton(Destination.focus.color)
                                .keyboardShortcut(.space, modifiers: [])
                        } else {
                            Button { focus.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                                .orbitGlassButton()
                                .keyboardShortcut(.space, modifiers: [])
                        }
                        Button { focus.finish(markTaskDone: false) } label: { Label("Finish", systemImage: "stop.fill") }
                            .orbitGlassButton()
                            .keyboardShortcut(.return, modifiers: [.command])
                        Button { focus.finish(markTaskDone: true) } label: { Label("Finish and tick off", systemImage: "checkmark") }
                            .orbitGlassProminentButton(Theme.success)
                        Button("Discard", role: .destructive) { focus.cancel() }
                            .buttonStyle(SoftButtonStyle(color: Theme.danger))
                    }
                    .controlSize(.large)
                } else {
                    ZStack {
                        RingArc(progress: Double(minutes) / 90, start: Destination.focus.color, end: Theme.pink, lineWidth: 22)
                        VStack(spacing: 0) {
                            Text("\(minutes)")
                                .font(.system(size: 72, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(Theme.textPrimary)
                                .contentTransition(.numericText())
                            Text("minutes").font(Theme.body.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .frame(width: 260, height: 260)
                    .animation(Motion.bouncy, value: minutes)
                    HStack(spacing: 6) {
                        ForEach(Self.presets, id: \.self) { m in
                            Button("\(m)m") { withAnimation(Motion.bouncy) { minutes = m } }
                                .buttonStyle(.plain)
                                .font(Theme.body.weight(.semibold))
                                .foregroundStyle(minutes == m ? .white : Theme.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(minutes == m ? AnyShapeStyle(Destination.focus.color.gradient) : AnyShapeStyle(Theme.hover),
                                            in: Capsule())
                        }
                        Stepper("", value: $minutes, in: 5...180, step: 5).labelsHidden()
                    }
                    Picker("To-do", selection: $selectedTaskID) {
                        Text("Just focus (no to-do)").tag(String?.none)
                        ForEach(open.prefix(60)) { t in Text(t.title).tag(String?.some(t.id)) }
                    }
                    .frame(maxWidth: 420)
                    Button {
                        let task = open.first { $0.id == selectedTaskID }
                        focus.start(task: task, title: task == nil ? "Focus" : nil, minutes: minutes)
                    } label: {
                        Label("Start focus", systemImage: "play.fill")
                            .font(Theme.large.weight(.bold))
                            .padding(.horizontal, Theme.Space.l)
                    }
                    .orbitGlassProminentButton(Destination.focus.color)
                    .controlSize(.extraLarge)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Whether the two Shortcuts exist, with the steps to make them.
struct FocusShortcutStatus: View {
    let names: Set<String>?

    var body: some View {
        let hasOn = names?.contains(FocusShortcuts.onName) ?? false
        let hasOff = names?.contains(FocusShortcuts.offName) ?? false
        if hasOn && hasOff {
            Label("“\(FocusShortcuts.onName)” and “\(FocusShortcuts.offName)” are set up.", systemImage: "checkmark.circle")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("macOS only lets apps switch Focus through Shortcuts. Make two shortcuts once:")
                Text("1. Open the Shortcuts app → File → New Shortcut. Name it “\(FocusShortcuts.onName)”.")
                Text("2. Add the action “Set Focus”, choose Do Not Disturb, set it to Turn On (Until Turned Off).")
                Text("3. Make a second shortcut “\(FocusShortcuts.offName)” with “Set Focus” → Do Not Disturb → Turn Off.")
                Text("Without them, focus sessions still work; Focus just isn't changed.")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
        }
    }
}

/// Compact focus controls for the menu bar window.
struct FocusMenuBarSection: View {
    private var hub: FeatureHub { .shared }

    var body: some View {
        let focus = hub.focus
        if let session = focus.session {
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(session.clock(at: ctx.date)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                }
                Text(session.title).lineLimit(1).foregroundStyle(.secondary)
                Spacer()
                Button(session.isPaused ? "Resume" : "Pause") { session.isPaused ? focus.resume() : focus.pause() }
                    .orbitGlassButton()
                Button("Finish") { focus.finish(markTaskDone: false) }
                    .orbitGlassProminentButton(Destination.focus.color)
            }
        } else {
            Button { _ = hub.startFocus(query: "", minutes: nil) } label: {
                Label("Focus on what's next", systemImage: "play.fill")
            }
            .orbitGlassButton()
        }
        if hub.updates.isAvailable {
            Button("Update Orbit") { Task { await hub.updates.install() } }
                .orbitGlassProminentButton()
        }
    }
}
