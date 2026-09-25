import WidgetKit
import SwiftUI

// Widgets read only the small JSON snapshot the app writes into the App Group
// after each sync (see `WidgetSnapshot`), so they never touch the database.

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot: WidgetSnapshot = context.isPreview ? .placeholder : (WidgetSnapshot.load() ?? .empty)
        completion(SnapshotEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load() ?? .empty
        let now = Date()
        // One entry now, then one as each upcoming item finishes, so "next up" moves on by itself.
        var dates = [now]
        dates += snapshot.nextUp.compactMap(\.end).filter { $0 > now }.prefix(5)
        let entries = dates.map { SnapshotEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

@main
struct OrbitWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextUpWidget()
        DueThisWeekWidget()
    }
}

// MARK: - Next up

struct NextUpWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OrbitNextUp", provider: SnapshotProvider()) { entry in
            NextUpWidgetView(entry: entry)
                .containerBackground(for: .widget) { Theme.background }
        }
        .configurationDisplayName("Next up")
        .description("What's on now and next.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NextUpWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: SnapshotEntry

    private var items: [WidgetSnapshot.Item] { entry.snapshot.nextUp(at: entry.date) }

    var body: some View {
        if let first = items.first {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(isNow(first) ? "NOW" : "NEXT UP")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(isNow(first) ? Theme.success : Theme.accent)
                    Spacer()
                    if let code = first.moduleCode {
                        Text(code).font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.moduleColor(code))
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.moduleColor(first.moduleCode)).frame(width: 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(first.title)
                            .font(.system(.headline, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(family == .systemSmall ? 3 : 2)
                        if let start = first.start {
                            timeText(first, start: start)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        if let detail = first.detail, family != .systemSmall {
                            Text(detail).font(.caption2).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                    }
                }
                if family == .systemMedium, items.count > 1 {
                    Divider()
                    ForEach(items.dropFirst().prefix(2)) { item in
                        HStack(spacing: 6) {
                            Circle().fill(Theme.moduleColor(item.moduleCode)).frame(width: 6, height: 6)
                            Text(item.title).font(.caption).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Spacer()
                            if let start = item.start { Text(start, style: .time).font(.caption2).foregroundStyle(Theme.textSecondary) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text("Nothing else today").font(.system(.headline, design: .rounded)).foregroundStyle(Theme.textPrimary)
                Text("Enjoy the space.").font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
        }
    }

    private func isNow(_ item: WidgetSnapshot.Item) -> Bool {
        guard let s = item.start, let e = item.end else { return false }
        return s <= entry.date && entry.date < e
    }

    @ViewBuilder
    private func timeText(_ item: WidgetSnapshot.Item, start: Date) -> some View {
        if isNow(item), let end = item.end {
            Text("until \(end, style: .time)")
        } else if Calendar.current.isDate(start, inSameDayAs: entry.date) {
            Text(start, style: .time)
        } else {
            Text("Tomorrow \(start, style: .time)")
        }
    }
}

// MARK: - Due this week

struct DueThisWeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OrbitDueThisWeek", provider: SnapshotProvider()) { entry in
            DueWidgetView(entry: entry)
                .containerBackground(for: .widget) { Theme.background }
        }
        .configurationDisplayName("Due this week")
        .description("Deadlines and assessments in the next seven days.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct DueWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: SnapshotEntry

    var body: some View {
        let items = entry.snapshot.dueThisWeek.prefix(family == .systemLarge ? 8 : 3)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Due this week", systemImage: "flag.fill")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Spacer()
                Text("\(entry.snapshot.dueThisWeek.count)")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            if items.isEmpty {
                Text("Nothing due. Nice.").font(.callout).foregroundStyle(Theme.textSecondary)
            }
            ForEach(Array(items)) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.kind == .assessment ? "graduationcap.fill" : "checkmark.circle")
                        .foregroundStyle(Theme.moduleColor(item.moduleCode))
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.caption.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        HStack(spacing: 4) {
                            if let code = item.moduleCode { Text(code).foregroundStyle(Theme.moduleColor(code)) }
                            if let detail = item.detail { Text(detail) }
                        }
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if let due = item.due {
                        Text(due, format: .dateTime.weekday(.abbreviated).hour().minute())
                            .font(.caption2)
                            .foregroundStyle(due < entry.date.addingTimeInterval(86400) ? Theme.danger : Theme.textSecondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
