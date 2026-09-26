import SwiftUI
import SwiftData
import OrbitCore

/// Focus mode: pick a planned block or to-do, run the timer, finish to log the minutes.
struct FocusView: View {
    @Query(sort: \StoredBlock.start) private var blocks: [StoredBlock]
    @Query(sort: \StoredTask.createdAt) private var tasks: [StoredTask]
    @State private var selectedTaskID: String?
    @State private var minutes = 25
    @State private var shortcutNames: Set<String>?
    private var hub: FeatureHub { .shared }
    private var focus: FocusController { hub.focus }

    var body: some View {
        let now = Date()
        let upcoming = blocks.filter { !$0.completed && !$0.skipped && $0.end > now && $0.start < now.addingTimeInterval(12 * 3600) }
        let open = tasks.filter { $0.completedAt == nil }.sorted { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }

        Form {
            if let session = focus.session {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(session.clock(at: ctx.date))
                                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                        }
                        Text(session.title).font(.system(size: 15))
                        Text(session.isPaused ? "Paused" : (focus.dndActive ? "Do Not Disturb is on" : "Focusing"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    HStack {
                        if session.isPaused {
                            Button("Resume") { focus.resume() }.keyboardShortcut(.space, modifiers: [])
                        } else {
                            Button("Pause") { focus.pause() }.keyboardShortcut(.space, modifiers: [])
                        }
                        Button("Finish") { focus.finish(markTaskDone: false) }.keyboardShortcut(.return, modifiers: [.command])
                        Button("Finish and mark done") { focus.finish(markTaskDone: true) }
                        Spacer()
                        Button("Discard", role: .destructive) { focus.cancel() }
                    }
                }
            } else {
                if !upcoming.isEmpty {
                    Section("Planned now and next") {
                        ForEach(upcoming.prefix(6)) { block in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(block.title)
                                    Text("\(hub.cal.time(block.start))–\(hub.cal.time(block.end))")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Start") {
                                    focus.start(task: tasks.first { $0.id == block.taskID }, block: block)
                                }
                            }
                        }
                    }
                }
                Section("Any to-do") {
                    Picker("To-do", selection: $selectedTaskID) {
                        Text("Choose…").tag(String?.none)
                        ForEach(open.prefix(60)) { t in Text(t.title).tag(String?.some(t.id)) }
                    }
                    Stepper("\(minutes) minutes", value: $minutes, in: 10...180, step: 5)
                    Button("Start focus") {
                        let task = open.first { $0.id == selectedTaskID }
                        focus.start(task: task, title: task == nil ? "Focus" : nil, minutes: minutes)
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            if let message = focus.lastMessage {
                Section { Text(message).foregroundStyle(.secondary) }
            }
            Section("Do Not Disturb") {
                Toggle("Turn on Do Not Disturb while focusing", isOn: Binding(
                    get: { FeatureSettings.bool(FeatureSettings.focusUseShortcuts, default: true) },
                    set: { FeatureSettings.defaults.set($0, forKey: FeatureSettings.focusUseShortcuts) }))
                FocusShortcutStatus(names: shortcutNames)
                Button("Check shortcuts") { Task { shortcutNames = await FocusShortcuts.installed() ?? [] } }
            }
            let learned = hub.state.learner.summary
            if !learned.isEmpty {
                Section("How long things really take") {
                    ForEach(learned, id: \.self) { Text($0) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Focus")
        .task { shortcutNames = await FocusShortcuts.installed() }
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
                Button("Finish") { focus.finish(markTaskDone: false) }
            }
        } else {
            Button("Focus on what's next") { _ = hub.startFocus(query: "", minutes: nil) }
        }
        if hub.updates.isAvailable {
            Button("Update Orbit") { Task { await hub.updates.install() } }
        }
    }
}
