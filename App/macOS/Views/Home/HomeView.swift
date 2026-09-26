import SwiftUI
import SwiftData
import OrbitCore

/// Home: a calm, light dashboard with at most six things on it: the greeting
/// (level and streak), the "Ask or tell Orbit" box, today's activities as pastel
/// cards, three big stat tiles, the schedule with a mini month, and today's
/// to-dos. Everything else is one click away (the "Jump to" chips, the rail).
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \StoredEvent.start) private var events: [StoredEvent]
    @Query(sort: \StoredBlock.start) private var blocks: [StoredBlock]
    @Query private var tasks: [StoredTask]
    @Query private var assessments: [StoredAssessment]
    @State private var showLighten = false
    @State private var confetti = 0

    var body: some View {
        TimelineView(.everyMinute) { context in
            HomeContent(ctx: HomeContext(now: context.date, calendar: app.calendar, events: events, blocks: blocks,
                                         tasks: tasks, assessments: assessments),
                        confetti: $confetti)
        }
        .overlay { ConfettiView(trigger: confetti).ignoresSafeArea() }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Reshuffle my plan") { replan() }
                    Button("Lighten today…") { showLighten = true }
                    Divider()
                    Button("Sync now") { Task { await app.backend.syncNow() } }
                } label: {
                    Label("Plan", systemImage: "wand.and.rays")
                }
                .help("Reshuffle, lighten or sync")
            }
        }
        .confirmationDialog("How much lighter?", isPresented: $showLighten, titleVisibility: .visible) {
            Button("A little (move a quarter)") { lighten(0.25) }
            Button("Half") { lighten(0.5) }
            Button("Most of it") { lighten(0.75) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Orbit moves the rest of today's planned work to later days.")
        }
    }

    private func replan() {
        Task {
            await app.backend.requestReplan()
            app.show("Reshuffled your plan")
        }
    }

    private func lighten(_ fraction: Double) {
        Task {
            await app.backend.lighten(day: Date(), fraction: fraction)
            app.show("Lightened today")
        }
    }
}

/// The page itself. Reflows with the window: adaptive grids, no measured widths.
struct HomeContent: View {
    @Environment(AppModel.self) private var app
    var ctx: HomeContext
    @Binding var confetti: Int
    private var hub: FeatureHub { .shared }
    private static let badgesSeenKey = "orbit.badgesSeen"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HomeGreeting(ctx: ctx)
                if let nudge = hub.nudges.banner {
                    NudgeBanner(nudge: nudge)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                AskTellBar()
                if hub.exam.isActive(now: ctx.now) {
                    ExamSection(now: ctx.now)
                }
                ActivitiesSection(ctx: ctx)
                StatTilesRow(ctx: ctx)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 20, alignment: .top)],
                          alignment: .leading, spacing: 20) {
                    ScheduleCard(ctx: ctx)
                    TodosCard(ctx: ctx)
                }
                JumpToRow()
            }
            .padding(.horizontal, 28)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, Theme.Space.xxxl)
            .frame(maxWidth: 1320)
            .frame(maxWidth: .infinity)
            .animation(Motion.smooth, value: hub.nudges.banner?.id)
        }
        .scrollIndicators(.automatic)
        .onChange(of: ctx.allTodosDone) { _, done in
            guard done else { return }
            confetti += 1
            OrbitSound.celebrate()
            app.show("Every to-do done today. Lovely work.")
        }
        .task(id: ctx.summary.earned.count) { celebrateNewBadges() }
    }

    /// A new badge: a toast and a little confetti, once.
    private func celebrateNewBadges() {
        let defaults = UserDefaults.standard
        let seen = Set(defaults.stringArray(forKey: Self.badgesSeenKey) ?? [])
        let earned = ctx.summary.earned
        let fresh = Gamification.newlyEarned(before: seen, now: earned)
        defaults.set(earned.map(\.rawValue), forKey: Self.badgesSeenKey)
        // The first run only records what's already earned.
        guard !seen.isEmpty || defaults.bool(forKey: Self.badgesSeenKey + ".init"), let badge = fresh.first else {
            defaults.set(true, forKey: Self.badgesSeenKey + ".init")
            return
        }
        confetti += 1
        OrbitSound.celebrate()
        app.show("New badge: \(badge.title)")
    }
}

