import SwiftUI
import SwiftData
import OrbitCore

/// The 21:58 shutdown ritual: a full-window glass flow.
/// (a) today's done and not-done to-dos, (b) roll-over choices, (c) tomorrow preview,
/// (d) an optional journal line, (e) the streak extended.
struct ShutdownSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \StoredEvent.start) private var events: [StoredEvent]
    @Query(sort: \StoredBlock.start) private var blocks: [StoredBlock]

    private enum Step: Int, CaseIterable { case review, rollover, tomorrow, journal, streak }
    private enum Choice: String, CaseIterable, Hashable { case tomorrow, pick, drop }

    @State private var step: Step = .review
    @State private var choices: [String: Choice] = [:]
    @State private var picked: [String: Date] = [:]
    @State private var journal = ""
    @State private var streakBefore = 0
    @State private var streakShown = 0
    @State private var ringsClosed = false
    @State private var review: (done: [StoredTask], notDone: [StoredTask]) = ([], [])
    @State private var tickedTonight: Set<String> = []

    private var routine: RoutineService { FeatureHub.shared.routine }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                Group {
                    switch step {
                    case .review: reviewStep
                    case .rollover: rolloverStep
                    case .tomorrow: tomorrowStep
                    case .journal: journalStep
                    case .streak: streakStep
                    }
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                .id(step)
            }
            footer
        }
        .frame(minWidth: 860, idealWidth: 1000, minHeight: 640, idealHeight: 760)
        .background { AmbientBackdrop().ignoresSafeArea() }
        .onAppear(perform: load)
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(symbol: "moon.stars.fill", color: Theme.violet, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Shutdown").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Theme.textPrimary)
                Text(app.calendar.format(Date(), "EEEE d MMMM") + " · two minutes, then you're done")
                    .font(Theme.body).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.hover))
                        .frame(width: s == step ? 26 : 10, height: 6)
                }
            }
            .animation(Motion.snappy, value: step)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.m)
    }

    private var footer: some View {
        HStack {
            if step != .review && step != .streak {
                Button("Back") { go(-1) }.orbitGlassButton()
            }
            Button("Later") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .opacity(step == .streak ? 0 : 1)
            Spacer()
            switch step {
            case .journal:
                Button("Finish shutdown") { finish() }
                    .orbitGlassProminentButton(Theme.violet)
                    .keyboardShortcut(.return, modifiers: [.command])
            case .streak:
                Button("Good night") { dismiss() }
                    .orbitGlassProminentButton(Theme.violet)
                    .keyboardShortcut(.defaultAction)
            default:
                Button(step == .review && review.notDone.filter({ !tickedTonight.contains($0.id) }).isEmpty ? "Next: tomorrow" : "Next") { go(1) }
                    .orbitGlassProminentButton()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.l)
        .background(.ultraThinMaterial)
    }

    private func go(_ delta: Int) {
        var next = step.rawValue + delta
        // Nothing to roll over: skip that step.
        if Step(rawValue: next) == .rollover && openTasks.isEmpty { next += delta }
        guard let s = Step(rawValue: next) else { return }
        withAnimation(Motion.smooth) { step = s }
    }

    private var openTasks: [StoredTask] { review.notDone.filter { !tickedTonight.contains($0.id) && $0.completedAt == nil } }

    // MARK: (a) Review

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            section("Done today", count: review.done.count + tickedTonight.count, color: Theme.success) {
                if review.done.isEmpty && tickedTonight.isEmpty {
                    Text("Nothing ticked off yet. Anything below you actually did?").font(Theme.body).foregroundStyle(Theme.textTertiary)
                }
                ForEach(Array(review.done.enumerated()), id: \.element.id) { i, t in
                    DoneRow(title: t.title, module: t.moduleCode, delay: Double(i) * 0.08)
                }
            }
            section("Not done", count: review.notDone.count - tickedTonight.count, color: Theme.warning) {
                if review.notDone.isEmpty {
                    Text("Everything planned for today is done.").font(Theme.body).foregroundStyle(Theme.success)
                }
                ForEach(review.notDone, id: \.id) { t in
                    HStack(spacing: Theme.Space.m) {
                        CircleCheckbox(isOn: tickedTonight.contains(t.id) || t.completedAt != nil, size: 20) {
                            if t.completedAt == nil {
                                app.toggleComplete(t)
                                tickedTonight.insert(t.id)
                            } else {
                                app.toggleComplete(t)
                                tickedTonight.remove(t.id)
                            }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(Theme.body.weight(.medium)).strikethrough(tickedTonight.contains(t.id))
                            HStack(spacing: 4) {
                                ModuleTag(code: t.moduleCode)
                                if let d = t.deadline { Text("due \(Fmt.shortDue(d, app.calendar))").font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                            }
                        }
                        Spacer()
                        OriginChip(origin: t.origin)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: (b) Roll-over

    private var rolloverStep: some View {
        section("What happens to the rest?", count: openTasks.count, color: Theme.accent) {
            ForEach(openTasks, id: \.id) { t in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(t.title).font(Theme.body.weight(.semibold))
                        Spacer()
                        ModuleTag(code: t.moduleCode)
                    }
                    HStack(spacing: Theme.Space.m) {
                        GlassSegmented(options: [(Choice.tomorrow, "Tomorrow"), (Choice.pick, "Pick a day"), (Choice.drop, "Drop")],
                                       selection: Binding(get: { choices[t.id] ?? .tomorrow }, set: { choices[t.id] = $0 }))
                        if (choices[t.id] ?? .tomorrow) == .pick {
                            DatePicker("", selection: Binding(get: { picked[t.id] ?? app.calendar.addingDays(2, to: Date()) },
                                                              set: { picked[t.id] = $0 }),
                                       in: app.calendar.addingDays(1, to: Date())..., displayedComponents: .date)
                                .labelsHidden()
                                .frame(width: 130)
                        }
                        if (choices[t.id] ?? .tomorrow) == .drop, t.origin == .required {
                            Label("Uni work: it'll still be due", systemImage: "exclamationmark.triangle.fill")
                                .font(Theme.caption).foregroundStyle(Theme.warning)
                        }
                    }
                }
                .padding(Theme.Space.m)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            }
        }
    }

    // MARK: (c) Tomorrow

    private var tomorrowStep: some View {
        let cal = app.calendar
        let tomorrow = cal.addingDays(1, to: cal.startOfDay(Date()))
        let dayEvents = events.filter { cal.isSameDay($0.start, tomorrow) }
        let items = (Agenda.items(events: events, blocks: blocks, on: tomorrow, calendar: cal)
            + Agenda.routineItems(prefs: app.prefs, events: events, on: tomorrow, calendar: cal)).map(TimeGridItem.init)
        let first = ShutdownPlanner(prefs: app.prefs).firstThing(
            tomorrowOf: Date(), events: dayEvents.map(\.value), blocks: blocks.filter { !$0.skipped }.map(\.value),
            routine: RoutinePlanner(prefs: app.prefs).blocks(on: tomorrow, events: dayEvents.map(\.value)))
        let r = app.prefs.effectiveRoutine
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                Text(cal.format(tomorrow, "EEEE")).font(Theme.sectionTitle)
                Spacer()
                if let first {
                    Label("First thing: \(first.title) at \(cal.time(first.start))", systemImage: "sunrise.fill")
                        .font(Theme.body.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
            TimeGrid(days: [tomorrow], items: items,
                     windows: TimeGridWindow.routine(prefs: app.prefs, events: dayEvents, days: [tomorrow], calendar: cal)
                        .filter { !$0.id.contains("sleep") },
                     calendar: cal, startHour: max(0, r.wakeTime / 60), endHour: min(24, r.bedtime / 60 + 1),
                     hourHeight: 26, scrolls: false) { TimeGridItemDetail(item: $0) }
                .padding(Theme.Space.s)
                .orbitGlassCard()
            Label("Bed by \(cal.time(cal.date(minute: r.bedtime, of: Date()))), up at \(cal.time(cal.date(minute: r.wakeTime, of: tomorrow))).",
                  systemImage: "bed.double.fill")
                .font(Theme.body).foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: (d) Journal

    private var journalStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("One line about today (optional)").font(Theme.sectionTitle)
            TextField("What went well, what didn't…", text: $journal, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .lineLimit(2...4)
                .padding(Theme.Space.l)
                .orbitGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous), interactive: true)
            if let last = routine.state.shutdownHistory.last(where: { $0.journal != nil }), let line = last.journal {
                Text("Last time: “\(line)”").font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: (e) Streak

    private var streakStep: some View {
        let m = FeatureHub.shared.stats.momentum(tasks: FeatureHub.shared.tasks(), blocks: blocks)
        let today = m.stats(DayKeys(timeZone: app.prefs.timeZone).key(Date()))
        return VStack(spacing: Theme.Space.xl) {
            ZStack {
                ActivityRings(study: ringsClosed ? max(1, today.studyProgress(m.goals)) : today.studyProgress(m.goals),
                              tasks: ringsClosed ? max(1, today.taskProgress(m.goals)) : today.taskProgress(m.goals),
                              reviews: ringsClosed ? max(1, today.reviewProgress(m.goals)) : today.reviewProgress(m.goals),
                              size: 200)
                VStack(spacing: 0) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(Theme.flame)
                        .symbolEffect(.bounce, value: streakShown)
                    Text("\(streakShown)")
                        .font(Theme.number(44))
                        .contentTransition(.numericText(value: Double(streakShown)))
                }
            }
            Text(streakShown > streakBefore ? "Streak extended: \(streakShown) days" : "\(streakShown)-day streak, still going")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Shutdown done. Laptop closed, book open: reading at \(app.calendar.time(app.calendar.date(minute: app.prefs.effectiveRoutine.readingStart, of: Date()))).")
                .font(Theme.body).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.xl)
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, count: Int, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text(title).font(Theme.sectionTitle).foregroundStyle(Theme.textPrimary)
                Text("\(max(0, count))").font(Theme.number(15)).foregroundStyle(color)
            }
            content()
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitGlassCard()
    }

    private func load() {
        review = routine.shutdownReview(now: Date())
        let m = FeatureHub.shared.stats.momentum(tasks: FeatureHub.shared.tasks(), blocks: blocks)
        streakBefore = m.streak(now: Date())
        streakShown = streakBefore
    }

    private func finish() {
        var out: [String: RolloverChoice] = [:]
        for t in openTasks {
            switch choices[t.id] ?? .tomorrow {
            case .tomorrow: out[t.id] = .tomorrow
            case .pick: out[t.id] = .day(picked[t.id] ?? app.calendar.addingDays(2, to: Date()))
            case .drop: out[t.id] = .drop
            }
        }
        routine.completeShutdown(choices: out, journal: journal)
        let after = FeatureHub.shared.stats.momentum(tasks: FeatureHub.shared.tasks(), blocks: blocks).streak(now: Date())
        withAnimation(Motion.smooth) { step = .streak }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.spring(response: 0.9, dampingFraction: 0.75)) { ringsClosed = true }
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(Motion.bouncy) { streakShown = max(after, streakBefore) }
        }
    }
}

/// A done row whose tick pops in, one after another.
private struct DoneRow: View {
    var title: String
    var module: String?
    var delay: Double
    @State private var shown = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            ZStack {
                Circle().fill(Theme.success.gradient).frame(width: 20, height: 20)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                CheckBurst(trigger: shown ? 1 : 0)
            }
            .scaleEffect(shown ? 1 : 0.2)
            .opacity(shown ? 1 : 0)
            Text(title).font(Theme.body.weight(.medium)).foregroundStyle(Theme.textPrimary)
            Spacer()
            ModuleTag(code: module)
        }
        .padding(.vertical, 2)
        .onAppear {
            withAnimation(Motion.bouncy.delay(0.15 + delay)) { shown = true }
        }
    }
}

/// Presents the shutdown sheet over the main window whenever `RoutineService.showShutdown` is set
/// (from the 21:58 notification, the Home banner or ⌘K).
struct ShutdownPresenter: ViewModifier {
    func body(content: Content) -> some View {
        let routine = FeatureHub.shared.routine
        let _ = routine.showShutdown // observe
        content.sheet(isPresented: Binding(get: { routine.showShutdown }, set: { routine.showShutdown = $0 })) {
            ShutdownSheet()
        }
    }
}
