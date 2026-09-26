import SwiftUI
import SwiftData
import OrbitCore

// The Home dashboard's cards. Each reads HomeContext (computed once a minute)
// or the observable services, and opens its full screen from the header.

// MARK: - Today and tomorrow

struct DaysCard: View {
    var ctx: HomeContext

    var body: some View {
        HomeCard(title: "Today and tomorrow", symbol: "calendar", color: Destination.calendar.color, destination: .calendar) {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                MiniTimeline(title: "Today", items: ctx.today, ctx: ctx, isToday: true)
                Rectangle().fill(Theme.separator).frame(width: Theme.hairline)
                MiniTimeline(title: ctx.calendar.format(ctx.calendar.addingDays(1, to: ctx.now), "EEEE"),
                             items: ctx.tomorrow, ctx: ctx, isToday: false)
            }
        }
    }
}

/// A compact agenda for one day with a live "now" line.
struct MiniTimeline: View {
    @Environment(AppModel.self) private var app
    var title: String
    var items: [AgendaItem]
    var ctx: HomeContext
    var isToday: Bool
    private let limit = 7

    var body: some View {
        let allDay = items.filter(\.isAllDay)
        let timed = items.filter { !$0.isAllDay }
        let visible = Array(timed.prefix(limit))
        let nowIndex = isToday ? (visible.firstIndex { $0.end > ctx.now } ?? visible.count) : nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.body.weight(.bold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                let focus = timed.filter { $0.kind == .block }.reduce(0) { $0 + $1.minutes }
                Text("\(timed.filter { $0.kind == .event }.count) events" + (focus > 0 ? " · \(Fmt.duration(focus)) study" : ""))
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            if !allDay.isEmpty {
                Flow(spacing: 4) {
                    ForEach(allDay) { item in
                        Tag(text: item.title, color: Theme.moduleColor(item.moduleCode))
                    }
                }
            }
            if timed.isEmpty {
                Text(isToday ? "Nothing else planned. Enjoy it." : "A clear day so far.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, Theme.Space.s)
            }
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                if index == nowIndex { NowLine(now: ctx.now, calendar: ctx.calendar) }
                TimelineRow(item: item, ctx: ctx, isToday: isToday)
            }
            if nowIndex == visible.count, isToday, !visible.isEmpty { NowLine(now: ctx.now, calendar: ctx.calendar) }
            if timed.count > limit {
                Text("+\(timed.count - limit) more")
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct NowLine: View {
    var now: Date
    var calendar: DayCalendar

    var body: some View {
        HStack(spacing: 6) {
            Text(calendar.time(now))
                .font(Theme.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Theme.now, in: Capsule())
            Capsule().fill(Theme.now).frame(height: 2)
                .shadow(color: Theme.now.opacity(0.6), radius: 3)
        }
        .padding(.vertical, 2)
    }
}

struct TimelineRow: View {
    var item: AgendaItem
    var ctx: HomeContext
    var isToday: Bool

    var body: some View {
        let origin = ctx.origin(of: item)
        let isNow = isToday && item.contains(ctx.now) && item.kind == .block
        let past = isToday && item.end < ctx.now
        let color = item.kind == .routine ? Theme.routine : (origin?.color ?? Theme.moduleColor(item.moduleCode))
        let routineID = item.kind == .routine ? String(item.id.dropFirst(2)) : nil
        HStack(spacing: Theme.Space.s) {
            Text(ctx.calendar.time(item.start))
                .font(Theme.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 38, alignment: .leading)
            RoundedRectangle(cornerRadius: 2)
                .fill(color.gradient)
                .frame(width: 4, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Theme.body.weight(.medium))
                    .foregroundStyle(past ? Theme.textTertiary : Theme.textPrimary)
                    .strikethrough(item.completed)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(Fmt.duration(item.minutes))
                    if let loc = item.location, !loc.isEmpty { Text("· \(loc)").lineLimit(1) }
                    if item.kind == .block, let origin { Text("· \(origin.shortLabel)").foregroundStyle(origin.color) }
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
            if isNow { DoNowBadge() }
            if let routineID, !routineID.hasPrefix("shutdown") {
                // "Ate it" / "Read it": quiets the "Dinner closes" nudge.
                let routine = FeatureHub.shared.routine
                CircleCheckbox(isOn: routine.state.routineDone.contains(routineID), color: Theme.routine, size: 15) {
                    if let block = routine.blocks(on: item.start).first(where: { $0.id == routineID }) { routine.toggleDone(block) }
                }
            }
        }
        .opacity(item.kind == .routine ? 0.85 : 1)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background {
            if isNow {
                RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                    .fill(DoNow.color.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                        .strokeBorder(DoNow.color.opacity(0.45), lineWidth: 1))
                    .shadow(color: DoNow.color.opacity(0.25), radius: 8)
            }
        }
    }
}

// MARK: - To-dos

struct TodosCard: View {
    @Environment(AppModel.self) private var app
    var ctx: HomeContext
    @State private var draft = ""
    @FocusState private var adding: Bool
    private let limit = 8

    var body: some View {
        let todos = ctx.todos
        let done = todos.filter(\.isDone).count
        HomeCard(title: "Today's to-dos", symbol: "checklist", color: Destination.tasks.color, destination: .tasks) {
            HStack(spacing: 6) {
                ProgressRing(progress: todos.isEmpty ? 0 : Double(done) / Double(todos.count),
                             color: Theme.success, lineWidth: 3.5)
                    .frame(width: 20, height: 20)
                Text("\(done)/\(todos.count) done")
                    .font(Theme.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
            }
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                if todos.isEmpty {
                    Text("Nothing due today. Add something below.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.vertical, Theme.Space.xs)
                }
                ForEach(todos.prefix(limit)) { task in
                    TodoRow(task: task, now: ctx.now)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if todos.count > limit {
                    Button("\(todos.count - limit) more in Tasks") {
                        NotificationCenter.default.post(name: .orbitNavigate, object: Destination.tasks)
                    }
                    .buttonStyle(.orbitLink)
                    .font(Theme.caption)
                    .padding(.leading, 30)
                }
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(adding ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
                        .frame(width: 22)
                    TextField("Add a to-do for today", text: $draft)
                        .textFieldStyle(.plain)
                        .font(Theme.body)
                        .focused($adding)
                        .onSubmit(add)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(Theme.hover.opacity(adding ? 1 : 0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                .padding(.top, 4)
            }
            .animation(Motion.smooth, value: todos.map(\.id))
        }
    }

    /// Anything added here without a date is due tonight, so it stays on today's list.
    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var task = app.parse(text).task
        if task.deadline == nil {
            task.deadline = ctx.calendar.date(minute: max(app.prefs.dayEnd - 1, 0), of: ctx.now)
        }
        let stored = app.addTask(task)
        draft = ""
        adding = true
        app.show("Added “\(stored.title)”", undo: { [weak app] in app?.delete(stored) })
    }
}

struct TodoRow: View {
    @Environment(AppModel.self) private var app
    var task: StoredTask
    var now: Date

    var body: some View {
        let done = task.isDone
        HStack(spacing: Theme.Space.s) {
            CircleCheckbox(isOn: done, size: 20) {
                withAnimation(Motion.bouncy) { app.toggleComplete(task) }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(Theme.body.weight(.medium))
                    .foregroundStyle(done ? Theme.textTertiary : Theme.textPrimary)
                    .strikethrough(done, color: Theme.textTertiary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    OriginDot(origin: task.origin, size: 6)
                    Text(task.origin.shortLabel).foregroundStyle(task.origin.color)
                    if let code = task.moduleCode { Text("· \(code)") }
                    if let d = task.deadline, !done { Text("· \(Fmt.shortDue(d, app.calendar, now: now)) \(app.calendar.time(d))") }
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
            if !done, let d = task.deadline, d < now {
                Tag(text: "Overdue", color: Theme.danger)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .hoverRow()
        .opacity(done ? 0.7 : 1)
        .contextMenu {
            Button("Open in Tasks") {
                app.selectedTaskID = task.id
                NotificationCenter.default.post(name: .orbitNavigate, object: Destination.tasks)
            }
            Button("Focus on this") { FeatureHub.shared.focus.start(task: task) }
            Divider()
            Button("Delete", role: .destructive) { app.deleteWithUndo(task) }
        }
    }
}

// MARK: - Rings, streak, heatmap

struct MomentumCard: View {
    var ctx: HomeContext
    private var stats: StatsService { FeatureHub.shared.stats }

    var body: some View {
        let m = ctx.momentum
        let today = m.stats(m.keys.key(ctx.now))
        let goals = m.goals
        HomeCard(title: "Your day", symbol: "flame.fill", color: .orange, destination: .progress) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.l) {
                    ActivityRings(study: today.studyProgress(goals), tasks: today.taskProgress(goals),
                                  reviews: today.reviewProgress(goals), size: 118)
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        ringLegend("Study", "\(today.studyMinutes)", "/\(goals.studyMinutes) min", Theme.ringStudy)
                        ringLegend("To-dos", "\(today.tasksDone)", "/\(goals.tasks)", Theme.ringTasks)
                        ringLegend("Reviews", "\(today.reviews)", "/\(goals.reviews)", Theme.ringReviews)
                    }
                }
                if today.allGoalsMet(goals) {
                    Label("All three rings closed. Brilliant.", systemImage: "checkmark.seal.fill")
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(Theme.success)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Last 18 weeks").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("Best streak \(m.bestStreak())d")
                            .font(Theme.caption.monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                    ActivityHeatmap(cells: m.heatmap(weeks: 18, now: ctx.now), cell: 10, spacing: 3)
                }
            }
        }
    }

    private func ringLegend(_ title: String, _ value: String, _ goal: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(Theme.number(20)).foregroundStyle(Theme.textPrimary).contentTransition(.numericText())
                Text(goal).font(Theme.number(12, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

// MARK: - Next up and focus

struct NextUpCard: View {
    @Environment(AppModel.self) private var app
    var ctx: HomeContext
    private var hub: FeatureHub { .shared }

    var body: some View {
        HomeCard(title: hub.focus.session == nil ? "Next up" : "Focusing", symbol: "timer",
                 color: Destination.focus.color, destination: .focus,
                 tint: hub.focus.session == nil ? nil : Destination.focus.color) {
            if let session = hub.focus.session {
                running(session)
            } else if let next = ctx.next {
                upcoming(next)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Nothing planned right now.")
                        .font(Theme.large.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                    Button {
                        hub.focus.start(task: nil, title: "Focus", minutes: 25)
                    } label: {
                        Label("Start a 25-minute focus", systemImage: "play.fill")
                    }
                    .orbitGlassProminentButton(Destination.focus.color)
                }
            }
        }
    }

    private func upcoming(_ item: AgendaItem) -> some View {
        let isNow = item.contains(ctx.now)
        let block = item.blockID.flatMap { ctx.blockByID[$0] }
        let origin = ctx.origin(of: item)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 6) {
                if isNow && item.kind == .block { DoNowBadge() } else {
                    Tag(text: isNow ? "Now" : Fmt.relative(item.start, now: ctx.now), color: Theme.accent)
                }
                if let origin { OriginChip(origin: origin) }
                ModuleChip(code: item.moduleCode)
            }
            Text(item.title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            Text("\(Fmt.day(item.start, ctx.calendar, now: ctx.now)) · \(Fmt.range(item.start, item.end, ctx.calendar))"
                 + (item.location.map { " · \($0)" } ?? ""))
                .font(Theme.body.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: Theme.Space.s) {
                if let block {
                    Button {
                        hub.focus.start(task: ctx.taskByID[block.taskID], block: block)
                    } label: {
                        Label("Start focus", systemImage: "play.fill")
                            .font(Theme.body.weight(.bold))
                            .padding(.horizontal, 4)
                    }
                    .orbitGlassProminentButton(Destination.focus.color)
                    .controlSize(.large)
                    Button("Done") { withAnimation(Motion.bouncy) { app.done(block) } }
                        .orbitGlassButton()
                    Button("Skip") { withAnimation(Motion.smooth) { app.skip(block) } }
                        .buttonStyle(SoftButtonStyle(color: Theme.textSecondary))
                } else {
                    Button {
                        _ = hub.startFocus(query: "", minutes: nil)
                    } label: {
                        Label("Focus on what's next", systemImage: "play.fill")
                    }
                    .orbitGlassButton()
                }
            }
        }
    }

    private func running(_ session: FocusSession) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { t in
            let planned = Double((session.plannedMinutes ?? 0) * 60)
            let progress = planned > 0 ? session.elapsed(at: t.date) / planned : 0
            HStack(spacing: Theme.Space.l) {
                ZStack {
                    RingArc(progress: progress, start: Destination.focus.color, end: Theme.pink, lineWidth: 9)
                    Text(session.clock(at: t.date))
                        .font(Theme.number(18))
                        .foregroundStyle(Theme.textPrimary)
                }
                .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(session.title)
                        .font(Theme.large.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text(session.isPaused ? "Paused" : (hub.focus.dndActive ? "Do Not Disturb on" : "In the zone"))
                        .font(Theme.caption.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 6) {
                        Button(session.isPaused ? "Resume" : "Pause") {
                            session.isPaused ? hub.focus.resume() : hub.focus.pause()
                        }
                        .orbitGlassButton()
                        Button("Finish") { hub.focus.finish(markTaskDone: false) }
                            .orbitGlassProminentButton(Destination.focus.color)
                    }
                }
            }
        }
    }
}

// MARK: - Deadlines

struct DeadlinesCard: View {
    @Environment(AppModel.self) private var app
    var ctx: HomeContext

    var body: some View {
        let due = Array(ctx.due.prefix(6))
        HomeCard(title: "Deadlines", symbol: "hourglass", color: Theme.danger, destination: .tasks) {
            VStack(alignment: .leading, spacing: 6) {
                if due.isEmpty {
                    Text("Nothing due in the next two weeks.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.textTertiary)
                }
                ForEach(due) { entry in
                    let urgency = Self.urgency(entry.due, now: ctx.now)
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: entry.kind == .assessment ? "doc.text.fill" : "circle.fill")
                            .font(.system(size: entry.kind == .assessment ? 12 : 6))
                            .foregroundStyle(Theme.moduleColor(entry.moduleCode))
                            .frame(width: 16)
                        Text(entry.title)
                            .font(Theme.body.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if let w = entry.weightPercent, w > 0 {
                            Text("\(Int(w))%").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: Theme.Space.s)
                        Text(Self.countdown(entry.due, now: ctx.now))
                            .font(Theme.number(12, weight: .bold))
                            .foregroundStyle(urgency)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(urgency.opacity(0.15), in: Capsule())
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { open(entry) }
                }
            }
        }
    }

    static func countdown(_ due: Date, now: Date) -> String {
        let seconds = due.timeIntervalSince(now)
        let overdue = seconds < 0
        let s = abs(Int(seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        let text = d > 0 ? "\(d)d \(h)h" : (h > 0 ? "\(h)h \(m)m" : "\(m)m")
        return overdue ? "−\(text)" : text
    }

    static func urgency(_ due: Date, now: Date) -> Color {
        let hours = due.timeIntervalSince(now) / 3600
        if hours < 24 { return Theme.danger }
        if hours < 72 { return Theme.warning }
        return Theme.success
    }

    private func open(_ entry: DueEntry) {
        switch entry.kind {
        case .task:
            app.selectedTaskID = String(entry.id.dropFirst(2))
            NotificationCenter.default.post(name: .orbitNavigate, object: Destination.tasks)
        case .assessment:
            app.selectedModuleID = entry.moduleCode
            NotificationCenter.default.post(name: .orbitNavigate, object: Destination.uni)
        }
    }
}

// MARK: - Uni this week

struct UniWeekCard: View {
    @Environment(OrbitBrain.self) private var brain
    @Query private var readings: [StoredReading]
    @Query private var modules: [StoredModule]
    @Query(filter: #Predicate<StoredTask> { $0.completedAt != nil }) private var doneTasks: [StoredTask]
    var ctx: HomeContext

    var body: some View {
        let week = brain.academic.currentWeek
        let rows = progressRows(week: week?.week)
        let missed = brain.academic.lectureReviews
            .filter { !$0.missed.isEmpty && $0.updatedAt > ctx.now.addingTimeInterval(-14 * 86400) }
            .prefix(3)
        HomeCard(title: "Uni this week", symbol: "graduationcap.fill", color: Destination.uni.color, destination: .uni) {
            Text(brain.academic.weekLabel)
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
        } content: {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if rows.isEmpty {
                        Text("Connect ELE to see readings and homework per module.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(rows, id: \.code) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                ModuleChip(code: row.code)
                                Text(row.name).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                Spacer()
                                Text("\(row.done)/\(row.total)")
                                    .font(Theme.number(12, weight: .bold))
                                    .foregroundStyle(row.done == row.total && row.total > 0 ? Theme.success : Theme.textSecondary)
                            }
                            ThinProgressBar(value: row.total == 0 ? 0 : Double(row.done) / Double(row.total),
                                            color: Theme.moduleColor(row.code), height: 6)
                            Text(row.detail).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !missed.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("You may have missed…")
                            .font(Theme.caption.weight(.bold))
                            .foregroundStyle(Theme.warning)
                        ForEach(Array(missed)) { review in
                            Button {
                                NotificationCenter.default.post(name: .orbitNavigate, object: Destination.notes)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(review.missed.prefix(2).map(\.topic).joined(separator: ", "))
                                        .font(Theme.body.weight(.medium))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text("\(review.moduleCode)\(review.week.map { " · week \($0)" } ?? "")"
                                         + (review.coverage.map { " · \(Int($0 * 100))% covered" } ?? ""))
                                        .font(Theme.caption)
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .padding(Theme.Space.s)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                }
            }
        }
    }

    private struct Row {
        var code: String
        var name: String
        var done: Int
        var total: Int
        var detail: String
    }

    private func progressRows(week: Int?) -> [Row] {
        let doneIDs = Set(doneTasks.map(\.id))
        var codes = brain.academic.modules.map { ($0.code, $0.name) }
        if codes.isEmpty { codes = modules.sorted { $0.id < $1.id }.map { ($0.id, $0.name) } }
        return codes.prefix(6).compactMap { entry -> Row? in
            let (code, name) = entry
            let hw = brain.academic.homework.filter { $0.moduleCode == code && (week == nil || $0.week == week) }
            let hwDone = hw.filter { doneIDs.contains($0.taskID.uuidString) }.count
            let rd = readings.filter { $0.moduleCode == code && (week == nil || $0.week == week) }
            let rdDone = rd.filter(\.done).count
            let total = hw.count + rd.count
            guard total > 0 || week == nil else {
                return Row(code: code, name: name, done: 0, total: 0, detail: "Nothing set this week yet")
            }
            var parts: [String] = []
            if !rd.isEmpty { parts.append("\(rdDone)/\(rd.count) readings") }
            if !hw.isEmpty { parts.append("\(hwDone)/\(hw.count) homework") }
            return Row(code: code, name: name, done: hwDone + rdDone, total: total,
                       detail: parts.isEmpty ? "Nothing set this week yet" : parts.joined(separator: " · "))
        }
    }
}

// MARK: - Flashcards

struct FlashcardsCard: View {
    var ctx: HomeContext
    @State private var reviewing = false
    private var hub: FeatureHub { .shared }

    var body: some View {
        let plan = hub.dailyReviewPlan(now: ctx.now)
        let today = ctx.momentum.stats(ctx.momentum.keys.key(ctx.now))
        let goal = ctx.momentum.goals.reviews
        HomeCard(title: "Flashcards", symbol: "rectangle.on.rectangle.angled.fill", color: Destination.review.color,
                 destination: .review) {
            HStack(spacing: Theme.Space.l) {
                ZStack {
                    RingArc(progress: Double(today.reviews) / Double(max(1, goal)), start: Theme.ringReviews,
                            end: Theme.ringReviewsEnd, lineWidth: 8)
                    VStack(spacing: -2) {
                        Text("\(plan.dueCount)").font(Theme.number(24)).foregroundStyle(Theme.textPrimary)
                        Text("due").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(width: 78, height: 78)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(plan.briefLine ?? "All caught up. New cards arrive as your notes sync.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(today.reviews) reviewed today")
                        .font(Theme.caption.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                    Button {
                        reviewing = true
                    } label: {
                        Label("Review now", systemImage: "play.fill")
                    }
                    .orbitGlassProminentButton(Destination.review.color)
                    .disabled(plan.dueCount == 0)
                }
            }
        }
        .sheet(isPresented: $reviewing) {
            DeckReviewView(module: nil).frame(minWidth: 620, minHeight: 480)
        }
    }
}

// MARK: - Inbox

struct InboxCard: View {
    @Query(filter: #Predicate<StoredEmailDigest> { !$0.handled }, sort: \StoredEmailDigest.date, order: .reverse)
    private var digests: [StoredEmailDigest]
    var ctx: HomeContext

    var body: some View {
        let week = ctx.now.addingTimeInterval(-7 * 86400)
        let important = digests.filter { d in
            d.date > week && (d.category == .urgent || d.category == .needsReply || d.importance >= 0.7)
        }
        .sorted { ($0.importance, $0.date) > ($1.importance, $1.date) }
        HomeCard(title: "Inbox", symbol: "tray.full.fill", color: Destination.inbox.color, destination: .inbox) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(important.count)").font(Theme.number(30)).foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                    Text(important.count == 1 ? "important email" : "important emails")
                        .font(Theme.body.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(important.prefix(3)) { d in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Circle().fill(d.category == .urgent ? Theme.danger : Theme.warning).frame(width: 6, height: 6)
                            Text(senderName(d.from)).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(Fmt.shortDue(d.date, ctx.calendar, now: ctx.now))
                                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Text(d.summary.isEmpty ? d.subject : d.summary)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
                if important.isEmpty {
                    Text("Nothing needs you. Inbox zero energy.")
                        .font(Theme.body).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private func senderName(_ from: String) -> String {
        if let lt = from.firstIndex(of: "<") {
            let name = from[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !name.isEmpty { return name }
        }
        return from
    }
}

// MARK: - Careers

struct CareersCard: View {
    var ctx: HomeContext
    private var careers: CareersService { FeatureHub.shared.careers }

    var body: some View {
        let filter = CareersFilter(category: .springWeeks, status: .open, eligibleOnly: true)
        let open = filter.apply(careers.opportunities, preferences: careers.preferences, now: ctx.now)
        let soonest = open.first
        HomeCard(title: "Careers", symbol: "briefcase.fill", color: Destination.careers.color, destination: .careers) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(open.count)").font(Theme.number(30)).foregroundStyle(Theme.textPrimary)
                    Text(open.count == 1 ? "spring week open now" : "spring weeks open now")
                        .font(Theme.body.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                if !open.isEmpty {
                    HStack(spacing: -6) {
                        ForEach(Array(uniqueCompanies(open).prefix(7)), id: \.self) { c in
                            FirmLogo(company: c, size: 30)
                        }
                    }
                }
                if let o = soonest, let d = o.daysToClose(now: ctx.now) {
                    HStack(spacing: 4) {
                        Text("Closing soonest:").foregroundStyle(Theme.textTertiary)
                        Text(o.company).fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                        Text(d == 0 ? "today" : "in \(d)d").foregroundStyle(d <= 3 ? Theme.danger : Theme.warning)
                    }
                    .font(Theme.caption)
                    .lineLimit(1)
                } else if careers.opportunities.isEmpty {
                    Text(careers.syncing ? "Reading Trackr…" : "Orbit checks Trackr every two hours.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private func uniqueCompanies(_ list: [Opportunity]) -> [String] {
        var seen = Set<String>()
        return list.map(\.company).filter { seen.insert($0.lowercased()).inserted }
    }
}

// MARK: - Money

struct MoneyCard: View {
    var ctx: HomeContext
    private var money: MoneyService { FeatureHub.shared.money }

    var body: some View {
        HomeCard(title: "Money", symbol: "sterlingsign", color: Destination.money.color, destination: .money) {
            if money.hasAnyData {
                let safe = money.safeToSpend(now: ctx.now)
                let worth = money.netWorth()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Safe to spend")
                        .font(Theme.caption.weight(.bold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(MoneyFormat.pounds(safe.availablePence))
                        .font(Theme.number(30))
                        .foregroundStyle(safe.availablePence > 0 ? Theme.success : Theme.danger)
                    Text("\(MoneyFormat.pounds(safe.perDayPence)) a day for \(safe.days) days · balance \(MoneyFormat.pounds(worth.cashPence))")
                        .font(Theme.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("See what's safe to spend until your next loan payment.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Connect Monzo or import a CSV") {
                        NotificationCenter.default.post(name: .orbitNavigate, object: Destination.money)
                    }
                    .orbitGlassButton()
                }
            }
        }
    }
}

// MARK: - ELE and Ed activity

struct ActivityCard: View {
    @Environment(OrbitBrain.self) private var brain
    var ctx: HomeContext
    private var ed: EdService { FeatureHub.shared.ed }

    private struct Entry: Identifiable {
        var id: String
        var symbol: String
        var color: Color
        var module: String?
        var title: String
        var detail: String
        var date: Date
        var url: String?
    }

    var body: some View {
        let entries = merged()
        HomeCard(title: "ELE and Ed", symbol: "bell.badge.fill", color: Color(hex: 0xFF6B3D), destination: .uni) {
            VStack(alignment: .leading, spacing: 6) {
                if entries.isEmpty {
                    Text("New files, announcements, grades and Ed posts show up here.")
                        .font(Theme.body).foregroundStyle(Theme.textTertiary)
                }
                ForEach(entries) { e in
                    HStack(spacing: Theme.Space.s) {
                        IconTile(symbol: e.symbol, color: e.color, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                if let m = e.module { ModuleChip(code: m) }
                                Text(e.title).font(Theme.body.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            }
                            if !e.detail.isEmpty {
                                Text(e.detail).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Text(Fmt.shortDue(e.date, ctx.calendar, now: ctx.now))
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let s = e.url, let url = URL(string: s) { openExternal(url) }
                    }
                }
            }
        }
    }

    private func merged() -> [Entry] {
        let ele = brain.academic.activity.prefix(6).map { a in
            Entry(id: "ele-" + a.id, symbol: symbol(a.kind), color: color(a.kind), module: a.moduleCode, title: a.title,
                  detail: a.detail, date: a.date, url: a.url)
        }
        let edItems = ed.state.items.sorted { $0.date > $1.date }.prefix(6).map { i in
            Entry(id: "ed-" + i.id, symbol: "bubble.left.and.bubble.right.fill", color: Color(hex: 0x7C5CFF),
                  module: i.moduleCode ?? i.courseCode, title: i.title, detail: i.snippet, date: i.date, url: i.url)
        }
        return Array((ele + edItems).sorted { $0.date > $1.date }.prefix(5))
    }

    private func symbol(_ kind: ELEActivityItem.Kind) -> String {
        switch kind {
        case .newFile, .newContent: "doc.fill"
        case .weekUpdated: "books.vertical.fill"
        case .newAssessment: "doc.badge.plus"
        case .deadlineChanged: "calendar.badge.exclamationmark"
        case .announcement: "megaphone.fill"
        case .forumPost: "bubble.left.fill"
        case .grade: "rosette"
        case .feedback: "text.bubble.fill"
        case .notification: "bell.fill"
        case .message: "envelope.fill"
        case .submission: "tray.and.arrow.up.fill"
        case .homework: "pencil.and.list.clipboard"
        case .other: "circle.fill"
        }
    }

    private func color(_ kind: ELEActivityItem.Kind) -> Color {
        switch kind {
        case .grade, .feedback: Theme.success
        case .deadlineChanged, .newAssessment, .homework: Theme.warning
        case .announcement, .notification: Theme.danger
        default: Theme.indigo
        }
    }
}

// MARK: - Ask Orbit

struct AskCard: View {
    @Environment(AppModel.self) private var app
    @State private var draft = ""
    @FocusState private var focused: Bool

    private let suggestions = ["What's my week like?", "Lighten today", "Quiz me on last week"]

    var body: some View {
        HomeCard(title: "Ask Orbit", symbol: "bubble.left.and.text.bubble.right.fill", color: Destination.chat.color,
                 destination: .chat) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    TextField("Ask anything about your week…", text: $draft)
                        .textFieldStyle(.plain)
                        .font(Theme.body)
                        .focused($focused)
                        .onSubmit { send(draft) }
                    Button { send(draft) } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Theme.accentGradient, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 7)
                .background(Theme.hover, in: Capsule())
                Flow(spacing: 6) {
                    ForEach(suggestions, id: \.self) { s in
                        Button(s) { send(s) }
                            .buttonStyle(.plain)
                            .font(Theme.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.accent.opacity(0.1), in: Capsule())
                    }
                }
            }
        }
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        draft = ""
        NotificationCenter.default.post(name: .orbitNavigate, object: Destination.chat)
        Task { await app.backend.sendChat(q) }
    }
}

// MARK: - Suggested from your notes

/// To-dos and notes-to-self found in handwritten notes ("find some Excel course…"),
/// each one click from the to-do list. Only on Home while there are some.
struct NoteSuggestionsCard: View {
    @Environment(OrbitBrain.self) private var brain

    var body: some View {
        HomeCard(title: "Suggested from your notes", symbol: "note.text.badge.plus", color: Destination.notes.color,
                 destination: .notes, tint: TaskOrigin.recommended.color.opacity(0.06)) {
            Text("\(brain.notesLibrary.suggestions.count)")
                .font(Theme.number(15))
                .foregroundStyle(TaskOrigin.recommended.color)
        } content: {
            NoteSuggestionsList(limit: 4)
        }
    }
}
