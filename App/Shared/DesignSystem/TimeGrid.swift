import SwiftUI
import SwiftData
import OrbitCore

/// One thing on a time grid: a calendar event or an Orbit study block.
struct TimeGridItem: Identifiable, Hashable {
    enum Kind: Hashable { case event, block }

    var id: String
    var kind: Kind = .event
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool = false
    var color: Color
    var location: String? = nil
    var notes: String? = nil
    /// "Google", "Exeter", "Orbit"…
    var calendarName: String? = nil
    var moduleCode: String? = nil
    /// For Orbit blocks: the `StoredBlock` id.
    var blockID: String? = nil
    var completed: Bool = false
    var started: Bool = false

    func contains(_ date: Date) -> Bool { start <= date && date < end }
}

extension TimeGridItem {
    /// Converts a Today agenda item.
    init(_ a: AgendaItem) {
        self.init(id: a.id, kind: a.kind == .block ? .block : .event, title: a.title, start: a.start, end: a.end,
                  isAllDay: a.isAllDay, color: Theme.moduleColor(a.moduleCode), location: a.location,
                  calendarName: a.kind == .block ? "Orbit" : nil, moduleCode: a.moduleCode, blockID: a.blockID,
                  completed: a.completed, started: a.started)
    }
}

/// A Fantastical / Notion Calendar style time grid: hour lines, one column per
/// day, events as flat tinted blocks with a coloured left edge, a red now-line
/// and (when scrolling) an initial scroll to the current time.
struct TimeGrid<Detail: View>: View {
    var days: [Date]
    var items: [TimeGridItem]
    var calendar: DayCalendar
    var startHour: Int = 0
    var endHour: Int = 24
    var hourHeight: CGFloat = 48
    /// When false the grid takes its full height (for use inside a page).
    var scrolls: Bool = true
    var onSelectDay: ((Date) -> Void)? = nil
    @ViewBuilder var detail: (TimeGridItem) -> Detail

    @State private var selectedID: String? = nil

    private var gutter: CGFloat { 52 }
    private var topInset: CGFloat { 8 }