/// Exam mode keeps its own width, so resizing doesn't redraw the rest of Home.
private struct ExamSection: View {
    var now: Date
    @State private var width: CGFloat = 1000

    var body: some View {
        ExamDashboard(width: width, now: now)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

// MARK: - Shared data for the cards

/// Everything the cards derive from the store, computed once per render of Home
/// (Home re-renders once a minute and when the store changes, not on resize).
struct HomeContext {
    let now: Date
    let calendar: DayCalendar
    let today: [AgendaItem]
    let tomorrow: [AgendaItem]
    let next: AgendaItem?
    let todos: [StoredTask]
    let due: [DueEntry]
    let taskByID: [String: StoredTask]
    let blockByID: [String: StoredBlock]
    let momentum: Momentum
    let summary: ProgressSummary
    /// Day keys ("2026-09-26") with at least one event, around this month (for the mini calendar).
    let busyDays: Set<String>
    let openTaskCount: Int

    var allTodosDone: Bool { !todos.isEmpty && todos.allSatisfy(\.isDone) }
    var timedToday: [AgendaItem] { today.filter { !$0.isAllDay } }

    @MainActor
    init(now: Date, calendar: DayCalendar, events: [StoredEvent], blocks: [StoredBlock], tasks: [StoredTask],
         assessments: [StoredAssessment]) {
        self.now = now
        self.calendar = calendar
        // The routine (hall meals, reading, shutdown) sits alongside, in its neutral colour.
        let prefs = FeatureHub.shared.prefs
        let tomorrowDay = calendar.addingDays(1, to: now)
        let order: (AgendaItem, AgendaItem) -> Bool = {
            ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title)
        }
        today = (Agenda.items(events: events, blocks: blocks, on: now, calendar: calendar)
            + Agenda.routineItems(prefs: prefs, events: events, on: now, calendar: calendar)).sorted(by: order)
        tomorrow = (Agenda.items(events: events, blocks: blocks, on: tomorrowDay, calendar: calendar)
            + Agenda.routineItems(prefs: prefs, events: events, on: tomorrowDay, calendar: calendar)).sorted(by: order)
        next = Agenda.nextUp(events: events, blocks: blocks, now: now, calendar: calendar)
        due = Agenda.dueSoon(tasks: tasks, assessments: assessments, now: now, days: 14)
        var byID: [String: StoredTask] = [:]
        var open = 0
        var typeUps = 0
        for t in tasks {
            byID[t.id] = t
            if t.completedAt == nil { open += 1 }
            else if t.sourceRef?.hasPrefix(RoutineService.typeUpRefPrefix) == true { typeUps += 1 }
        }
        taskByID = byID
        openTaskCount = open
        var bByID: [String: StoredBlock] = [:]
        for b in blocks { bByID[b.id] = b }
        blockByID = bByID

        // Today's to-dos: due by tonight, planned today, or ticked off today.
        let endOfDay = calendar.endOfDay(now)
        let plannedToday = Set(blocks.lazy.filter { !$0.skipped && calendar.isSameDay($0.start, now) }.map(\.taskID))
        todos = tasks.filter { t in
            if let done = t.completedAt { return calendar.isSameDay(done, now) }
            if let d = t.deadline, d < endOfDay { return true }
            return plannedToday.contains(t.id)
        }
        .sorted { a, b in
            if a.isDone != b.isDone { return !a.isDone }
            return (a.deadline ?? .distantFuture, a.createdAt) < (b.deadline ?? .distantFuture, b.createdAt)
        }
        let m = FeatureHub.shared.stats.momentum(tasks: tasks, blocks: blocks)
        momentum = m
        summary = Gamification.summary(momentum: m, typeUps: typeUps, now: now)

        // Busy days for the mini calendar: events from ~6 weeks back to ~10 weeks ahead.
        let from = calendar.addingDays(-42, to: now), to = calendar.addingDays(70, to: now)
        let keys = DayKeys(timeZone: calendar.timeZone)
        var busy = Set<String>()
        for e in events where e.start >= from && e.start <= to { busy.insert(keys.key(e.start)) }
        busyDays = busy
    }

    func origin(of item: AgendaItem) -> TaskOrigin? {
        guard let id = item.blockID, let block = blockByID[id], let task = taskByID[block.taskID] else { return nil }
        return task.origin
    }
}

extension AgendaItem {
    /// An SF Symbol for the row / card.
    var symbol: String {
        switch kind {
        case .routine:
            let t = title.lowercased()
            if t.contains("breakfast") || t.contains("lunch") || t.contains("dinner") || t.contains("meal") { return "fork.knife" }
            if t.contains("read") { return "book.fill" }
            if t.contains("shutdown") { return "moon.stars.fill" }
            if t.contains("gym") { return "figure.run" }
            return "sparkles"
        case .block:
            return moduleCode.map { ModuleNames.symbol(for: $0) } ?? "brain.head.profile"
        case .event:
            let t = title.lowercased()
            if t.contains("lecture") { return "person.wave.2.fill" }
            if t.contains("tutorial") || t.contains("seminar") || t.contains("workshop") { return "person.3.fill" }
            if t.contains("exam") || t.contains("test") { return "pencil.and.list.clipboard" }
            if moduleCode != nil { return ModuleNames.symbol(for: moduleCode) }
            return "calendar"
        }
    }
}

// MARK: - Greeting

struct HomeGreeting: View {
    @Environment(AppModel.self) private var app
    @Environment(OrbitBrain.self) private var brain
    var ctx: HomeContext
    @State private var showProgress = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Space.l) {
                titleBlock
                Spacer(minLength: Theme.Space.l)
                pills
            }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                titleBlock
                pills
            }
        }
        .padding(.top, Theme.Space.m)
        .sheet(isPresented: $showProgress) { ProgressSheet(ctx: ctx) }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.s) {
                Text(ctx.calendar.format(ctx.now, "EEEE d MMMM"))
                    .font(Theme.body.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                if let w = brain.academic.currentWeek {
                    Tag(text: "Week \(w.week)\(w.isReadingWeek ? " · Reading week" : "")", color: Theme.textSecondary,
                        systemImage: "graduationcap.fill")
                }
            }
            Text(greeting)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var greeting: String {
        let hour = ctx.calendar.minuteOfDay(ctx.now) / 60
        let name = app.firstName
        let lead = hour < 5 ? "Still up" : hour < 12 ? "Good morning" : hour < 18 ? "Welcome back" : "Good evening"
        return lead + (name.isEmpty ? "" : ", \(name)") + " 👋"
    }

    private var pills: some View {
        HStack(spacing: Theme.Space.s) {
            Button { showProgress = true } label: {
                LevelPill(level: ctx.summary.level, todayXP: ctx.summary.todayXP)
            }
            .buttonStyle(PressScaleStyle(scale: 0.96))
            .help("Your level, badges and rings")
            StreakPill(streak: ctx.summary.streak, todayCounts: ctx.momentum.todayCounts(now: ctx.now))
            HealthPill()
        }
    }
}

