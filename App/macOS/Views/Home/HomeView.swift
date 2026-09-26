import SwiftUI
import SwiftData
import OrbitCore

/// Home: the one dashboard Orbit opens on. A greeting, a big quick-add bar, then a
/// bento grid of glass cards (today and tomorrow, to-dos, rings and streak, next
/// up, deadlines, uni, activity, inbox, careers, money, flashcards, Ask Orbit).
/// Every card opens its full screen.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(OrbitBrain.self) private var brain
    @Query(sort: \StoredEvent.start) private var events: [StoredEvent]
    @Query(sort: \StoredBlock.start) private var blocks: [StoredBlock]
    @Query private var tasks: [StoredTask]
    @Query private var assessments: [StoredAssessment]
    @Query(sort: \StoredBrief.createdAt, order: .reverse) private var briefs: [StoredBrief]
    @State private var width: CGFloat = 1000
    @State private var showLighten = false
    @State private var showEverything = false
    private var hub: FeatureHub { .shared }

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .background { AmbientBackdrop().ignoresSafeArea().orbitBackgroundExtension() }
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

    private func content(now: Date) -> some View {
        let ctx = HomeContext(now: now, calendar: app.calendar, events: events, blocks: blocks, tasks: tasks,
                              assessments: assessments)
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HomeHeader(now: now, brief: briefLine(now: now, ctx: ctx), momentum: ctx.momentum)
                    .staggeredAppear(0)
                if let nudge = hub.nudges.banner {
                    NudgeBanner(nudge: nudge)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                HomeQuickAddBar()
                    .staggeredAppear(1)
                OriginLegend()
                    .padding(.leading, Theme.Space.xs)
                    .staggeredAppear(2)
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: 0)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                if hub.exam.isActive(now: now) {
                    ExamDashboard(width: width, now: now)
                    DisclosureGroup(isExpanded: $showEverything) {
                        BentoGrid(width: width, tiles: tiles, ctx: ctx)
                            .padding(.top, Theme.Space.m)
                    } label: {
                        Text("Everything else").font(Theme.headline).foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    BentoGrid(width: width, tiles: tiles, ctx: ctx)
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.xxxl)
            .frame(maxWidth: 1480)
            .frame(maxWidth: .infinity)
            .animation(Motion.smooth, value: hub.nudges.banner?.id)
        }
        .scrollIndicators(.automatic)
    }

    /// The bento order. Spans shrink to fit when there are fewer columns.
    private var tiles: [HomeTile] {
        var t: [HomeTile] = [.days, .momentum, .todos, .nextUp, .deadlines, .uni, .flashcards, .inbox, .careers, .money, .activity, .ask]
        // To-dos found in lecture notes, only while there are some to look at.
        if !brain.notesLibrary.suggestions.isEmpty, let i = t.firstIndex(of: .flashcards) { t.insert(.noteSuggestions, at: i) }
        return t
    }

    private func briefLine(now: Date, ctx: HomeContext) -> String {
        let cal = app.calendar
        if let brief = briefs.first(where: { $0.id == StoredBrief.id(.morning, day: now, calendar: cal) }) {
            let text = (brief.narrative ?? brief.plainText).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.prefix(260)) }
        }
        let remaining = ctx.today.filter { !$0.isAllDay && $0.end > now && $0.kind == .event }.count
        let focus = ctx.today.filter { $0.kind == .block && $0.end > now }.reduce(0) { $0 + $1.minutes }
        var parts: [String] = []
        parts.append(remaining == 0 ? "Nothing else on the calendar" : "\(remaining) more thing\(remaining == 1 ? "" : "s") on today")
        if focus > 0 { parts.append("\(Fmt.duration(focus)) of focus planned") }
        let open = ctx.todos.filter { !$0.isDone }.count
        if open > 0 { parts.append("\(open) to-do\(open == 1 ? "" : "s") left") }
        return parts.joined(separator: " · ") + "."
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

// MARK: - Shared data for the cards

