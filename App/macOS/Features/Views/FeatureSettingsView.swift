import AppKit
import SwiftUI
import OrbitCore

/// Settings for the features: quick capture, focus, deadline alerts, reading, flashcards, updates.
struct FeatureSettingsView: View {
    private var hub: FeatureHub { .shared }
    @State private var recording = false
    @State private var monitor: Any?
    @State private var shortcutNames: Set<String>?

    var body: some View {
        Form {
            Section {
                Toggle("Quick capture from anywhere", isOn: setting(FeatureSettings.quickCaptureEnabled, default: true) {
                    hub.capture.registerFromSettings()
                })
                LabeledContent("Shortcut") {
                    HStack {
                        Text(recording ? "Press the new shortcut…" : hub.capture.shortcutLabel)
                            .font(.system(size: 13, design: .monospaced))
                        Button(recording ? "Cancel" : "Change…") { recording ? stopRecording() : startRecording() }
                        Button("Reset") { hub.capture.resetShortcut() }
                    }
                }
                if !hub.capture.registered && FeatureSettings.bool(FeatureSettings.quickCaptureEnabled, default: true) {
                    Text("That shortcut is taken by another app. Pick another one.").font(.system(size: 11)).foregroundStyle(.red)
                }
            } header: {
                Text("Quick capture")
            } footer: {
                Text("Type a to-do and press Return. Start with “e:” for a calendar event (e: dinner Fri 7pm @ Côte) or “n:” for a note. Esc closes.")
            }

            Section("Focus") {
                Toggle("Turn on Do Not Disturb while focusing", isOn: setting(FeatureSettings.focusUseShortcuts, default: true))
                FocusShortcutStatus(names: shortcutNames)
                Button("Check shortcuts") { Task { shortcutNames = await FocusShortcuts.installed() ?? [] } }
            }

            Section {
                Toggle("Deadline reminders", isOn: setting(FeatureSettings.deadlineAlertsEnabled, default: true))
                Toggle("Quiet hours", isOn: setting(FeatureSettings.quietEnabled, default: true))
                DatePicker("Quiet from", selection: minuteBinding(FeatureSettings.quietStart, default: 23 * 60), displayedComponents: .hourAndMinute)
                DatePicker("Quiet until", selection: minuteBinding(FeatureSettings.quietEnd, default: 8 * 60), displayedComponents: .hourAndMinute)
            } header: {
                Text("Deadlines")
            } footer: {
                Text("Reminders 72 hours, 24 hours and 3 hours before each assessment, homework or to-do deadline, and 1 hour before if it isn't marked submitted. Reminders due in quiet hours come just before or just after.")
            }

            Section {
                Toggle("Split readings into daily sessions", isOn: setting(FeatureSettings.readingPlannerEnabled, default: true))
                Button("Re-plan reading now") { Task { await hub.planReadingIfNeeded(now: Date(), force: true) } }
            } header: {
                Text("Reading")
            } footer: {
                Text("Readings for each week are estimated (about 2 minutes a page; a chapter is about 30 pages), split into sessions of up to 45 minutes and planned on the days before the lecture or tutorial they're for.")
            }

            Section("Flashcards") {
                Toggle("Make cards from new slides and notes (local AI)", isOn: setting(FeatureSettings.flashcardGenerationEnabled, default: true))
                Toggle("Add a 10-minute review to each day's plan", isOn: setting(FeatureSettings.dailyReviewTaskEnabled, default: true))
            }

            UpdateSettingsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Extras")
        .task { shortcutNames = await FocusShortcuts.installed() }
        .onDisappear(perform: stopRecording)
    }

    private func setting(_ key: String, default value: Bool, onChange: @escaping () -> Void = {}) -> Binding<Bool> {
        Binding(get: { FeatureSettings.bool(key, default: value) },
                set: { FeatureSettings.defaults.set($0, forKey: key); onChange() })
    }

    private func minuteBinding(_ key: String, default value: Int) -> Binding<Date> {
        let cal = hub.cal
        return Binding(
            get: { cal.date(minute: FeatureSettings.int(key, default: value), of: Date()) },
            set: { FeatureSettings.defaults.set(cal.minuteOfDay($0), forKey: key) })
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Swallow every key while recording; the handler runs on the main thread.
            let code = event.keyCode
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let characters = event.charactersIgnoringModifiers
            MainActor.assumeIsolated { recorded(code: code, flags: flags, characters: characters) }
            return nil
        }
    }

    private func recorded(code: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        if code == 53 { stopRecording(); return } // Esc
        guard !flags.isEmpty else { return }       // needs at least one modifier
        hub.capture.setShortcut(keyCode: code, flags: flags, characters: characters)
        stopRecording()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

/// Updates: what's running, what's out, and the install button.
struct UpdateSettingsSection: View {
    private var updates: UpdateService { FeatureHub.shared.updates }

    var body: some View {
        Section {
            LabeledContent("This version", value: updates.currentShortSHA)
            Text(updates.statusText).foregroundStyle(.secondary)
            HStack {
                Button("Check now") { Task { await updates.check(reason: "manual") } }
                if updates.isAvailable {
                    Button("Install update and restart") { Task { await updates.install() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Orbit checks GitHub for a newer build when it starts and every 6 hours. Installing downloads it, replaces \(updates.destinationPath) and reopens Orbit.")
        }
    }
}