/// "Lv 4 · 60%" with a thin progress bar.
struct LevelPill: View {
    var level: LevelInfo
    var todayXP: Int

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.lavender)
                Text("\(level.level)").font(Theme.number(15)).foregroundStyle(Theme.textPrimary)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(level.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                ThinProgressBar(value: level.progress, color: Theme.lavenderInk, height: 5)
                    .frame(width: 96)
            }
            if todayXP > 0 {
                Text("+\(todayXP) XP")
                    .font(Theme.number(11, weight: .semibold))
                    .foregroundStyle(Theme.sageInk)
                    .contentTransition(.numericText())
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 14)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Level \(level.level), \(level.xpToNext) XP to the next level")
    }
}

/// The flame and the streak count.
struct StreakPill: View {
    var streak: Int
    var todayCounts: Bool
    @State private var flicker = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(streak > 0 ? AnyShapeStyle(Theme.flame) : AnyShapeStyle(Theme.textTertiary))
                .scaleEffect(flicker ? 1.08 : 0.96)
            Text("\(streak)")
                .font(Theme.number(17))
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
            Text("day\(streak == 1 ? "" : "s")")
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(streak > 0 ? Theme.peach : Theme.surface))
        .help(todayCounts ? "Today counts. Keep it going tomorrow." : "Do anything today (a to-do, 10 minutes of focus or 5 cards) to keep your streak.")
        .onAppear {
            guard streak > 0 else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { flicker = true }
        }
    }
}

