import SwiftUI
import SwiftData
import OrbitCore

// Settings → Routine, Health and Backups.

/// Edits `UserPrefs.routine` (synced) plus the Mac-only nudge and exam settings.
struct RoutineSettingsTab: View {
    @Environment(AppModel.self) private var app
    @State private var prefs = UserPrefs()
    @State private var loaded = false
    private var hub: FeatureHub { .shared }

    var body: some View {
        Form {
            routineSections(routine)
            nudgeSection
            examSection
        }
        .formStyle(.grouped)
        .onAppear {
            app.reloadSettings()
            prefs = app.prefs
            loaded = true
        }
        .onChange(of: prefs) { _, new in if loaded { app.savePrefs(new); hub.tasksChanged() } }
    }

    private var routine: Binding<RoutineSettings> {
        Binding(get: { prefs.effectiveRoutine }, set: { prefs.routine = $0 })
    }

    @ViewBuilder
    private func routineSections(_ r: Binding<RoutineSettings>) -> some View {
        Section {
            Toggle("Use my routine when planning", isOn: r.enabled)
            TextField("Hall", text: r.hallName)
        } header: {
            Text("Routine")
        } footer: {
            Text("Meals, reading, the shutdown and sleep are busy time: Orbit never plans work over them. They show on Calendar and Home in grey and aren't sent to Google unless you switch that on below.")
        }

        Section {
            ForEach(r.meals) { $meal in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $meal.enabled) {
                        HStack(spacing: 6) {
                            Image(systemName: meal.kind.symbol).foregroundStyle(Theme.routine)
                            Text(meal.name).font(Theme.body.weight(.semibold))
                            Text(Self.days(meal.weekdays)).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    if meal.enabled {
                        HStack {
                            MinutePicker(title: "Opens", minutes: $meal.windowStart)
                            MinutePicker(title: "Closes", minutes: $meal.windowEnd)
                        }
                        HStack {
                            MinutePicker(title: "Ideally at", minutes: $meal.preferredStart)
                            Stepper("\(meal.mealMinutes) min", value: $meal.mealMinutes, in: 15...90, step: 5)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Button("Reset to Holland Hall times") { r.wrappedValue.meals = RoutineSettings.hollandHallMeals }
        } header: {
            Text("Hall meals")
        } footer: {
            Text("Each meal is a window. Orbit books \(r.wrappedValue.meals.first?.mealMinutes ?? 45) minutes inside it at the best time around your classes and the walk back, and nudges you before it closes.")
        }

        Section("Travel") {
            Stepper("Hall ↔ campus: \(r.wrappedValue.travel.travelMinutes) min", value: r.travel.travelMinutes, in: 5...40, step: 5)
            Stepper("Between buildings: \(r.wrappedValue.travel.walkMinutes) min", value: r.travel.walkMinutes, in: 0...15)
            Stepper("Stay on campus for gaps up to \(r.wrappedValue.travel.campusGapMinutes) min", value: r.travel.campusGapMinutes, in: 30...180, step: 15)
            TextField("Study spot on campus", text: r.travel.campusStudySpot)
        }

        Section {
            Toggle("Read (book)", isOn: r.readingEnabled)
            if r.wrappedValue.readingEnabled {
                MinutePicker(title: "Reading starts", minutes: r.readingStart)
                Stepper("\(r.wrappedValue.readingMinutes) min", value: r.readingMinutes, in: 5...60, step: 5)
            }
            Toggle("Daily shutdown ritual", isOn: r.shutdownEnabled)
            if r.wrappedValue.shutdownEnabled {
                MinutePicker(title: "Shutdown at", minutes: r.shutdownTime)
            }
        } header: {
            Text("Evening")
        } footer: {
            Text("No uni work is planned after the shutdown.")
        }

        Section {
            Toggle("Protect my sleep", isOn: r.protectSleep)
            MinutePicker(title: "Target bedtime", minutes: r.bedtime)
            MinutePicker(title: "Wake up", minutes: r.wakeTime)
            Stepper("Getting ready: \(r.wrappedValue.morningPrepMinutes) min", value: r.morningPrepMinutes, in: 0...60, step: 5)
        } header: {
            Text("Sleep")
        } footer: {
            Text("Nothing is scheduled between bedtime and wake-up (plus getting ready). The morning brief shows your sleep window. Gym sessions will slot in here later.")
        }

        Section {
            Toggle("Type-up block after every lecture and tutorial", isOn: r.typeUpEnabled)
            Stepper("\(r.wrappedValue.typeUpMinutes) min", value: r.typeUpMinutes, in: 10...60, step: 5)
            Stepper("Remove if not done after \(r.wrappedValue.typeUpExpiryDays) days", value: r.typeUpExpiryDays, in: 1...7)
        } header: {
            Text("Type-ups")
        } footer: {
            Text("Planned straight after the session in the library when there's room before your next class, otherwise back at the hall. Ticked off automatically when a typed note for that module and week appears in your Library.")
        }

        Section {
            Toggle("Also put meals and reading on Google Calendar", isOn: r.pushRoutineToGoogle)
        } footer: {
            Text("Off by default. Written to the Orbit calendar a day ahead, marked free.")
        }
    }

    // MARK: Nudges

    private var nudgeSettings: Binding<NudgeSettings> {
        Binding(get: { hub.nudges.settings }, set: { hub.nudges.settings = $0 })
    }

    private var nudgeSection: some View {
        let s = nudgeSettings
        return Section {
            Toggle("Proactive nudges", isOn: s.enabled)
            if s.wrappedValue.enabled {
                ForEach(NudgeKind.allCases) { kind in
                    Toggle(kind.label, isOn: Binding(
                        get: { !s.wrappedValue.disabledKinds.contains(kind) },
                        set: { on in
                            if on { s.wrappedValue.disabledKinds.remove(kind) } else { s.wrappedValue.disabledKinds.insert(kind) }
                        }))
                }
                Stepper("At most \(s.wrappedValue.maxPerDay) a day", value: s.maxPerDay, in: 1...15)
                MinutePicker(title: "Quiet from", minutes: s.quietStart)
                MinutePicker(title: "Quiet until", minutes: s.quietEnd)
            }
        } header: {
            Text("Nudges")
        } footer: {
            Text("Never during focus sessions, classes, meals or quiet hours (the shutdown and reading reminders still come). Checked every 5 minutes.")
        }
    }

    // MARK: Exam mode

    private var examSection: some View {
        let routine = hub.routine
        return Section {
            Picker("Exam mode", selection: Binding(get: { routine.state.examManual }, set: { v in routine.update { $0.examManual = v } })) {
                Text("Automatic").tag(ExamMode.Manual.auto)
                Text("On").tag(ExamMode.Manual.on)
                Text("Off").tag(ExamMode.Manual.off)
            }
            Stepper("Switch on \(routine.state.examWithinDays) days before an exam",
                    value: Binding(get: { routine.state.examWithinDays }, set: { v in routine.update { $0.examWithinDays = v } }), in: 7...70, step: 7)
            Button("Re-plan revision now") { hub.exam.planRevision(force: true) }
        } header: {
            Text("Exam mode")
        } footer: {
            Text("Home becomes an exam dashboard: countdowns, revision progress, past papers and weak topics. Revision sessions are planned around your routine.")
        }
    }

    static func days(_ set: Set<Int>) -> String {
        if set == [2, 3, 4, 5, 6] { return "Mon–Fri" }
        if set == [1, 7] { return "Sat–Sun" }
        let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return set.sorted().map { names[$0] }.joined(separator: ", ")
    }
}

// MARK: - Health

struct HealthSettingsTab: View {
    private var health: HealthService { FeatureHub.shared.health }

    var body: some View {
        Form {
            Section {
                ForEach(health.rows) { row in HealthRowView(row: row) }
                if health.rows.isEmpty { ProgressView().frame(maxWidth: .infinity) }
            } header: {
                HStack {
                    Text("Connections and jobs")
                    Spacer()
                    if let at = health.checkedAt {
                        Text("Checked \(at.formatted(date: .omitted, time: .shortened))").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Button("Check again") { Task { await health.refresh() } }
                        .disabled(health.checking)
                }
            }
        }
        .formStyle(.grouped)
        .task { await health.refresh() }
    }
}

struct HealthRowView: View {
    var row: HealthRow
    @State private var fixing = false

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            IconTile(symbol: row.symbol, color: color, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    StatusDot(color: color)
                    Text(row.title).font(Theme.body.weight(.semibold))
                }
                Text(row.detail).font(Theme.caption).foregroundStyle(row.level == .ok ? Theme.textSecondary : color).lineLimit(2)
                Text(row.lastOK.map { "Last OK \($0.formatted(.relative(presentation: .named)))" } ?? "No successful sync yet")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: Theme.Space.s)
            if let title = row.fixTitle, let fix = row.fix {
                Button {
                    fixing = true
                    Task {
                        await fix()
                        await FeatureHub.shared.health.refresh()
                        fixing = false
                    }
                } label: {
                    if fixing { ProgressView().controlSize(.small) } else { Text(row.level == .ok ? title : "Fix: \(title)") }
                }
                .orbitGlassButton()
                .disabled(fixing)
            }
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch row.level {
        case .ok: Theme.success
        case .warning: Theme.warning
        case .broken: Theme.danger
        }
    }
}

// MARK: - Backups

struct BackupSettingsTab: View {
    private var backups: BackupService { FeatureHub.shared.backups }
    private var routine: RoutineService { FeatureHub.shared.routine }

    var body: some View {
        let dest = backups.destination
        Form {
            Section {
                LabeledContent("Last backup") {
                    if let last = backups.lastBackup {
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("Never").foregroundStyle(Theme.warning)
                    }
                }
                LabeledContent("Location") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(dest.label)
                        Text(dest.url.path).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
                if let err = backups.lastError {
                    Text(err).font(Theme.caption).foregroundStyle(Theme.danger)
                }
                if !backups.status.isEmpty {
                    Text(backups.status).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
                HStack {
                    Button {
                        Task { await backups.backUp() }
                    } label: {
                        if backups.running { ProgressView().controlSize(.small) } else { Text("Back up now") }
                    }
                    .orbitGlassProminentButton()
                    .disabled(backups.running)
                    Button("Restore…") { Task { await backups.restoreInteractively() } }
                        .orbitGlassButton()
                        .disabled(backups.restoring)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([dest.url]) }
                        .orbitGlassButton()
                }
            } header: {
                Text("Nightly backups")
            } footer: {
                Text("Every night at 03:00 (or the next time Orbit opens). Keeps the last 14 days and 8 weekly backups. Sign-ins, tokens and API keys are never included.")
            }

            Section("What's included") {
                LabeledContent("Tasks, study blocks, notes list, flashcards, stats and streak history, routine, preferences, careers watchlist, money categories") {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                }
                Toggle("Typed notes folder", isOn: Binding(get: { routine.state.backupIncludeTypedNotes },
                                                           set: { v in routine.update { $0.backupIncludeTypedNotes = v } }))
                Toggle("Course knowledge base (large)", isOn: Binding(get: { routine.state.backupIncludeKnowledge },
                                                                      set: { v in routine.update { $0.backupIncludeKnowledge = v } }))
            }

            Section("Folder") {
                Button("Choose a different folder…") { backups.chooseFolder() }
                if routine.state.backupFolder != nil {
                    Button("Use Google Drive / OneDrive automatically") { backups.useAutomaticFolder() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