/// Everything the cards derive from the store, computed once per minute.
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

    @MainActor
    init(now: Date, calendar: DayCalendar, events: [StoredEvent], blocks: [StoredBlock], tasks: [StoredTask],
         assessments: [StoredAssessment]) {
        self.now = now
        self.calendar = calendar
        // The routine (hall meals, reading, shutdown) sits alongside, in its neutral colour.
        let prefs = FeatureHub.shared.prefs
        let tomorrowDay = calendar.addingDays(1, to: now)
        today = (Agenda.items(events: events, blocks: blocks, on: now, calendar: calendar)
            + Agenda.routineItems(prefs: prefs, events: events, on: now, calendar: calendar))
            .sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
        tomorrow = (Agenda.items(events: events, blocks: blocks, on: tomorrowDay, calendar: calendar)
            + Agenda.routineItems(prefs: prefs, events: events, on: tomorrowDay, calendar: calendar))
            .sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
        next = Agenda.nextUp(events: events, blocks: blocks, now: now, calendar: calendar)
        due = Agenda.dueSoon(tasks: tasks, assessments: assessments, now: now, days: 14)
        var byID: [String: StoredTask] = [:]
        for t in tasks { byID[t.id] = t }
        taskByID = byID
        var bByID: [String: StoredBlock] = [:]
        for b in blocks { bByID[b.id] = b }
        blockByID = bByID

        // Today's to-dos: due by tonight, planned today, or ticked off today.
        let endOfDay = calendar.endOfDay(now)
        let plannedToday = Set(blocks.filter { !$0.skipped && calendar.isSameDay($0.start, now) }.map(\.taskID))
        todos = tasks.filter { t in
            if let done = t.completedAt { return calendar.isSameDay(done, now) }
            if let d = t.deadline, d < endOfDay { return true }
            return plannedToday.contains(t.id)
        }
        .sorted { a, b in
            if a.isDone != b.isDone { return !a.isDone }
            return (a.deadline ?? .distantFuture, a.createdAt) < (b.deadline ?? .distantFuture, b.createdAt)
        }
        momentum = FeatureHub.shared.stats.momentum(tasks: tasks, blocks: blocks)
    }

    func origin(of item: AgendaItem) -> TaskOrigin? {
        guard let id = item.blockID, let block = blockByID[id], let task = taskByID[block.taskID] else { return nil }
        return task.origin
    }
}

// MARK: - Layout

enum HomeTile: String, Identifiable {
    case days, momentum, todos, nextUp, deadlines, uni, noteSuggestions, flashcards, inbox, careers, money, activity, ask
    var id: String { rawValue }

    /// Columns wanted on a wide window.
    var span: Int {
        switch self {
        case .days, .uni, .activity: 2
        default: 1
        }
    }
}

/// Packs tiles into rows of equal-height glass cards.
struct BentoGrid: View {
    var width: CGFloat
    var tiles: [HomeTile]
    var ctx: HomeContext
    private let gap: CGFloat = Theme.Space.l

    private var columns: Int { width > 1180 ? 3 : (width > 720 ? 2 : 1) }

