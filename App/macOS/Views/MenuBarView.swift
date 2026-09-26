import SwiftUI
import SwiftData
import OrbitCore

/// The menu bar popover: next up, today at a glance, quick add.
struct MenuBarView: View {
    @Environment(AppModel.self) private var app
    @Environment(OrbitBrain.self) private var brain
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \StoredEvent.start) private var events: [StoredEvent]
    @Query(sort: \StoredBlock.start) private var blocks: [StoredBlock]
    @Query private var tasks: [StoredTask]
    @Query private var assessments: [StoredAssessment]

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .frame(width: 320)
    }

    private func content(now: Date) -> some View {
        let cal = app.calendar
        let upcoming = Agenda.upcoming(events: events, blocks: blocks, now: now, calendar: cal, limit: 4)
        let due = Agenda.dueSoon(tasks: tasks, assessments: assessments, now: now, days: 3).prefix(4)
        let todayItems = Agenda.items(events: events, blocks: blocks, on: now, calendar: cal)
        let eventsToday = todayItems.filter { $0.kind == .event && !$0.isAllDay }.count
        let tasksToday = tasks.filter { t in !t.isDone && (t.deadline.map { cal.days(from: now, to: $0) <= 0 } ?? false) }.count

        return VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text(cal.format(now, "EEEE d MMMM"))
                    .font(Theme.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(eventsToday) events · \(tasksToday) due")
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.s)

            // Next up
            if upcoming.isEmpty {
                Text("Nothing else today.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.s)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, item in
                        upcomingRow(item, first: index == 0, now: now, cal: cal)
                    }
                }
                .padding(.horizontal, Theme.Space.xs)
            }

            if !due.isEmpty {
                Hairline().padding(.vertical, Theme.Space.xs)
                Text("Due soon")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.top, Theme.Space.xs)
                VStack(spacing: 0) {
                    ForEach(Array(due)) { d in
                        HStack(spacing: Theme.Space.s) {
                            ModuleDot(code: d.moduleCode, size: 7)
                            Text(d.title).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Spacer(minLength: Theme.Space.s)
                            DueText(date: d.due, calendar: cal, now: now, style: .short)
                        }
                        .padding(.horizontal, Theme.Space.s)
                        .frame(height: 26)
                        .hoverRow()
                    }
                }
                .padding(.horizontal, Theme.Space.xs)
            }

            Hairline().padding(.vertical, Theme.Space.xs)
            QuickAddField(placeholder: "Quick add")
                .padding(.horizontal, Theme.Space.xs)

            Hairline().padding(.top, Theme.Space.xs)
            HStack(spacing: Theme.Space.xs) {
                Button("Open Orbit") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Sync now") { Task { await brain.syncNow() } }
                // TODO(features): focus timer and "Update available" from App/macOS/Features/ go here.
                Spacer()
                BrainStatusFooter().fixedSize()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(SoftButtonStyle(color: Theme.textSecondary))
            .font(Theme.caption)
            .padding(.horizontal, Theme.Space.xs)
            .padding(.vertical, Theme.Space.xs)
        }
        .background(Theme.background)
    }

    private func upcomingRow(_ item: AgendaItem, first: Bool, now: Date, cal: DayCalendar) -> some View {
        let isNow = item.contains(now)
        return HStack(alignment: .center, spacing: Theme.Space.s) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.moduleColor(item.moduleCode))
                .frame(width: 3, height: first ? 30 : 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(first ? Theme.body.weight(.medium) : Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if first {
                    Text(isNow ? "Now · until \(cal.time(item.end))"
                         : "\(Fmt.day(item.start, cal)) \(Fmt.range(item.start, item.end, cal)) · \(Fmt.relative(item.start, now: now))")
                        .font(Theme.caption.monospacedDigit())
                        .foregroundStyle(isNow ? Theme.accent : Theme.textSecondary)
                }
            }
            Spacer(minLength: Theme.Space.s)
            if !first {
                Text(cal.isSameDay(item.start, now) ? cal.time(item.start) : Fmt.shortDue(item.start, cal, now: now))
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            } else if let blockID = item.blockID, let block = blocks.first(where: { $0.id == blockID }) {
                CircleCheckbox(isOn: block.completed) { app.done(block) }
                    .help("Mark done")
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, first ? 6 : 4)
        .hoverRow()
    }
}
