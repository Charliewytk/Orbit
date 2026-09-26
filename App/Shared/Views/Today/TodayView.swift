import SwiftUI
import SwiftData
import OrbitCore

/// Today: a quiet Notion-like page. Date title, a one-paragraph brief, what's
/// next, the day as a time grid (or agenda), then what's due.
struct TodayView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \StoredEvent.start) private var events: [StoredEvent]
    @Query(sort: \StoredBlock.start) private var blocks: [StoredBlock]
    @Query private var tasks: [StoredTask]
    @Query private var assessments: [StoredAssessment]
    @Query(sort: \StoredBrief.createdAt, order: .reverse) private var briefs: [StoredBrief]
    @AppStorage("todayScheduleMode") private var mode: ScheduleMode = .grid
    @Environment(\.dedicatedTaskIDs) private var dedicatedTaskIDs
    @State private var showLighten = false

    enum ScheduleMode: String { case grid, list }

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .navigationTitle("Today")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Reshuffle my plan") { replan() }
                    Button("Lighten today…") { showLighten = true }
                    Divider()
                    Button("Sync now") { Task { await app.backend.syncNow() } }
                } label: {
                    Label("Plan", systemImage: "ellipsis.circle")
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
        .refreshable { await app.backend.syncNow() }
    }

    // MARK: Page

    @ViewBuilder
    private func content(now: Date) -> some View {
        let cal = app.calendar
        let items = Agenda.items(events: events, blocks: blocks, on: now, calendar: cal)
        let timed = items.filter { !$0.isAllDay }
        let next = Agenda.nextUp(events: events, blocks: blocks, now: now, calendar: cal)
        let due = Agenda.dueSoon(tasks: tasks, assessments: assessments, now: now, days: 7)
            .filter { !($0.kind == .task && dedicatedTaskIDs.contains(String($0.id.dropFirst(2)))) }
        let morning = briefs.first { $0.id == StoredBrief.id(.morning, day: now, calendar: cal) }
        let evening = briefs.first { $0.id == StoredBrief.id(.evening, day: now, calendar: cal) }

        Page {
            header(now: now, cal: cal, items: items, due: due)

            Text(briefText(morning, items: items, due: due, now: now, cal: cal))
                .font(Theme.large)
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let next {
                NextUpRow(item: next, now: now)
                    .padding(.top, Theme.Space.xl)
            }

            PageSection(title: "Schedule", accessory: {
                SegmentedHeader(options: [(ScheduleMode.grid, "Day"), (ScheduleMode.list, "List")], selection: $mode)
            }) {
                if items.isEmpty {
                    EmptyState(title: "Nothing on the calendar today.")
                } else if mode == .grid {
                    let range = hourRange(timed, cal: cal)
                    TimeGrid(days: [now], items: items.map(TimeGridItem.init), calendar: cal,
                             startHour: range.lowerBound, endHour: range.upperBound, hourHeight: 44, scrolls: false) {
                        TimeGridItemDetail(item: $0)
                    }
                } else {
                    AgendaList(items: items, now: now)
                }
            }

            if !due.isEmpty {
                PageSection(title: "Due soon", count: due.count) {
                    VStack(spacing: 0) {
                        ForEach(due) { entry in DueRow(entry: entry, now: now) }
                    }
                }
            }

            #if os(macOS)
            AcademicTodaySections(now: now)
            #endif

            if cal.minuteOfDay(now) >= app.prefs.eveningReviewTime, let evening {
                PageSection(title: "Evening review") {
                    EveningReviewText(brief: evening)
                }
            }

            #if os(iOS)
            MoreLinks()
            #endif
        }
    }

    private func header(now: Date, cal: DayCalendar, items: [AgendaItem], due: [DueEntry]) -> some View {
        let events = items.filter { $0.kind == .event && !$0.isAllDay }.count
        let focus = items.filter { $0.kind == .block }.reduce(0) { $0 + $1.minutes }
        var parts: [String] = []
        parts.append("\(events) event\(events == 1 ? "" : "s")")
        if focus > 0 { parts.append("\(Fmt.duration(focus)) focus") }
        if !due.isEmpty { parts.append("\(due.count) due soon") }
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(cal.format(now, "EEEE d MMMM"))
                .font(Theme.pageTitle)
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 0) {
                #if os(macOS)
                AcademicWeekLabel(now: now, trailingSeparator: true)
                #endif
                Text(parts.joined(separator: " · "))
                    .contentTransition(.numericText())
            }
            .font(Theme.body)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, Theme.Space.xxl)
        .padding(.bottom, Theme.Space.l)
    }

    private func briefText(_ brief: StoredBrief?, items: [AgendaItem], due: [DueEntry], now: Date, cal: DayCalendar) -> String {
        if let brief {
            let text = (brief.narrative ?? brief.plainText).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        let greeting = Fmt.greeting(app.firstName, now: now, cal: cal)
        let remaining = items.filter { !$0.isAllDay && $0.end > now && $0.kind == .event }.count
        let dueToday = due.filter { cal.days(from: now, to: $0.due) <= 0 }.count
        var sentence = "\(greeting). "
        sentence += remaining == 0 ? "Nothing else on the calendar today" : "\(remaining) more thing\(remaining == 1 ? "" : "s") on the calendar today"
        sentence += dueToday == 0 ? "." : ", and \(dueToday) due by tonight."
        if brief == nil, cal.minuteOfDay(now) < app.prefs.morningBriefTime {
            sentence += " Your brief arrives at \(Fmt.minuteOfDay(app.prefs.morningBriefTime))."
        }
        return sentence
    }

    private func hourRange(_ items: [AgendaItem], cal: DayCalendar) -> ClosedRange<Int> {
        let prefs = app.prefs
        let firstItem = items.map { cal.minuteOfDay($0.start) / 60 }.min() ?? 24
        let lastItem = items.map { i -> Int in
            cal.isSameDay(i.end, i.start) ? Int((Double(cal.minuteOfDay(i.end)) / 60).rounded(.up)) : 24
        }.max() ?? 0
        let start = max(0, min(prefs.dayStart / 60, firstItem))
        let end = min(24, max(Int((Double(prefs.dayEnd) / 60).rounded(.up)), lastItem))
        return start...max(start + 1, end)
    }

    private func replan() {
        Task {
            await app.backend.requestReplan()
            app.show(app.backend.isBrain ? "Reshuffled your plan" : "Asked your Mac to reshuffle")
        }
    }

    private func lighten(_ fraction: Double) {
        Task {
            await app.backend.lighten(day: Date(), fraction: fraction)
            app.show(app.backend.isBrain ? "Lightened today" : "Asked your Mac to lighten today")
        }
    }
}