    var body: some View {
        let rows = pack()
        let unit = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        OrbitGlassContainer(spacing: 0) {
            VStack(alignment: .leading, spacing: gap) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(rows[r]) { tile in
                            let span = min(tile.span, columns)
                            HomeTileView(tile: tile, ctx: ctx)
                                .frame(width: max(0, unit * CGFloat(span) + gap * CGFloat(span - 1)))
                                .frame(maxHeight: .infinity, alignment: .top)
                                .staggeredAppear(3 + (tiles.firstIndex(of: tile) ?? 0))
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Greedy rows; a row that can't fit the next tile is closed. The last
    /// tile of a short row stretches to fill it.
    private func pack() -> [[HomeTile]] {
        var rows: [[HomeTile]] = []
        var row: [HomeTile] = []
        var used = 0
        for tile in tiles {
            let span = min(tile.span, columns)
            if used + span > columns {
                rows.append(row)
                row = []
                used = 0
            }
            row.append(tile)
            used += span
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }
}

struct HomeTileView: View {
    var tile: HomeTile
    var ctx: HomeContext

    var body: some View {
        switch tile {
        case .days: DaysCard(ctx: ctx)
        case .momentum: MomentumCard(ctx: ctx)
        case .todos: TodosCard(ctx: ctx)
        case .nextUp: NextUpCard(ctx: ctx)
        case .deadlines: DeadlinesCard(ctx: ctx)
        case .uni: UniWeekCard(ctx: ctx)
        case .flashcards: FlashcardsCard(ctx: ctx)
        case .inbox: InboxCard(ctx: ctx)
        case .careers: CareersCard(ctx: ctx)
        case .money: MoneyCard(ctx: ctx)
        case .activity: ActivityCard(ctx: ctx)
        case .ask: AskCard()
        case .noteSuggestions: NoteSuggestionsCard()
        }
    }
}

// MARK: - Header

struct HomeHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(OrbitBrain.self) private var brain
    var now: Date
    var brief: String
    var momentum: Momentum

    var body: some View {
        let cal = app.calendar
        let streak = momentum.streak(now: now)
        HStack(alignment: .top, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Text(cal.format(now, "EEEE d MMMM"))
                        .font(Theme.body.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    if let w = brain.academic.currentWeek {
                        Tag(text: "Week \(w.week) · Term \(w.term)\(w.isReadingWeek ? " · Reading week" : "")",
                            color: Theme.accent, systemImage: "graduationcap.fill")
                    }
                }
                greeting(cal: cal)
                Text(brief)
                    .font(Theme.large)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 720, alignment: .leading)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: Theme.Space.s) {
                StreakBadge(streak: streak, todayCounts: momentum.todayCounts(now: now))
                HealthPill()
            }
        }
        .padding(.top, Theme.Space.l)
    }

    private func greeting(cal: DayCalendar) -> some View {
        let hour = cal.minuteOfDay(now) / 60
        let part = hour < 5 ? "Still up" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let name = app.firstName
        return (Text(part + (name.isEmpty ? "" : ", "))
                    .foregroundStyle(Theme.textPrimary)
                + Text(name).foregroundStyle(Theme.accentGradient))
            .font(.system(size: 38, weight: .bold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// The flame and the streak count.
struct StreakBadge: View {
    var streak: Int
    var todayCounts: Bool
    @State private var flicker = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "flame.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(streak > 0 ? AnyShapeStyle(Theme.flame) : AnyShapeStyle(Theme.textTertiary))
                .scaleEffect(flicker ? 1.08 : 0.96)
                .shadow(color: streak > 0 ? Color.orange.opacity(0.5) : .clear, radius: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(streak)")
                    .font(Theme.number(26))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text(streak == 1 ? "day streak" : "day streak")
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .orbitGlass(in: Capsule(), tint: streak > 0 ? .orange : nil)
        .help(todayCounts ? "Today counts. Keep it going tomorrow." : "Do anything today (a to-do, 10 minutes of focus or 5 cards) to keep your streak.")
        .onAppear {
            guard streak > 0 else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { flicker = true }
        }
    }
}

// MARK: - Quick add

/// The big natural-language quick add at the top of Home (⌘N focuses it).
struct HomeQuickAddBar: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var added = 0
    @State private var showCheck = false
    @FocusState private var focused: Bool

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let result = trimmed.isEmpty ? nil : app.parse(text)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                ZStack {
                    Circle().fill(showCheck ? AnyShapeStyle(Theme.success.gradient) : AnyShapeStyle(Theme.accentGradient))
                        .frame(width: 32, height: 32)
                        .shadow(color: (showCheck ? Theme.success : Theme.violet).opacity(0.45), radius: 8, y: 2)
                    Image(systemName: showCheck ? "checkmark" : "plus")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                    CheckBurst(trigger: added)
                }
                .scaleEffect(showCheck ? 1.12 : 1)
                TextField("Add anything — “essay plan BEM2031 2h by Fri”, “call mum tomorrow 6pm”", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .medium))
                    .focused($focused)
                    .onSubmit(add)
                    .onExitCommand { text = ""; focused = false }
                if result != nil {
                    Button("Add", action: add)
                        .orbitGlassProminentButton()
                        .keyboardShortcut(.return, modifiers: [])
                        .transition(.scale.combined(with: .opacity))
                } else {
                    KeyHint(keys: "⌘N")
                }
            }
            if let result {
                ParsedChips(result: result)
                    .padding(.leading, 32 + Theme.Space.m)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .orbitGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous),
                    tint: focused ? Theme.accent : nil, interactive: true)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.accentGradient, lineWidth: focused ? 1.5 : 0)
                .opacity(focused ? 0.8 : 0)
        }
        .animation(Motion.snappy, value: result == nil)
        .animation(Motion.fade, value: focused)
        .onReceive(NotificationCenter.default.publisher(for: .orbitFocusHomeQuickAdd)) { _ in focused = true }
    }

    private func add() {
        guard let task = app.addTask(text: text) else { return }
        text = ""
        added += 1
        withAnimation(Motion.bouncy) { showCheck = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(Motion.smooth) { showCheck = false }
        }
        let when = task.deadline.map { " · due \(Fmt.shortDue($0, app.calendar))" } ?? ""
        app.show("Added “\(task.title)”\(when)", undo: { [weak app] in app?.delete(task) })
    }
}

// MARK: - Card chrome

/// A dashboard card: icon tile, title, optional accessory, chevron; opens `destination`.
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
                IconTile(symbol: symbol, color: color, size: 24)
                Text(title)
                    .font(Theme.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Theme.Space.s)
                accessory
                if destination != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            content
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .orbitGlassCard(tint: tint)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onTapGesture(count: 2, perform: open)
        .hoverLift()
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