// MARK: - Ask or tell

/// One box for asking and telling: questions go to the assistant (a conversation
/// sheet opens in place), anything else becomes a to-do. ⌘N focuses it; ⌥Space
/// quick capture sends questions here too.
struct AskTellBar: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var added = 0
    @State private var showChat = false
    @FocusState private var focused: Bool

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let mode = AskOrTell.classify(trimmed)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                ZStack {
                    Circle().fill(Theme.lavender).frame(width: 36, height: 36)
                    Image(systemName: mode == .ask && !trimmed.isEmpty ? "sparkles" : "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.symbolEffect(.replace))
                    CheckBurst(trigger: added)
                }
                TextField("Ask or tell Orbit…  “what's due this week?”  ·  “essay plan 2h by Fri”", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .medium))
                    .focused($focused)
                    .onSubmit { submit(mode) }
                    .onExitCommand { text = ""; focused = false }
                if trimmed.isEmpty {
                    Button { showChat = true } label: {
                        Label("Conversation", systemImage: "bubble.left.and.text.bubble.right.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open the conversation")
                    KeyHint(keys: "⌘N")
                } else {
                    actionButtons(mode)
                }
            }
            if !trimmed.isEmpty && mode == .tell {
                ParsedChips(result: app.parse(text))
                    .padding(.leading, 36 + Theme.Space.m)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(focused ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: focused ? 1.5 : 1))
        .animation(Motion.fade, value: focused)
        .animation(Motion.snappy, value: trimmed.isEmpty)
        .onReceive(NotificationCenter.default.publisher(for: .orbitFocusHomeQuickAdd)) { _ in focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .orbitOpenAsk)) { note in
            if let q = note.object as? String { ask(q) } else { showChat = true }
        }
        .sheet(isPresented: $showChat) { AskSheet() }
    }

    private func actionButtons(_ mode: AskOrTell) -> some View {
        HStack(spacing: 6) {
            Button("Ask") { ask(text) }
                .buttonStyle(mode == .ask ? AnyButtonStyle(PillButtonStyle()) : AnyButtonStyle(GlassCapsuleButtonStyle()))
            Button("Add to-do") { tell() }
                .buttonStyle(mode == .tell ? AnyButtonStyle(PillButtonStyle()) : AnyButtonStyle(GlassCapsuleButtonStyle()))
        }
        .transition(.opacity)
    }

    private func submit(_ mode: AskOrTell) {
        if mode == .ask { ask(text) } else { tell() }
    }

    private func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        showChat = true
        guard !q.isEmpty else { return }
        Task { await app.backend.sendChat(q) }
    }

    private func tell() {
        guard let task = app.addTask(text: text) else { return }
        text = ""
        added += 1
        OrbitSound.tick()
        let when = task.deadline.map { " · due \(Fmt.shortDue($0, app.calendar))" } ?? ""
        app.show("Added “\(task.title)”\(when)", undo: { [weak app] in app?.delete(task) })
    }
}

/// Type-erased button style (to switch styles on a condition without branching views).
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// The conversation, in a sheet over Home.
struct AskSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChatView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 520, idealHeight: 640)
    }
}

// MARK: - Activities

/// "Your activities today (5)": a horizontal strip of pastel cards.
struct ActivitiesSection: View {
    var ctx: HomeContext