// MARK: - Next up

struct NextUpRow: View {
    @Environment(AppModel.self) private var app
    @Query private var blocks: [StoredBlock]
    var item: AgendaItem
    var now: Date
    @State private var tick = 0

    private var block: StoredBlock? { item.blockID.flatMap { id in blocks.first { $0.id == id } } }

    var body: some View {
        let cal = app.calendar
        let isNow = item.contains(now)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(isNow ? "Now" : "Next up")
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(isNow ? Theme.accent : Theme.textTertiary)
            HStack(alignment: .center, spacing: Theme.Space.m) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.moduleColor(item.moduleCode))
                    .frame(width: 3, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(Theme.large.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text(detail(isNow: isNow, cal: cal))
                        .font(Theme.body.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Space.m)
                if let block {
                    HStack(spacing: Theme.Space.xs) {
                        if block.startedAt == nil {
                            Button("Start") { act { app.start(block) } }
                                .buttonStyle(.bordered)
                        }
                        Button("Done") { act { app.done(block) } }
                            .buttonStyle(.quiet)
                        Button("Skip") { act { app.skip(block) } }
                            .buttonStyle(SoftButtonStyle(color: Theme.textSecondary))
                    }
                    .controlSize(.small)
                }
            }
        }
        .successHaptic(tick)
    }

    private func detail(isNow: Bool, cal: DayCalendar) -> String {
        var parts = [cal.isSameDay(item.start, now) ? Fmt.range(item.start, item.end, cal)
                     : "\(Fmt.day(item.start, cal, now: now)) \(Fmt.range(item.start, item.end, cal))"]
        if let loc = item.location, !loc.isEmpty { parts.append(loc) }
        parts.append(isNow ? "until \(cal.time(item.end))" : Fmt.relative(item.start, now: now))
        return parts.joined(separator: " · ")
    }

    private func act(_ change: () -> Void) {
        tick += 1
        withAnimation(Motion.snappy) { change() }
    }
}

// MARK: - Agenda list

struct AgendaList: View {
    @Environment(AppModel.self) private var app
    var items: [AgendaItem]
    var now: Date

    var body: some View {
        let cal = app.calendar
        VStack(spacing: 0) {
            ForEach(items) { item in
                HStack(spacing: Theme.Space.m) {
                    Text(item.isAllDay ? "All day" : cal.time(item.start))
                        .font(Theme.caption.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 44, alignment: .leading)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.moduleColor(item.moduleCode))
                        .frame(width: 3, height: 16)
                    Text(item.title)
                        .font(Theme.body)
                        .foregroundStyle(item.end < now ? Theme.textTertiary : Theme.textPrimary)
                        .strikethrough(item.completed)
                        .lineLimit(1)
                    if item.kind == .block {
                        Text("Focus").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: Theme.Space.s)
                    if let loc = item.location, !loc.isEmpty {
                        Text(loc).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    if !item.isAllDay {
                        Text(Fmt.duration(item.minutes))
                            .font(Theme.caption.monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, Theme.Space.s)
                .frame(height: 32)
                .hoverRow()
            }
        }
    }
}

// MARK: - Due soon

struct DueRow: View {
    @Environment(AppModel.self) private var app
    var entry: DueEntry
    var now: Date

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: entry.kind == .assessment ? "doc.text" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 16)
            Text(entry.title)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            ModuleTag(code: entry.moduleCode)
            if let w = entry.weightPercent {
                Text("\(Int(w))%").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: Theme.Space.s)
            DueText(date: entry.due, calendar: app.calendar, now: now)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 32)
        .hoverRow()
        .onTapGesture(perform: open)
    }

    private func open() {
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

// MARK: - Evening review

struct EveningReviewText: View {
    var brief: StoredBrief

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(brief.narrative ?? brief.plainText)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let review = brief.evening {
                Text(stats(review))
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                ForEach(review.rollovers) { r in
                    Text("Rolling over: \(r.title) · \(Fmt.duration(r.minutes))")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func stats(_ review: EveningReview) -> String {
        var parts = ["\(Fmt.duration(review.minutesDone)) of \(Fmt.duration(review.minutesPlanned)) done"]
        if let rate = review.completionRate { parts.append("\(Int((rate * 100).rounded()))%") }
        if review.streak.count > 0 { parts.append("\(review.streak.count)-day streak") }
        return parts.joined(separator: " · ")
    }
}
