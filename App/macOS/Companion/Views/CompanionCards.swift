import SwiftUI
import SwiftData
import OrbitCore

// MARK: - Home cards

struct BriefingCard: View {
    private var companion: CompanionHub { .shared }

    var body: some View {
        HomeCard(title: "Morning briefing", symbol: Destination.briefing.symbol, color: Destination.briefing.color, destination: .briefing) {
            if let b = companion.state.briefing {
                VStack(alignment: .leading, spacing: 6) {
                    if let w = b.weather {
                        Label(w.line, systemImage: w.symbol).font(Theme.body).foregroundStyle(Theme.textPrimary)
                    }
                    Text(b.notificationBody).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(4)
                    ForEach(b.news.prefix(3)) { n in
                        Text("• " + n.story.title).font(Theme.caption).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    }
                }
            } else {
                Text("Arrives at your wake time with weather, today's plan, what's new on ELE and Ed, and three economics stories.")
                    .font(Theme.body).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

struct GradesCard: View {
    private var companion: CompanionHub { .shared }

    var body: some View {
        let p = companion.projection
        HomeCard(title: "First predictor", symbol: Destination.grades.symbol, color: Destination.grades.color, destination: .grades) {
            VStack(alignment: .leading, spacing: 4) {
                Text(p.yearProjected.map { String(format: "%.1f", $0) } ?? "–")
                    .font(Theme.number(30))
                    .foregroundStyle((p.yearProjected ?? 0) >= 70 ? Theme.success : Theme.textPrimary)
                Text(p.classification).font(Theme.caption.weight(.bold)).foregroundStyle(Theme.textTertiary)
                Text(requirementLine(p)).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
        }
    }

    private func requirementLine(_ p: GradeProjection) -> String {
        let parts = p.targets.compactMap { t -> String? in
            guard let r = p.yearRequired[t] else { return nil }
            return "\(Int(t)): need \(Int(max(0, r).rounded(.up))) avg on what's left"
        }
        return parts.isEmpty ? "Add weights and marks to see what you need." : parts.joined(separator: " · ")
    }
}

// MARK: - Money: spending (informational)

struct SpendingInsightsView: View {
    private var companion: CompanionHub { .shared }

    var body: some View {
        let o = companion.moneyOverview()
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack(alignment: .top, spacing: Theme.Space.xl) {
                    stat("This week", MoneyInsights.pounds(o.thisWeekPence))
                    stat("Typical week", MoneyInsights.pounds(o.typicalWeekPence))
                    stat(o.termLabel, MoneyInsights.pounds(o.termPence))
                    Spacer()
                }
                .padding(Theme.Space.l)
                .orbitGlassCard()
                DigestSection(title: "Last 8 weeks") { WeekBars(weeks: o.weeks) }
                DigestSection(title: "This week by category") { CategoryRows(totals: o.weekByCategory) }
                DigestSection(title: "\(o.termLabel) by category") { CategoryRows(totals: o.termByCategory) }
                if !o.alerts.isEmpty {
                    DigestSection(title: "Worth a glance") { BulletList(items: o.alerts.map(\.message)) }
                }
                Text("Just information: no limits, nothing blocked.").font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.caption.weight(.bold)).foregroundStyle(Theme.textTertiary)
            Text(value).font(Theme.number(24))
        }
    }
}

struct WeekBars: View {
    var weeks: [MoneyOverview.Week]

    var body: some View {
        let top = max(1, weeks.map(\.pence).max() ?? 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(weeks) { w in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.accent.gradient)
                        .frame(width: 28, height: max(2, 120 * CGFloat(w.pence) / CGFloat(top)))
                    Text(w.start.formatted(.dateTime.day().month(.abbreviated))).font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                }
                .help(MoneyInsights.pounds(w.pence))
            }
        }
        .frame(height: 150, alignment: .bottom)
    }
}

struct CategoryRows: View {
    var totals: [CategoryTotal]

