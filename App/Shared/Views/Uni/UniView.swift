import SwiftUI
import SwiftData
import OrbitCore

struct UniView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \StoredModule.id) private var modules: [StoredModule]
    @Query private var allAssessments: [StoredAssessment]
    @Query(sort: \StoredReading.title) private var readings: [StoredReading]
    @Query private var allAnnouncements: [StoredAnnouncement]
    @Query(sort: \StoredBrief.createdAt, order: .reverse) private var briefs: [StoredBrief]
    @Query private var tasks: [StoredTask]

    private var assessments: [StoredAssessment] {
        allAssessments.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    private var announcements: [StoredAnnouncement] {
        allAnnouncements.sorted { ($0.posted ?? .distantPast) > ($1.posted ?? .distantPast) }
    }

    var body: some View {
        let coach = StudyCoach(prefs: app.prefs)
        let values = assessments.map(\.value)
        let year = coach.yearStanding(modules: modules.map(\.value), assessments: values)
        let weekly = briefs.first { $0.kind == .weekly }

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                YearHeader(year: year, target: app.prefs.targetGrade)

                if modules.isEmpty {
                    Card {
                        EmptyState(systemImage: "graduationcap", title: "No modules yet",
                                   message: "Connect ELE in Settings on your Mac and your modules, deadlines and reading lists appear here.")
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(modules) { m in
                            ModuleCard(module: m, standing: year.modules.first { $0.moduleCode == m.id },
                                       review: weekly?.weekly?.modules.first { $0.moduleCode == m.id })
                        }
                    }
                }

                if let weekly { WeeklyReviewCard(brief: weekly) }

                AssessmentsSection(assessments: assessments.filter { !$0.submitted && $0.mark == nil },
                                   standings: year.modules, tasks: tasks)

                ReadingListsSection(modules: modules, readings: readings)

                if !announcements.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "ELE announcements")
                        ForEach(announcements.prefix(8)) { a in
                            AnnouncementRow(announcement: a)
                        }
                    }
                }
            }
            .padding(Theme.padding)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .orbitBackground()
        .navigationTitle("Uni")
    }
}

struct YearHeader: View {
    var year: YearStanding
    var target: Double

    var body: some View {
        Card {
            HStack(spacing: 18) {
                ProgressRing(progress: (year.currentAverage ?? 0) / 100, color: ringColor, lineWidth: 8,
                             label: year.currentAverage.map { "\(Int($0.rounded()))%" } ?? "–")
                    .frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Aiming for \(Int(target))%+")
                        .font(Theme.title(22))
                        .foregroundStyle(Theme.textPrimary)
                    if let req = year.requiredAverageOnRemaining {
                        Text(req <= 0 ? "You've already banked enough for your target."
                             : String(format: "Average %.0f%% on what's left to get there.", req))
                            .font(Theme.callout)
                            .foregroundStyle(req > 100 ? Theme.danger : Theme.textSecondary)
                    } else {
                        Text("Marks will show here as they come back.")
                            .font(Theme.callout).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
            }
        }
    }

    private var ringColor: Color {
        guard let avg = year.currentAverage else { return Theme.accent }
        return avg >= target ? Theme.success : avg >= target - 5 ? Theme.warning : Theme.danger
    }
}

struct ModuleCard: View {
    @Environment(AppModel.self) private var app
    var module: StoredModule
    var standing: ModuleStanding?
    var review: ModuleReview?

