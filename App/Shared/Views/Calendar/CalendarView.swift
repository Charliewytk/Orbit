import SwiftUI
import SwiftData
import OrbitCore

/// Day / week calendar: Google and Exeter events plus Orbit's study blocks on
/// one time grid. Click anything for details.
struct CalendarView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \StoredEvent.start) private var events: [StoredEvent]
    @Query(sort: \StoredBlock.start) private var blocks: [StoredBlock]
    @Query private var tasks: [StoredTask]
    @AppStorage("calendarMode") private var mode: Mode = .week
    @State private var anchor = Date()

    enum Mode: String { case day, week }

    var body: some View {
        let cal = app.calendar
        let days = visibleDays(cal)
        let start = days.first ?? cal.startOfDay(anchor)
        let end = cal.endOfDay(days.last ?? anchor)
        VStack(spacing: 0) {
            header(cal: cal, days: days)
            TimeGrid(days: days, items: items(from: start, to: end, cal: cal), calendar: cal,
                     hourHeight: mode == .day ? 56 : 48, scrolls: true,
                     onSelectDay: { day in
                         anchor = day
                         withAnimation(Motion.snappy) { mode = .day }
                     }) {
                TimeGridItemDetail(item: $0)
            }
            .id(mode)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .orbitGlassCard()
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.l)
        }
        .orbitBackground()
        .navigationTitle("Calendar")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { step(-1) } label: { Label("Previous", systemImage: "chevron.left") }
                    .help(mode == .day ? "Previous day" : "Previous week")
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button { step(1) } label: { Label("Next", systemImage: "chevron.right") }
                    .help(mode == .day ? "Next day" : "Next week")
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
            }
        }
    }

    private func header(cal: DayCalendar, days: [Date]) -> some View {
        let first = days.first ?? anchor
        let isCurrent = days.contains { cal.isSameDay($0, Date()) }
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(mode == .day ? cal.format(first, "EEEE d MMMM") : cal.format(first, "MMMM yyyy"))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            if mode == .week {
                Text("Week of \(cal.format(first, "d MMM"))")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Space.m)
            OriginLegend()
            Button("Today") { withAnimation(Motion.snappy) { anchor = Date() } }
                .orbitGlassButton()
                .disabled(isCurrent)
                .keyboardShortcut("t", modifiers: [.command])
            SegmentedHeader(options: [(Mode.day, "Day"), (Mode.week, "Week")], selection: $mode)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.s)
    }

    private func visibleDays(_ cal: DayCalendar) -> [Date] {
        switch mode {
        case .day: return [cal.startOfDay(anchor)]
        case .week:
            let monday = cal.startOfWeek(anchor)
            return (0..<7).map { cal.addingDays($0, to: monday) }
        }
    }

    private func step(_ direction: Int) {
        let cal = app.calendar
        withAnimation(Motion.snappy) {
            anchor = cal.addingDays(direction * (mode == .day ? 1 : 7), to: anchor)
        }
    }

    private func items(from start: Date, to end: Date, cal: DayCalendar) -> [TimeGridItem] {
        var out: [TimeGridItem] = events
            .filter { $0.start < end && $0.end > start }
            .map { e in
                let code = ModuleCode.find(in: e.title)
                return TimeGridItem(id: "e-\(e.id)", kind: .event, title: e.title, start: e.start, end: e.end,
                                    isAllDay: e.isAllDay, color: Self.color(for: e.source, moduleCode: code),
                                    location: e.location, notes: e.notes, calendarName: Self.label(for: e.source),
                                    moduleCode: code)
            }
        let taskByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        out += blocks
            .filter { $0.start < end && $0.end > start && !$0.skipped }
            .map { b in
                // Blocks are coloured by where their work came from (You set / Orbit recommends / Required).
                let origin = taskByID[b.taskID]?.origin ?? .recommended
                return TimeGridItem(id: "b-\(b.id)", kind: .block, title: b.title, start: b.start, end: b.end,
                                    color: origin.color,
                                    calendarName: "Orbit study block · \(origin.label)", moduleCode: b.moduleCode, blockID: b.id,
                                    completed: b.completed, started: b.startedAt != nil)
            }
        return out
    }

    /// Module colour when the title names a module; otherwise a calm colour per calendar.
    static func color(for source: CalendarSource, moduleCode: String?) -> Color {
        if let moduleCode { return Theme.moduleColor(moduleCode) }
        switch source {
        case .google: return Theme.paletteColor(4)
        case .local, .outlook, .timetable: return Theme.paletteColor(5)
        case .ele: return Theme.paletteColor(1)
        case .orbit: return Theme.success
        }
    }

    static func label(for source: CalendarSource) -> String {
        switch source {
        case .google: "Google Calendar"
        case .local: "Calendar on this Mac"
        case .outlook: "Exeter (Outlook)"
        case .timetable: "Timetable"
        case .ele: "ELE"
        case .orbit: "Orbit"
        }
    }
}