    var body: some View {
        let top = max(1, totals.map(\.pence).max() ?? 1)
        VStack(spacing: 6) {
            ForEach(totals) { t in
                HStack {
                    Label(t.category.label, systemImage: t.category.symbol).font(Theme.body).frame(width: 170, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(Theme.accent.opacity(0.5))
                            .frame(width: max(4, g.size.width * CGFloat(t.pence) / CGFloat(top)))
                    }
                    .frame(height: 8)
                    Text(MoneyInsights.pounds(t.pence)).font(Theme.caption.monospacedDigit()).frame(width: 70, alignment: .trailing)
                }
            }
            if totals.isEmpty { Text("No spending yet.").font(Theme.body).foregroundStyle(Theme.textSecondary) }
        }
    }
}

// MARK: - Menu bar: today's to-dos

struct MenuBarTodos: View {
    @Environment(AppModel.self) private var app
    @Query(filter: #Predicate<StoredTask> { $0.completedAt == nil }) private var open: [StoredTask]

    var body: some View {
        let cal = app.calendar
        let now = Date()
        let today = open.filter { t in t.deadline.map { cal.days(from: now, to: $0) <= 0 } ?? false }.prefix(5)
        VStack(alignment: .leading, spacing: 2) {
            if !today.isEmpty {
                Text("Today's to-dos").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.xs)
                ForEach(Array(today)) { t in
                    HStack(spacing: Theme.Space.s) {
                        CircleCheckbox(isOn: false) { app.toggleComplete(t) }
                        Text(t.title).font(Theme.body).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Space.m)
                    .frame(height: 24)
                }
            }
        }
    }
}

// MARK: - Settings

struct CompanionSettingsView: View {
    @AppStorage(CompanionHub.Keys.briefingEnabled) private var briefingOn = true
    @AppStorage(CompanionHub.Keys.briefingMinute) private var briefingMinute = 7 * 60 + 35
    @AppStorage(CompanionHub.Keys.recapEnabled) private var recapOn = true
    @AppStorage(CompanionHub.Keys.recapMinute) private var recapMinute = 19 * 60
    @AppStorage(CompanionHub.Keys.recordingsAuto) private var recordingsAuto = true
    @AppStorage(CompanionHub.Keys.newsFullText) private var newsFullText = false
    @AppStorage(CompanionHub.Keys.moneyAlerts) private var moneyAlerts = true

    var body: some View {
        Form {
            Section("Daily briefing") {
                Toggle("Morning briefing notification", isOn: $briefingOn)
                DatePicker("Wake time", selection: minuteBinding($briefingMinute), displayedComponents: .hourAndMinute)
            }
            Section("Weekly review") {
                Toggle("Saturday and Sunday evening review", isOn: $recapOn)
                DatePicker("Time", selection: minuteBinding($recapMinute), displayedComponents: .hourAndMinute)
            }
            Section("Lecture recordings") {
                Toggle("Process new ELE recordings automatically", isOn: $recordingsAuto)
                Text(transcriberLine).font(.caption).foregroundStyle(.secondary)
            }
            Section("News") {
                Toggle("Fetch full articles with my own FT / Economist login", isOn: $newsFullText)
                Text("Sign-in happens on the publisher's page in an Orbit window. Orbit never asks for or stores passwords.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Money") {
                Toggle("Gentle notes about unusual spending", isOn: $moneyAlerts)
            }
        }
        .formStyle(.grouped)
    }

    private var transcriberLine: String {
        if LocalTranscriber.appleOnDeviceAvailable { return "Uses captions when provided, otherwise Apple's on-device speech recognition." }
        if LocalTranscriber.whisperBinary() != nil { return "Uses captions when provided, otherwise whisper.cpp on this Mac." }
        return "Uses captions when provided. For recordings without captions, enable on-device dictation or install whisper.cpp with a ggml model."
    }

    private func minuteBinding(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(get: { DayCalendar().date(minute: minute.wrappedValue, of: Date()) },
                set: { minute.wrappedValue = DayCalendar().minuteOfDay($0) })
    }
}