    var body: some View {
        let items = ctx.timedToday.filter { $0.kind != .routine || $0.end > ctx.now }
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your activities today (\(items.count))")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("See calendar") { NotificationCenter.default.post(name: .orbitNavigate, object: Destination.calendar) }
                    .buttonStyle(SoftButtonStyle(color: Theme.textSecondary))
            }
            if items.isEmpty {
                PastelCard(fill: Theme.sage, padding: 18) {
                    HStack(spacing: Theme.Space.m) {
                        IconCircle(symbol: "leaf.fill", size: 38)
                        Text("Nothing else on today. Enjoy the space.")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 14) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            ActivityCard(item: item, index: i, ctx: ctx)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
            }
        }
    }
}

/// One pastel activity: a white circle icon, the time, the title and the module.
struct ActivityCard: View {
    var item: AgendaItem
    var index: Int
    var ctx: HomeContext

    var body: some View {
        let isNow = item.contains(ctx.now)
        let past = item.end <= ctx.now
        let fill = item.kind == .routine ? Theme.surface : Theme.pastel(index)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                IconCircle(symbol: item.symbol, size: 38)
                Spacer()
                if isNow { DoNowBadge() }
                else if item.completed { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.sageInk) }
            }
            Spacer(minLength: 0)
            Text(ctx.calendar.time(item.start) + "–" + ctx.calendar.time(item.end))
                .font(Theme.number(13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(ModuleNames.humanise(item.title))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let code = item.moduleCode { ModuleChip(code: code) }
            else if let loc = item.location, !loc.isEmpty {
                Label(loc, systemImage: "mappin").font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .padding(16)
        .frame(width: 206, height: 176, alignment: .topLeading)
        .softCard(fill: fill, radius: 24, shadow: item.kind == .routine)
        .overlay {
            if isNow {
                RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(DoNow.color.opacity(0.6), lineWidth: 1.5)
            }
        }
        .opacity(past ? 0.55 : 1)
    }
}

// MARK: - Stat tiles

struct StatTilesRow: View {
    var ctx: HomeContext
    @State private var showProgress = false

    var body: some View {
        let done = ctx.todos.filter(\.isDone).count
        let today = ctx.momentum.stats(ctx.momentum.keys.key(ctx.now))
        let score = Int((today.score(ctx.momentum.goals) * 100).rounded())
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)], spacing: 16) {
            StatTile(title: "Completed", value: "\(done)", symbol: "checkmark.circle.fill", fill: Theme.sage,
                     caption: "of \(ctx.todos.count) to-dos today") {
                NotificationCenter.default.post(name: .orbitNavigate, object: Destination.tasks)
            }
            StatTile(title: "Your score", value: "\(score)", symbol: "circle.circle.fill", fill: Theme.butter,
                     caption: "Level \(ctx.summary.level.level) · +\(ctx.summary.todayXP) XP") {
                showProgress = true
            }
            StatTile(title: "Active", value: "\(ctx.openTaskCount)", symbol: "bolt.fill", fill: Theme.blush,
                     caption: "open to-dos in total") {
                NotificationCenter.default.post(name: .orbitNavigate, object: Destination.tasks)
            }
        }
        .sheet(isPresented: $showProgress) { ProgressSheet(ctx: ctx) }
    }
}

// MARK: - Schedule

/// Today / tomorrow list beside a clean month calendar.
struct ScheduleCard: View {
    var ctx: HomeContext
    @State private var showTomorrow = false

    var body: some View {
        let items = (showTomorrow ? ctx.tomorrow : ctx.today).filter { !$0.isAllDay }
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Schedule").font(Theme.cardTitle).foregroundStyle(Theme.textPrimary)
                Spacer()
                GlassSegmented(options: [(false, "Today"), (true, "Tomorrow")], selection: $showTomorrow)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    ScheduleList(items: items, ctx: ctx, isToday: !showTomorrow).frame(minWidth: 240)
                    MiniMonthCalendar(today: ctx.now, calendar: ctx.calendar, busyDays: ctx.busyDays).frame(width: 236)
                }
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    ScheduleList(items: items, ctx: ctx, isToday: !showTomorrow)
                    MiniMonthCalendar(today: ctx.now, calendar: ctx.calendar, busyDays: ctx.busyDays)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .softCard()
    }
}