    var body: some View {
        VStack(spacing: 0) {
            if days.count > 1 { dayHeader }
            allDayRow
            if scrolls {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        grid
                    }
                    .onAppear { scrollToNow(proxy, animated: false) }
                    .onChange(of: days) { _, _ in scrollToNow(proxy, animated: true) }
                }
            } else {
                grid
            }
        }
    }

    // MARK: Header rows

    private var dayHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days, id: \.self) { day in
                let isToday = calendar.isSameDay(day, Date())
                Button {
                    onSelectDay?(day)
                } label: {
                    HStack(spacing: 6) {
                        Text(calendar.format(day, "EEE"))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Text(calendar.format(day, "d"))
                            .font(Theme.large.weight(isToday ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(isToday ? Color.white : Theme.textPrimary)
                            .frame(minWidth: 24, minHeight: 24)
                            .background { if isToday { Circle().fill(Theme.now) } }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(onSelectDay != nil)
            }
        }
        .padding(.vertical, Theme.Space.s)
        .hairlineBelow()
    }

    @ViewBuilder
    private var allDayRow: some View {
        let allDay = items.filter(\.isAllDay)
        if !allDay.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                Text("all-day")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: gutter - 8, alignment: .trailing)
                    .padding(.trailing, 8)
                    .padding(.top, 3)
                ForEach(days, id: \.self) { day in
                    let dayStart = calendar.startOfDay(day), dayEnd = calendar.endOfDay(day)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(allDay.filter { $0.start < dayEnd && $0.end > dayStart }) { item in
                            allDayChip(item)
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 4)
            .hairlineBelow()
        }
    }

    private func allDayChip(_ item: TimeGridItem) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(item.color).frame(width: 3)
            Text(item.title)
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
            Spacer(minLength: 0)
        }
        .background(Theme.tint(item.color))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { selectedID = item.id }
        .popover(isPresented: popoverBinding(item.id), arrowEdge: .bottom) { detail(item) }
    }

    // MARK: Grid

    private var gridHeight: CGFloat { CGFloat(max(1, endHour - startHour)) * hourHeight }

    private var grid: some View {
        HStack(alignment: .top, spacing: 0) {
            hourLabels
            GeometryReader { geo in
                let columnWidth = geo.size.width / CGFloat(max(1, days.count))
                ZStack(alignment: .topLeading) {
                    hourLines
                    if days.count > 1 { daySeparators(columnWidth: columnWidth) }
                    ForEach(days.indices, id: \.self) { index in
                        ForEach(layout(day: days[index], width: max(20, columnWidth - 6))) { placed in
                            blockView(placed)
                                .padding(.leading, CGFloat(index) * columnWidth + placed.x + 2)
                                .padding(.top, placed.y)
                        }
                    }
                    nowLine(columnWidth: columnWidth)
                }
            }
            .frame(height: gridHeight)
        }
        .padding(.top, topInset)
        .padding(.bottom, Theme.Space.s)
    }

    private var hourLabels: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(startHour..<max(startHour + 1, endHour), id: \.self) { hour in
                Text(String(format: "%02d:00", hour % 24))
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .opacity(hour == startHour && scrolls ? 0 : 1)
                    .frame(width: gutter - 8, height: hourHeight, alignment: .topTrailing)
                    .offset(y: -7)
                    .id("hour-\(hour)")
            }
        }
        .padding(.trailing, 8)
        .overlay(alignment: .topTrailing) { nowLabel }
    }

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(startHour..<max(startHour + 1, endHour), id: \.self) { _ in
                VStack(spacing: 0) {
                    Rectangle().fill(Theme.separator).frame(height: Theme.hairline)
                    Spacer(minLength: 0)
                }
                .frame(height: hourHeight)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: Theme.hairline)
        }
        .allowsHitTesting(false)
    }

    private func daySeparators(columnWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0...days.count, id: \.self) { i in
                Rectangle().fill(Theme.separator)
                    .frame(width: Theme.hairline, height: gridHeight)
                    .padding(.leading, CGFloat(i) * columnWidth)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Now

    private func nowLine(columnWidth: CGFloat) -> some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            if let index = days.firstIndex(where: { calendar.isSameDay($0, now) }), let y = yPosition(now, on: days[index]),
               y >= 0, y <= gridHeight {
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.now).frame(height: 1.5)
                    Circle().fill(Theme.now).frame(width: 7, height: 7).offset(x: -3.5)
                }
                .frame(width: days.count > 1 ? columnWidth : nil)
                .frame(maxWidth: days.count > 1 ? nil : .infinity, alignment: .leading)
                .padding(.leading, CGFloat(index) * columnWidth)
                .padding(.top, y - 3.5)
                .allowsHitTesting(false)
            }
        }
    }

    private var nowLabel: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            if let day = days.first(where: { calendar.isSameDay($0, now) }), let y = yPosition(now, on: day),
               y >= 0, y <= gridHeight {
                Text(calendar.time(now))
                    .font(Theme.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .background(Theme.now, in: Capsule())
                    .padding(.top, y - 7)
                    .padding(.trailing, 8)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Blocks

    private func blockView(_ placed: Placed) -> some View {
        let item = placed.item
        return TimeGridBlock(item: item, height: placed.height, calendar: calendar,
                             isSelected: selectedID == item.id)
            .frame(width: placed.width, height: placed.height)
            .onTapGesture { selectedID = item.id }
            .popover(isPresented: popoverBinding(item.id), arrowEdge: .trailing) { detail(item) }
    }

    private func popoverBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { selectedID == id }, set: { if !$0, selectedID == id { selectedID = nil } })
    }

    // MARK: Layout

    struct Placed: Identifiable {
        var id: String { item.id }
        var item: TimeGridItem
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
    }

    /// Y offset of `date` within `day`'s column (nil if it's on another day).
    private func yPosition(_ date: Date, on day: Date) -> CGFloat? {
        let dayStart = calendar.startOfDay(day), dayEnd = calendar.endOfDay(day)
        guard date >= dayStart, date <= dayEnd else { return nil }
        let minutes = date >= dayEnd ? 24 * 60 : calendar.minuteOfDay(date)
        return CGFloat(minutes - startHour * 60) / 60 * hourHeight
    }

    /// Clusters overlapping items and gives each a column (per day).
    private func layout(day: Date, width: CGFloat) -> [Placed] {
        let dayStart = calendar.startOfDay(day), dayEnd = calendar.endOfDay(day)
        let visibleStart = calendar.date(minute: startHour * 60, of: day)
        let visibleEnd = endHour >= 24 ? dayEnd : calendar.date(minute: endHour * 60, of: day)
        let dayItems = items
            .filter { !$0.isAllDay && $0.start < min(dayEnd, visibleEnd) && $0.end > max(dayStart, visibleStart) }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        var out: [Placed] = []
        var cluster: [(TimeGridItem, Int)] = []
        var clusterEnd = Date.distantPast
        var columnsEnd: [Date] = []

        func flush() {
            let columns = max(1, (cluster.map(\.1).max() ?? 0) + 1)
            let colWidth = width / CGFloat(columns)
            for (item, col) in cluster {
                let s = max(item.start, visibleStart), e = min(item.end, visibleEnd)
                let y = yPosition(s, on: day) ?? 0
                let yEnd = yPosition(e, on: day) ?? gridHeight
                let h = max(18, yEnd - y - 1)
                out.append(Placed(item: item, x: CGFloat(col) * colWidth, y: y, width: max(10, colWidth - 2), height: h))
            }
            cluster = []
            columnsEnd = []
        }

        for item in dayItems {
            if !cluster.isEmpty && item.start >= clusterEnd { flush() }
            if let free = columnsEnd.firstIndex(where: { $0 <= item.start }) {
                columnsEnd[free] = item.end
                cluster.append((item, free))
            } else {
                columnsEnd.append(item.end)
                cluster.append((item, columnsEnd.count - 1))
            }
            clusterEnd = cluster.count == 1 ? item.end : max(clusterEnd, item.end)
        }
        if !cluster.isEmpty { flush() }
        return out
    }

    private func scrollToNow(_ proxy: ScrollViewProxy, animated: Bool) {
        let now = Date()
        let showsToday = days.contains { calendar.isSameDay($0, now) }
        let firstEvent = items.filter { !$0.isAllDay }.map { calendar.minuteOfDay($0.start) / 60 }.min()
        var hour = showsToday ? calendar.minuteOfDay(now) / 60 - 2 : (firstEvent.map { $0 - 1 } ?? 8)
        hour = max(startHour, min(hour, endHour - 1))
        let target = "hour-\(hour)"
        if animated {
            withAnimation(Motion.smooth) { proxy.scrollTo(target, anchor: .top) }
        } else {
            DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
        }
    }
}

