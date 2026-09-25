import SwiftUI
import SwiftData
import OrbitCore

/// The menu bar popover: next up, quick add and status.
struct MenuBarView: View {
    @Environment(AppModel.self) private var app
    @Environment(OrbitBrain.self) private var brain
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \StoredEvent.start) private var events: [StoredEvent]
    @Query(sort: \StoredBlock.start) private var blocks: [StoredBlock]
    @Query private var tasks: [StoredTask]
    @Query private var assessments: [StoredAssessment]
    @State private var text = ""

    var body: some View {
        let now = Date()
        let cal = app.calendar
        let upcoming = Agenda.upcoming(events: events, blocks: blocks, now: now, calendar: cal, limit: 3)
        let due = Agenda.dueSoon(tasks: tasks, assessments: assessments, now: now, days: 3).prefix(3)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Orbit").font(Theme.title(18))
                Spacer()
                BrainStatusFooter().fixedSize()
            }

            if upcoming.isEmpty {
                Text("Nothing else today.").font(Theme.callout).foregroundStyle(Theme.textSecondary)
            }
            ForEach(Array(upcoming.enumerated()), id: \.element.id) { i, item in
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.moduleColor(item.moduleCode)).frame(width: 4, height: i == 0 ? 40 : 28)
                    VStack(alignment: .leading, spacing: 2) {
                        if i == 0 {
                            Text(item.contains(now) ? "NOW" : "NEXT UP").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                        Text(item.title).font(i == 0 ? Theme.headline : Theme.callout).lineLimit(1)
                        Text("\(Fmt.day(item.start, cal)) \(Fmt.range(item.start, item.end, cal))")
                            .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if i == 0, let blockID = item.blockID, let block = blocks.first(where: { $0.id == blockID }) {
                        Button { app.done(block) } label: { Image(systemName: "checkmark.circle") }
                            .buttonStyle(.borderless).help("Mark done")
                    }
                }
            }

            if !due.isEmpty {
                Divider()
                ForEach(Array(due)) { d in
                    HStack {
                        Image(systemName: d.kind == .assessment ? "graduationcap" : "flag")
                            .foregroundStyle(Theme.moduleColor(d.moduleCode))
                        Text(d.title).lineLimit(1)
                        Spacer()
                        Text(Fmt.due(d.due, cal, now: now)).foregroundStyle(d.isOverdue ? Theme.danger : Theme.textSecondary)
                    }
                    .font(Theme.caption)
                }
            }

            Divider()
            HStack {
                Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
                TextField("Quick add… “read ch. 4 BEM2031 1h by Thu”", text: $text)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        if app.addTask(text: text) != nil { text = "" }
                    }
            }
            if !text.isEmpty {
                let parsed = app.parse(text).task
                Text("\(parsed.title) · \(Fmt.duration(parsed.estimateMinutes))\(parsed.deadline.map { " · due \(Fmt.dayTime($0, cal))" } ?? "")")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }

            Divider()
            HStack {
                Button("Open Orbit") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Sync now") { Task { await brain.syncNow() } }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(Theme.caption)
        }
        .padding(16)
        .frame(width: 340)
    }
}