struct ScheduleList: View {
    var items: [AgendaItem]
    var ctx: HomeContext
    var isToday: Bool
    private let limit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if items.isEmpty {
                Text(isToday ? "Nothing else planned today." : "A clear day so far.")
                    .font(Theme.body).foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, Theme.Space.s)
            }
            ForEach(items.prefix(limit)) { item in
                ScheduleRow(item: item, ctx: ctx, isToday: isToday)
            }
            if items.count > limit {
                Button("+\(items.count - limit) more in Calendar") {
                    NotificationCenter.default.post(name: .orbitNavigate, object: Destination.calendar)
                }
                .buttonStyle(.plain)
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct ScheduleRow: View {
    var item: AgendaItem
    var ctx: HomeContext
    var isToday: Bool

    var body: some View {
        let isNow = isToday && item.contains(ctx.now)
        let past = isToday && item.end < ctx.now
        let origin = ctx.origin(of: item)
        HStack(spacing: Theme.Space.m) {
            IconCircle(symbol: item.symbol, size: 32, fill: rowFill(origin), ink: Theme.textPrimary)
            VStack(alignment: .leading, spacing: 1) {
                Text(ModuleNames.humanise(item.title))
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(past ? Theme.textTertiary : Theme.textPrimary)
                    .strikethrough(item.completed)
                    .lineLimit(1)
                Text(ctx.calendar.time(item.start) + " · " + Fmt.duration(item.minutes)
                     + (item.kind == .block ? " · " + (origin?.shortLabel ?? "Study") : ""))
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isNow { DoNowBadge() }
        }
        .padding(6)
        .background {
            if isNow {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DoNow.color.opacity(0.08))
            }
        }
        .opacity(item.kind == .routine ? 0.8 : 1)
    }

    private func rowFill(_ origin: TaskOrigin?) -> Color {
        if item.kind == .routine { return Theme.hover }
        if let origin { return origin.pastel }
        return Theme.moduleColor(item.moduleCode).opacity(0.16)
    }
}

/// A clean month: pastel circles on busy days, a black circle on today.
struct MiniMonthCalendar: View {
    var today: Date
    var calendar: DayCalendar
    var busyDays: Set<String>
    @State private var offset = 0

    var body: some View {
        let cal = calendar.calendar
        let keys = DayKeys(timeZone: calendar.timeZone)
        let month = cal.date(byAdding: .month, value: offset, to: cal.startOfDay(for: today)) ?? today
        let comps = cal.dateComponents([.year, .month], from: month)
        let first = cal.date(from: comps) ?? month
        let lead = (cal.component(.weekday, from: first) + 5) % 7
        let count = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        VStack(spacing: 8) {
            HStack {
                Text(calendar.format(first, "MMMM yyyy"))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                monthButton("chevron.left", -1)
                monthButton("chevron.right", 1)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, d in
                    Text(d).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                }
                ForEach(0..<(lead + count), id: \.self) { i in
                    if i < lead {
                        Color.clear.frame(height: 26)
                    } else {
                        let day = cal.date(byAdding: .day, value: i - lead, to: first) ?? first
                        DayDot(number: i - lead + 1, isToday: cal.isDate(day, inSameDayAs: today),
                               busy: busyDays.contains(keys.key(day)), tint: Theme.pastel(i))
                    }
                }
            }
        }
    }

    private func monthButton(_ symbol: String, _ delta: Int) -> some View {
        Button { withAnimation(Motion.snappy) { offset += delta } } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.hover))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta < 0 ? "Previous month" : "Next month")
    }
}

private struct DayDot: View {
    var number: Int
    var isToday: Bool
    var busy: Bool
    var tint: Color

    var body: some View {
        Text("\(number)")
            .font(.system(size: 11, weight: isToday ? .bold : .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(isToday ? Theme.onAccent : Theme.textPrimary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(isToday ? Theme.accent : (busy ? tint : Color.clear)))
    }
}

// MARK: - Jump to

/// Everything else, one click away.
struct JumpToRow: View {
    private let items: [Destination] = [.inbox, .review, .grades, .briefing, .progress, .money, .careers]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Jump to").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
            Flow(spacing: 8) {
                ForEach(items) { d in
                    Button {
                        NotificationCenter.default.post(name: .orbitNavigate, object: d)
                    } label: {
                        Label(d.title, systemImage: d.symbol)
                            .font(Theme.body.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(d.pastel))
                    }
                    .buttonStyle(PressScaleStyle(scale: 0.96))
                }
            }
        }
    }
}

