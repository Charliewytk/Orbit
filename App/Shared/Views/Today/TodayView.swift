import SwiftUI
import SwiftData
import OrbitCore

struct TodayView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \StoredEvent.start) private var events: [StoredEvent]
    @Query(sort: \StoredBlock.start) private var blocks: [StoredBlock]
    @Query private var tasks: [StoredTask]
    @Query private var assessments: [StoredAssessment]
    @Query(sort: \StoredBrief.createdAt, order: .reverse) private var briefs: [StoredBrief]
    @State private var showLighten = false
    @State private var working = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .orbitBackground()
        .navigationTitle("Today")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await app.backend.syncNow() }
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
        .refreshable { await app.backend.syncNow() }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let cal = app.calendar
        let items = Agenda.items(events: events, blocks: blocks, on: now, calendar: cal)
        let next = Agenda.nextUp(events: events, blocks: blocks, now: now, calendar: cal)
        let due = Agenda.dueSoon(tasks: tasks, assessments: assessments, now: now, days: 7)
        let morningID = StoredBrief.id(.morning, day: now, calendar: cal)
        let eveningID = StoredBrief.id(.evening, day: now, calendar: cal)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(now: now, cal: cal)

                MorningBriefCard(brief: briefs.first { $0.id == morningID }, items: items, due: due,
                                 briefTime: app.prefs.morningBriefTime)

                if let next {
                    NextUpCard(item: next, now: now)
                }

                if !due.isEmpty {
                    DueSoonStrip(items: due, now: now)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Your day",
                                  subtitle: summary(items),
                                  actionTitle: nil)
                    DayTimeline(items: items.filter { !$0.isAllDay }, allDay: items.filter(\.isAllDay),
                                now: now, prefs: app.prefs, calendar: cal)
                }

                actions

                if cal.minuteOfDay(now) >= app.prefs.eveningReviewTime {
                    EveningReviewCard(brief: briefs.first { $0.id == eveningID })
                }

                #if os(iOS)
                MoreLinks()
                #endif
            }
            .padding(Theme.padding)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    private func header(now: Date, cal: DayCalendar) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cal.format(now, "EEEE d MMMM").uppercased())
                .font(Theme.caption)
                .tracking(1.2)
                .foregroundStyle(Theme.textTertiary)
            Text(Fmt.greeting(app.firstName, now: now, cal: cal))
                .font(Theme.title(30))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.top, 8)
    }

    private func summary(_ items: [AgendaItem]) -> String {
        let events = items.filter { $0.kind == .event && !$0.isAllDay }.count
        let planned = items.filter { $0.kind == .block }.reduce(0) { $0 + $1.minutes }
        return "\(events) event\(events == 1 ? "" : "s") · \(Fmt.duration(planned)) of focus planned"
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                showLighten = true
            } label: {
                Label("Lighten my day", systemImage: "leaf")
            }
            .buttonStyle(SoftButtonStyle(color: Theme.success))
            .confirmationDialog("How much lighter?", isPresented: $showLighten, titleVisibility: .visible) {
                Button("A little (move a quarter)") { lighten(0.25) }
                Button("Half") { lighten(0.5) }
                Button("Most of it") { lighten(0.75) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Orbit moves the rest of today's planned work to later days.")
            }

            Button {
                working = true
                Task {
                    await app.backend.requestReplan()
                    working = false
                    app.show(app.backend.isBrain ? "Reshuffled your plan" : "Asked your Mac to reshuffle")
                }
            } label: {
                Label("Reshuffle", systemImage: "shuffle")
            }
            .buttonStyle(SoftButtonStyle())
            .disabled(working)

            Spacer()
            if working || app.backend.isThinking { ProgressView().controlSize(.small) }
        }
        .haptic(working)
    }

    private func lighten(_ fraction: Double) {
        working = true
        Task {
            await app.backend.lighten(day: Date(), fraction: fraction)
            working = false
            app.show(app.backend.isBrain ? "Lightened today" : "Asked your Mac to lighten today")
        }
    }
}

// MARK: - Morning brief

struct MorningBriefCard: View {
    var brief: StoredBrief?
    var items: [AgendaItem]
    var due: [DueEntry]
    var briefTime: MinuteOfDay

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Morning brief", systemImage: "sun.max.fill")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.warning)
                    Spacer()
                    if let brief { Text(brief.createdAt, style: .time).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                }
                if let brief {
                    Text(brief.narrative ?? brief.plainText)
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text("Your brief arrives at \(Fmt.minuteOfDay(briefTime)). Here's the shape of the day so far.")
                        .font(Theme.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: 10) {
                    stat(value: "\(eventsCount)", label: "events", symbol: "calendar")
                    stat(value: Fmt.duration(plannedMinutes), label: "focus", symbol: "timer")
                    stat(value: "\(due.count)", label: "due soon", symbol: "flag")
                    if let cards = brief?.morning?.flashcardsDue, cards > 0 {
                        stat(value: "\(cards)", label: "cards", symbol: "rectangle.on.rectangle")
                    }
                }
            }
        }
    }

    private var eventsCount: Int { brief?.morning?.events.count ?? items.filter { $0.kind == .event && !$0.isAllDay }.count }
    private var plannedMinutes: Int { brief?.morning?.plannedMinutes ?? items.filter { $0.kind == .block }.reduce(0) { $0 + $1.minutes } }

    private func stat(value: String, label: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(value, systemImage: symbol)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .labelStyle(.titleAndIcon)
            Text(label).font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
    }
}