/// A flat tinted block with a coloured left edge.
struct TimeGridBlock: View {
    var item: TimeGridItem
    var height: CGFloat
    var calendar: DayCalendar
    var isSelected: Bool
    @State private var hovering = false

    var body: some View {
        let past = item.end < Date()
        let compact = height < 34
        let doNow = item.kind == .block && !item.completed && item.contains(Date())
        HStack(spacing: 0) {
            Rectangle().fill(item.color.gradient).frame(width: 4)
            VStack(alignment: .leading, spacing: 1) {
                if compact {
                    HStack(spacing: 4) {
                        title
                        Text(calendar.time(item.start))
                            .font(Theme.caption.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    title
                    Text(Fmt.range(item.start, item.end, calendar) + (item.location.map { " · \($0)" } ?? ""))
                        .font(Theme.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(height > 70 ? 2 : 1)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, compact ? 1 : 3)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(LinearGradient(colors: [item.color.opacity(fillOpacity + 0.06), item.color.opacity(fillOpacity)],
                                   startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
        .overlay {
            if isSelected || doNow {
                RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
                    .strokeBorder(doNow ? DoNow.color : item.color, lineWidth: doNow ? 1.5 : 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if doNow && height >= 34 {
                DoNowBadge().scaleEffect(0.85).padding(3)
            }
        }
        .shadow(color: doNow ? DoNow.color.opacity(0.35) : .clear, radius: 8)
        .opacity(past && !item.contains(Date()) ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
        .help(item.title)
    }

    private var fillOpacity: Double {
        let base = item.kind == .block ? 0.14 : 0.2
        return hovering || isSelected ? base + 0.08 : base
    }

    private var title: some View {
        Text(item.title)
            .font(Theme.caption.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .strikethrough(item.completed)
            .lineLimit(height > 52 ? 2 : 1)
    }
}

/// The popover shown when an event or block is clicked.
struct TimeGridItemDetail: View {
    @Environment(AppModel.self) private var app
    @Query private var blocks: [StoredBlock]
    var item: TimeGridItem

    private var block: StoredBlock? { item.blockID.flatMap { id in blocks.first { $0.id == id } } }

    var body: some View {
        let cal = app.calendar
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                RoundedRectangle(cornerRadius: 1.5).fill(item.color).frame(width: 3, height: 14)
                Text(item.title)
                    .font(Theme.large.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(item.isAllDay ? "\(Fmt.day(item.start, cal)) · all day"
                     : "\(Fmt.day(item.start, cal)) · \(Fmt.range(item.start, item.end, cal))")
                    .monospacedDigit()
                if let location = item.location, !location.isEmpty {
                    Label(location, systemImage: "mappin").labelStyle(DetailLabelStyle())
                }
                if let name = item.calendarName {
                    Label(name, systemImage: "calendar").labelStyle(DetailLabelStyle())
                }
                if let code = item.moduleCode { ModuleTag(code: code) }
            }
            .font(Theme.body)
            .foregroundStyle(Theme.textSecondary)

            if let notes = item.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                Hairline()
                Text(notes)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }

            if let block, !block.completed {
                Hairline()
                HStack(spacing: Theme.Space.s) {
                    if block.startedAt == nil {
                        Button("Start") { withAnimation(Motion.snappy) { app.start(block) } }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Done") { withAnimation(Motion.snappy) { app.done(block) } }
                        .buttonStyle(.bordered)
                    Button("Skip") { withAnimation(Motion.snappy) { app.skip(block) } }
                        .buttonStyle(.borderless)
                }
                .controlSize(.small)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 280, alignment: .leading)
    }
}

/// Icon in tertiary, title in the inherited style.
struct DetailLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundStyle(Theme.textTertiary).imageScale(.small)
            configuration.title
        }
    }
}
