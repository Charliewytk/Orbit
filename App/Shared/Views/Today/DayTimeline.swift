import SwiftUI
import OrbitCore

/// A vertical timeline of the day: hour lines, events and Orbit blocks in
/// module colours side by side when they overlap, and a "now" line.
struct DayTimeline: View {
    var items: [AgendaItem]
    var allDay: [AgendaItem]
    var now: Date
    var prefs: UserPrefs
    var calendar: DayCalendar

    private let hourHeight: CGFloat = 58
    private let gutter: CGFloat = 48

    private var firstHour: Int {
        let starts = items.map { calendar.minuteOfDay($0.start) / 60 }
        return max(0, min(prefs.dayStart / 60, starts.min() ?? 24))
    }

    private var lastHour: Int {
        let ends = items.map { i -> Int in
            calendar.isSameDay(i.end, i.start) ? Int((Double(calendar.minuteOfDay(i.end)) / 60).rounded(.up)) : 24
        }
        return min(24, max(prefs.dayEnd / 60 + (prefs.dayEnd % 60 > 0 ? 1 : 0), ends.max() ?? 0))
    }

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                if !allDay.isEmpty {
                    Flow {
                        ForEach(allDay) { a in
                            Tag(text: a.title, color: Theme.moduleColor(a.moduleCode), systemImage: "sun.max")
                        }
                    }
                }
                if items.isEmpty {
                    EmptyState(systemImage: "sparkles", title: "A clear day",
                               message: "Nothing on the calendar. Add a to-do and Orbit will find it a slot.")
                } else {
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            hourGrid
                            ForEach(layout(width: geo.size.width - gutter - 4)) { placed in
                                block(placed)
                                    .frame(width: placed.width, height: placed.height)
                                    .offset(x: gutter + placed.x, y: placed.y)
                            }
                            nowLine(width: geo.size.width)
                        }
                    }
                    .frame(height: CGFloat(max(1, lastHour - firstHour)) * hourHeight + 8)
                }
            }
        }
    }

    // MARK: Pieces

    private var hourGrid: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(firstHour..<max(firstHour + 1, lastHour), id: \.self) { h in
                HStack(alignment: .top, spacing: 8) {
                    Text(String(format: "%02d:00", h))
                        .font(Theme.mono)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: gutter - 8, alignment: .trailing)
                    Rectangle().fill(Theme.border).frame(height: 0.5).padding(.top, 7)
                }
                .frame(height: hourHeight, alignment: .top)
            }
        }
    }

    @ViewBuilder
    private func nowLine(width: CGFloat) -> some View {
        let y = yPosition(now)
        if y >= 0 && y <= CGFloat(lastHour - firstHour) * hourHeight {
            HStack(spacing: 0) {
                Circle().fill(Theme.danger).frame(width: 8, height: 8)
                Rectangle().fill(Theme.danger).frame(height: 1.5)
            }
            .frame(width: max(0, width - gutter + 4))
            .offset(x: gutter - 4, y: y - 4)
            .allowsHitTesting(false)
        }
    }

    private func block(_ placed: Placed) -> some View {
        let item = placed.item
        let color = Theme.moduleColor(item.moduleCode)
        let isBlock = item.kind == .block
        let past = item.end < now
        return HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isBlock {
                        Image(systemName: item.completed ? "checkmark.circle.fill" : item.started ? "timer" : "sparkles")
                            .font(.caption2)
                    }
                    Text(item.title)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .lineLimit(placed.height > 44 ? 2 : 1)
                        .strikethrough(item.completed)
                }
                if placed.height > 34 {
                    Text(Fmt.range(item.start, item.end, calendar) + (item.location.map { " · \($0)" } ?? ""))
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.vertical, 4).padding(.trailing, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(isBlock ? 0.10 : 0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(color.opacity(isBlock ? 0.45 : 0), style: StrokeStyle(lineWidth: 1, dash: isBlock ? [4, 3] : []))
        )
        .opacity(past && !item.contains(now) ? 0.55 : 1)
    }

    // MARK: Layout

    struct Placed: Identifiable {
        var id: String { item.id }
        var item: AgendaItem
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
    }

    private func yPosition(_ date: Date) -> CGFloat {
        let minutes = calendar.isSameDay(date, now) ? calendar.minuteOfDay(date) : (date < now ? 0 : 24 * 60)
        return CGFloat(minutes - firstHour * 60) / 60 * hourHeight + 7
    }

    /// Groups overlapping items into clusters and gives each a column.
    private func layout(width: CGFloat) -> [Placed] {
        let sorted = items.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var out: [Placed] = []
        var cluster: [(AgendaItem, Int)] = []
        var clusterEnd = Date.distantPast
        var columnsEnd: [Date] = []

        func flush() {
            let columns = max(1, (cluster.map(\.1).max() ?? 0) + 1)
            let colWidth = max(40, width / CGFloat(columns))
            for (item, col) in cluster {
                let y = yPosition(item.start)
                let h = max(22, yPosition(item.end) - y - 2)
                out.append(Placed(item: item, x: CGFloat(col) * colWidth, y: y, width: colWidth - 3, height: h))
            }
            cluster = []
            columnsEnd = []
        }

        for item in sorted {
            if !cluster.isEmpty && item.start >= clusterEnd { flush() }
            if let free = columnsEnd.firstIndex(where: { $0 <= item.start }) {
                columnsEnd[free] = item.end
                cluster.append((item, free))
            } else {
                columnsEnd.append(item.end)
                cluster.append((item, columnsEnd.count - 1))
            }
            clusterEnd = cluster.isEmpty ? item.end : max(clusterEnd, item.end)
        }
        if !cluster.isEmpty { flush() }
        return out
    }
}