// MARK: - Progress sheet

/// Level, rings, badges and the heatmap.
struct ProgressSheet: View {
    var ctx: HomeContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let m = ctx.momentum
        let today = m.stats(m.keys.key(ctx.now))
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Your progress").font(Theme.title(26)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button("Done") { dismiss() }.orbitGlassButton().keyboardShortcut(.defaultAction)
                }
                HStack(alignment: .center, spacing: 24) {
                    ActivityRings(study: today.studyProgress(m.goals), tasks: today.taskProgress(m.goals),
                                  reviews: today.reviewProgress(m.goals), size: 132)
                    VStack(alignment: .leading, spacing: 10) {
                        LevelPill(level: ctx.summary.level, todayXP: ctx.summary.todayXP)
                        Text("\(ctx.summary.level.xpToNext) XP to level \(ctx.summary.level.level + 1)")
                            .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        ringLine("Study", "\(today.studyMinutes)/\(m.goals.studyMinutes) min", Theme.ringStudy)
                        ringLine("To-dos", "\(today.tasksDone)/\(m.goals.tasks)", Theme.ringTasks)
                        ringLine("Reviews", "\(today.reviews)/\(m.goals.reviews)", Theme.ringReviews)
                    }
                }
                Text("Badges").font(Theme.sectionTitle).foregroundStyle(Theme.textPrimary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(Badge.allCases) { b in BadgeTile(badge: b, earned: ctx.summary.earned.contains(b)) }
                }
                HStack {
                    Text("Last 18 weeks").font(Theme.sectionTitle).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("Best streak \(ctx.summary.bestStreak) days").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
                ActivityHeatmap(cells: m.heatmap(weeks: 18, now: ctx.now), cell: 11, spacing: 3)
            }
            .padding(28)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 680)
        .background(Theme.background)
    }

    private func ringLine(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(Theme.body.weight(.medium)).foregroundStyle(Theme.textSecondary)
            Text(value).font(Theme.number(13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
        }
    }
}

struct BadgeTile: View {
    var badge: Badge
    var earned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            IconCircle(symbol: badge.symbol, size: 34, fill: earned ? Theme.surface : Theme.hover,
                       ink: earned ? Theme.textPrimary : Theme.textTertiary)
            Text(badge.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(earned ? Theme.textPrimary : Theme.textTertiary)
            Text(badge.detail).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .softCard(fill: earned ? Theme.butter : Theme.surface, radius: 20, shadow: false)
        .opacity(earned ? 1 : 0.7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(badge.title), \(earned ? "earned" : "locked")")
    }
}

// MARK: - Card chrome

/// A white dashboard card: an icon in a soft circle, a rounded title, an
/// optional accessory and a round arrow that opens `destination`.
struct HomeCard<Content: View, Accessory: View>: View {
    var title: String
    var symbol: String
    var color: Color
    var destination: Destination?
    var tint: Color? = nil
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                IconCircle(symbol: symbol, size: 34, fill: color.opacity(0.16), ink: color)
                Text(title)
                    .font(Theme.cardTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                accessory
                if destination != nil {
                    ArrowButton(size: 30, help: "Open \(title)", action: open)
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .softCard(fill: tint.map { _ in Theme.surface } ?? Theme.surface)
        .overlay {
            if let tint {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(tint.opacity(0.08)).allowsHitTesting(false)
            }
        }
    }

    private func open() {
        guard let destination else { return }
        NotificationCenter.default.post(name: .orbitNavigate, object: destination)
    }
}

extension HomeCard where Accessory == EmptyView {
    init(title: String, symbol: String, color: Color, destination: Destination?, tint: Color? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, color: color, destination: destination, tint: tint,
                  accessory: { EmptyView() }, content: content)
    }
}