// MARK: - Next up

struct NextUpCard: View {
    @Environment(AppModel.self) private var app
    @Query private var blocks: [StoredBlock]
    var item: AgendaItem
    var now: Date
    @State private var tick = 0

    private var block: StoredBlock? { item.blockID.flatMap { id in blocks.first { $0.id == id } } }
    private var isNow: Bool { item.contains(now) }

    var body: some View {
        let color = Theme.moduleColor(item.moduleCode)
        Card {
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 5)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(isNow ? "NOW" : "NEXT UP")
                            .font(Theme.caption).tracking(1.2)
                            .foregroundStyle(isNow ? Theme.success : Theme.accent)
                        Spacer()
                        ModuleChip(code: item.moduleCode)
                    }
                    Text(item.title)
                        .font(Theme.title(22))
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 8) {
                        Label(Fmt.range(item.start, item.end, app.calendar), systemImage: "clock")
                        if !isNow {
                            Text("·")
                            Text(item.start, style: .relative)
                        }
                        if let loc = item.location, !loc.isEmpty {
                            Text("·")
                            Label(loc, systemImage: "mappin").lineLimit(1)
                        }
                    }
                    .font(Theme.callout)
                    .foregroundStyle(Theme.textSecondary)

                    if let block {
                        HStack(spacing: 8) {
                            if block.startedAt == nil {
                                Button { tick += 1; withAnimation(Theme.spring) { app.start(block) } } label: {
                                    Label("Start", systemImage: "play.fill")
                                }
                                .buttonStyle(PillButtonStyle(color: color))
                            } else {
                                Label("In progress", systemImage: "timer")
                                    .font(Theme.caption).foregroundStyle(Theme.success)
                            }
                            Button { tick += 1; withAnimation(Theme.spring) { app.done(block) } } label: {
                                Label("Done", systemImage: "checkmark")
                            }
                            .buttonStyle(SoftButtonStyle(color: Theme.success))
                            Button { tick += 1; withAnimation(Theme.spring) { app.skip(block) } } label: {
                                Label("Skip", systemImage: "forward")
                            }
                            .buttonStyle(SoftButtonStyle(color: Theme.textSecondary))
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
        .successHaptic(tick)
    }
}

// MARK: - Due soon

struct DueSoonStrip: View {
    @Environment(AppModel.self) private var app
    var items: [DueEntry]
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Due soon", subtitle: "Next 7 days")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: item.kind == .assessment ? "graduationcap.fill" : "checkmark.circle")
                                    .foregroundStyle(Theme.moduleColor(item.moduleCode))
                                ModuleChip(code: item.moduleCode)
                                if let w = item.weightPercent { Tag(text: "\(Int(w))%") }
                            }
                            Text(item.title)
                                .font(.system(.callout, design: .rounded).weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(2)
                            Text(Fmt.due(item.due, app.calendar, now: now))
                                .font(Theme.caption)
                                .foregroundStyle(item.isOverdue || item.due.timeIntervalSince(now) < 86400 ? Theme.danger : Theme.textSecondary)
                        }
                        .padding(12)
                        .frame(width: 190, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
                    }
                }
            }
        }
    }
}

// MARK: - Evening review

struct EveningReviewCard: View {
    var brief: StoredBrief?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Evening review", systemImage: "moon.stars.fill")
                    .font(Theme.headline)
                    .foregroundStyle(Theme.accent)
                if let brief, let review = brief.evening {
                    Text(brief.narrative ?? brief.plainText)
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        ProgressRing(progress: review.completionRate ?? 0, color: Theme.success, lineWidth: 5,
                                     label: review.completionRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                            .frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(Fmt.duration(review.minutesDone)) of \(Fmt.duration(review.minutesPlanned)) done")
                                .font(Theme.callout).foregroundStyle(Theme.textPrimary)
                            Label("\(review.streak.count)-day streak (best \(review.streak.best))", systemImage: "flame")
                                .font(Theme.caption).foregroundStyle(Theme.warning)
                        }
                    }
                    if !review.rollovers.isEmpty {
                        Text("Rolling over")
                            .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        ForEach(review.rollovers) { r in
                            Label("\(r.title) · \(Fmt.duration(r.minutes))", systemImage: "arrow.uturn.right")
                                .font(Theme.callout).foregroundStyle(Theme.textPrimary)
                        }
                    }
                } else {
                    Text("Your wrap-up of the day will appear here shortly.")
                        .font(Theme.callout).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}
