import SwiftUI
import OrbitCore

// Traffic-light colours come from the design system (`RAGStatus.color` in DesignSystem/Helpers.swift).

/// "On track for a First?" — this week's traffic lights per module, and past weeks.
struct WeeklyReportView: View {
    @State private var selected: String?
    @State private var working = false
    private var hub: FeatureHub { .shared }

    var body: some View {
        let reports = hub.state.reports
        let report = reports.first { $0.weekKey == selected } ?? reports.first

        List {
            if let report {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Circle().fill(report.overall.color).frame(width: 10, height: 10)
                            Text(report.headline).font(.system(size: 17, weight: .semibold))
                        }
                        Text("Week ending \(hub.cal.shortDay(report.generatedAt))"
                             + (report.yearAverage.map { String(format: " · average %.0f%%", $0) } ?? "")
                             + " · studied \(Fmt.duration(report.minutesDone)) of \(Fmt.duration(report.minutesPlanned)) planned")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if let n = report.narrative { Text(n).padding(.top, 4) }
                    }
                    .padding(.vertical, 4)
                }
                if !report.topActions.isEmpty {
                    Section("This week") {
                        ForEach(Array(report.topActions.enumerated()), id: \.offset) { i, action in
                            Text("\(i + 1). \(action)")
                        }
                    }
                }
                ForEach(report.modules) { m in
                    Section {
                        ForEach(m.reasons, id: \.text) { r in
                            Label {
                                Text(r.text)
                            } icon: {
                                Circle().fill(r.status.color).frame(width: 7, height: 7)
                            }
                        }
                        ForEach(m.wins, id: \.self) { w in
                            Label(w, systemImage: "checkmark").foregroundStyle(.secondary)
                        }
                        Text(metrics(m)).font(.system(size: 11)).foregroundStyle(.tertiary)
                    } header: {
                        HStack(spacing: 6) {
                            Circle().fill(m.status.color).frame(width: 8, height: 8)
                            Text(m.moduleName.isEmpty ? ModuleLabel.title(m.moduleCode) : m.moduleName)
                        }
                    }
                }
            } else {
                ContentUnavailableView("No report yet", systemImage: "chart.bar",
                                       description: Text("Orbit writes one every Sunday at 18:00. Make one now to see where you stand."))
            }
        }
        .toolbar {
            if reports.count > 1 {
                Picker("Week", selection: $selected) {
                    ForEach(reports) { r in Text(hub.cal.shortDay(r.generatedAt)).tag(String?.some(r.weekKey)) }
                }
            }
            Button(working ? "Making…" : "Make report now") {
                working = true
                Task { await hub.makeWeeklyReport(); selected = nil; working = false }
            }
            .disabled(working)
        }
        .navigationTitle("On track for a First?")
    }

    private func metrics(_ m: ModuleOnTrack) -> String {
        var parts: [String] = []
        if m.readingsAssigned > 0 { parts.append("Readings \(m.readingsDone)/\(m.readingsAssigned)") }
        if m.lecturesHeld > 0 { parts.append("Lectures with notes \(m.lecturesWithNotes)/\(m.lecturesHeld)") }
        if m.homeworkTotal > 0 { parts.append("Homework \(m.homeworkDone)/\(m.homeworkTotal)") }
        if let avg = m.currentAverage { parts.append(String(format: "Marks %.0f%%", avg)) }
        if let req = m.requiredOnRemaining, m.outlook != .secured { parts.append(String(format: "Need %.0f%% on the rest", req)) }
        parts.append("Study \(Fmt.duration(m.minutesDone))/\(Fmt.duration(m.minutesPlanned))")
        return parts.joined(separator: " · ")
    }
}

/// Recurring themes in marker feedback.
struct FeedbackThemesView: View {
    private var hub: FeatureHub { .shared }

    var body: some View {
        let ledger = hub.feedbackLedger
        List {
            if ledger.themes.isEmpty {
                ContentUnavailableView("No feedback yet", systemImage: "text.bubble",
                                       description: Text("When marks and comments arrive on ELE, the recurring points show up here and in the plan for your next assessment."))
            }
            if !ledger.toWorkOn.isEmpty {
                Section("To work on") {
                    ForEach(ledger.toWorkOn) { t in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(t.label.prefix(1).uppercased() + t.label.dropFirst()).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text("\(t.needsWorkCount)×").monospacedDigit().foregroundStyle(.secondary)
                            }
                            if let advice = FeedbackTheme.known(t.themeID)?.advice { Text("Next time: \(advice).") }
                            if let quote = t.examples.first { Text("“\(quote)”").font(.system(size: 11)).foregroundStyle(.secondary) }
                            Text("\(t.modules.joined(separator: ", ")) · last on \(t.lastAssessment)")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            if !ledger.strengths.isEmpty {
                Section("Strengths") {
                    ForEach(ledger.strengths) { t in
                        Label("\(t.label.prefix(1).uppercased() + t.label.dropFirst()) (\(t.praisedCount)×)", systemImage: "checkmark")
                    }
                }
            }
        }
        .navigationTitle("Feedback themes")
    }
}

/// The reading plan: which readings are split into which days.
struct ReadingPlanView: View {
    private var hub: FeatureHub { .shared }

    var body: some View {
        let chunks = hub.state.readingChunks
        let days = Dictionary(grouping: chunks, by: \.day).sorted { $0.key < $1.key }
        List {
            if chunks.isEmpty {
                ContentUnavailableView("No reading to plan", systemImage: "book",
                                       description: Text("Readings for the next ten days are split into short daily sessions and put on your plan."))
            }
            ForEach(days, id: \.key) { day, items in
                Section("\(hub.cal.format(day, "EEEE d MMM")) · \(Fmt.duration(items.reduce(0) { $0 + $1.minutes }))") {
                    ForEach(items) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title)
                            Text("\(ModuleLabel.title(c.moduleCode)) · \(c.minutes) min · finish by \(hub.cal.shortDay(c.deadline)) \(hub.cal.time(c.deadline))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .toolbar {
            Text(hub.readingStatus).font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Re-plan now") { Task { await hub.planReadingIfNeeded(now: Date(), force: true) } }
        }
        .navigationTitle("Reading plan")
    }
}

/// Upcoming deadlines and when Orbit will remind you.
struct DeadlinesView: View {
    private var hub: FeatureHub { .shared }

    var body: some View {
        let now = Date()
        let items = hub.deadlineItems(now: now).filter { $0.due > now }
        let planner = DeadlineAlertPlanner(quietHours: FeatureSettings.quietHours, timeZone: hub.prefs.timeZone)
        List {
            if items.isEmpty {
                ContentUnavailableView("No deadlines coming up", systemImage: "flag", description: Text("Nice."))
            }
            ForEach(items.prefix(40)) { item in
                let next = planner.schedule([item]).first { $0.fireAt > now && hub.state.sentDeadlineAlerts[$0.id] == nil }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text((item.moduleCode.map { ModuleLabel.title($0) + " · " } ?? "") + item.title)
                        Spacer()
                        Text("\(hub.cal.shortDay(item.due)) \(hub.cal.time(item.due))").monospacedDigit().foregroundStyle(.secondary)
                    }
                    if let step = item.nextStep { Text("Next: \(step)").font(.system(size: 11)).foregroundStyle(.secondary) }
                    if let next {
                        Text("Reminder \(hub.cal.shortDay(next.fireAt)) \(hub.cal.time(next.fireAt))")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .navigationTitle("Deadlines")
    }
}