    var body: some View {
        let color = Theme.moduleColor(module.id)
        let rag = review?.status ?? standing?.outlook.rag ?? .green
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(module.id).font(Theme.headline).foregroundStyle(color)
                Spacer()
                StatusDot(color: rag.color)
                Text("\(module.credits) cr").font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            Text(module.name.isEmpty ? module.id : module.name)
                .font(Theme.callout.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2, reservesSpace: true)
            HStack(spacing: 12) {
                ProgressRing(progress: (standing?.currentAverage ?? 0) / 100, color: color, lineWidth: 5,
                             label: standing?.currentAverage.map { "\(Int($0.rounded()))" } ?? "–")
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    if let req = standing?.requiredAverageOnRemaining, (standing?.remainingWeight ?? 0) > 0 {
                        Text(req <= 0 ? "Target secured" : String(format: "Need %.0f%% on the rest", req))
                            .font(Theme.caption).foregroundStyle(Theme.textPrimary)
                    } else {
                        Text("No marks yet").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Text(standing?.outlook.label ?? "On track")
                        .font(Theme.caption).foregroundStyle(rag.color)
                }
            }
            if let reasons = review?.reasons, let first = reasons.first {
                Text(first).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: Theme.radius, topTrailingRadius: Theme.radius, style: .continuous)
                .fill(color).frame(height: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

struct WeeklyReviewCard: View {
    var brief: StoredBrief

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("On track for a First?", systemImage: "chart.line.uptrend.xyaxis")
                        .font(Theme.headline).foregroundStyle(Theme.accent)
                    Spacer()
                    if let review = brief.weekly {
                        Tag(text: review.status.label, color: review.status.color)
                    }
                }
                Text(brief.narrative ?? brief.plainText)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("Weekly review · \(brief.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

struct AssessmentsSection: View {
    @Environment(AppModel.self) private var app
    var assessments: [StoredAssessment]
    var standings: [ModuleStanding]
    var tasks: [StoredTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Upcoming assessments", subtitle: "Weight, deadline and whether you're on track")
            if assessments.isEmpty {
                Card { Text("Nothing outstanding. Nice.").foregroundStyle(Theme.textSecondary) }
            }
            ForEach(assessments) { a in
                AssessmentRow(assessment: a, outlook: standings.first { $0.moduleCode == a.moduleCode }?.outlook,
                              plannedTasks: tasks.filter { $0.assessmentID == a.id })
            }
        }
    }
}

struct AssessmentRow: View {
    @Environment(AppModel.self) private var app
    var assessment: StoredAssessment
    var outlook: ModuleStanding.Outlook?
    var plannedTasks: [StoredTask]
    @State private var confirmReplan = false

    private var status: RAGStatus {
        let now = Date()
        let open = plannedTasks.filter { !$0.isDone }
        if let due = assessment.due {
            let days = due.timeIntervalSince(now) / 86400
            if plannedTasks.isEmpty && days < 7 { return .red }
            if plannedTasks.isEmpty && days < 14 { return .amber }
            let remaining = open.reduce(0) { $0 + $1.remainingMinutes }
            if days < 3 && remaining > 240 { return .red }
        }
        return outlook?.rag ?? (plannedTasks.isEmpty ? .amber : .green)
    }

    var body: some View {
        let done = plannedTasks.filter(\.isDone).count
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                StatusDot(color: status.color).padding(.top, 6)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ModuleChip(code: assessment.moduleCode)
                        if assessment.weightPercent > 0 { Tag(text: "\(Int(assessment.weightPercent))%", systemImage: "scalemass") }
                        Tag(text: assessment.kind.rawValue.capitalized)
                        Spacer()
                        if let due = assessment.due {
                            Text(Fmt.due(due, app.calendar)).font(Theme.caption)
                                .foregroundStyle(due.timeIntervalSinceNow < 3 * 86400 ? Theme.danger : Theme.textSecondary)
                        }
                    }
                    Text(assessment.title).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    if !plannedTasks.isEmpty {
                        ProgressView(value: Double(done), total: Double(max(1, plannedTasks.count))) {
                            Text("\(done) of \(plannedTasks.count) steps done").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        }
                        .tint(Theme.moduleColor(assessment.moduleCode))
                    }
                    HStack(spacing: 10) {
                        Button {
                            if plannedTasks.contains(where: { !$0.isDone }) { confirmReplan = true } else { plan() }
                        } label: {
                            Label(assessment.kind == .exam ? "Revision plan" : (plannedTasks.isEmpty ? "Plan this assessment" : "Re-plan"),
                                  systemImage: assessment.kind == .exam ? "brain" : "wand.and.stars")
                        }
                        .buttonStyle(SoftButtonStyle())
                        if let s = assessment.eleURL, let url = URL(string: s) {
                            Button { openExternal(url) } label: { Label("ELE", systemImage: "arrow.up.right.square") }
                                .buttonStyle(.borderless).font(Theme.caption)
                        }
                    }
                }
            }
        }
        .confirmationDialog("Replace the current plan?", isPresented: $confirmReplan) {
            Button("Re-plan from now") { plan() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unfinished steps for this assessment are replaced with a fresh plan.")
        }
    }

    private func plan() {
        withAnimation(Theme.spring) { _ = app.planAssessment(assessment) }
    }
}

struct ReadingListsSection: View {
    @Environment(AppModel.self) private var app
    var modules: [StoredModule]
    var readings: [StoredReading]

    var body: some View {
        let codes = Array(Set(readings.map(\.moduleCode))).sorted()
        if !codes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Reading lists")
                ForEach(codes, id: \.self) { code in
                    let items = readings.filter { $0.moduleCode == code }
                        .sorted { ($0.week ?? 99, $0.essential ? 0 : 1, $0.title) < ($1.week ?? 99, $1.essential ? 0 : 1, $1.title) }
                    Card(padding: 12) {
                        DisclosureGroup {
                            ForEach(items) { r in
                                HStack(alignment: .top, spacing: 10) {
                                    Button { withAnimation(Theme.spring) { app.toggle(r) } } label: {
                                        Image(systemName: r.done ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(r.done ? Theme.success : Theme.textSecondary)
                                    }
                                    .buttonStyle(.plain)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.title).font(Theme.callout).foregroundStyle(r.done ? Theme.textTertiary : Theme.textPrimary)
                                            .strikethrough(r.done)
                                        HStack(spacing: 6) {
                                            if r.essential { Tag(text: "Essential", color: Theme.warning) }
                                            if let w = r.week { Tag(text: "Week \(w)") }
                                        }
                                    }
                                    Spacer()
                                    if let s = r.url, let url = URL(string: s) {
                                        Button { openExternal(url) } label: { Image(systemName: "arrow.up.right.square") }
                                            .buttonStyle(.borderless)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        } label: {
                            HStack {
                                ModuleChip(code: code)
                                Text(modules.first { $0.id == code }?.name ?? "").font(Theme.callout).lineLimit(1)
                                Spacer()
                                Text("\(items.filter(\.done).count)/\(items.count)").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct AnnouncementRow: View {
    var announcement: StoredAnnouncement
    @State private var expanded = false

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ModuleChip(code: announcement.moduleCode)
                    Spacer()
                    if let d = announcement.posted {
                        Text(d.formatted(date: .abbreviated, time: .omitted)).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                Text(announcement.subject).font(Theme.callout.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Text(announcement.message).font(Theme.callout).foregroundStyle(Theme.textSecondary)
                    .lineLimit(expanded ? nil : 3)
                HStack {
                    Button(expanded ? "Less" : "More") { withAnimation(Theme.spring) { expanded.toggle() } }
                    if let s = announcement.url, let url = URL(string: s) {
                        Button("Open on ELE") { openExternal(url) }
                    }
                }
                .font(Theme.caption)
                .buttonStyle(.borderless)
            }
        }
    }
}
