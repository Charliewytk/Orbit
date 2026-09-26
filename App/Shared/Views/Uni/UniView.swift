import SwiftUI
import SwiftData
import OrbitCore

/// Uni: a module column on the left, the module page (or the year overview) on the right.
struct UniView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \StoredModule.id) private var modules: [StoredModule]
    @Query private var allAssessments: [StoredAssessment]
    @Query(sort: \StoredReading.title) private var readings: [StoredReading]
    @Query private var allAnnouncements: [StoredAnnouncement]
    @Query(sort: \StoredBrief.createdAt, order: .reverse) private var briefs: [StoredBrief]
    @Query private var tasks: [StoredTask]
    #if os(macOS)
    @State private var showEd = false
    #endif

    private var assessments: [StoredAssessment] {
        allAssessments.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    private var announcements: [StoredAnnouncement] {
        allAnnouncements.sorted { ($0.posted ?? .distantPast) > ($1.posted ?? .distantPast) }
    }

    var body: some View {
        let sortedAssessments = assessments
        let year = StudyCoach(prefs: app.prefs).yearStanding(modules: modules.map(\.value),
                                                             assessments: sortedAssessments.map(\.value))
        let selection = Binding<String?>(get: { app.selectedModuleID }, set: { app.selectedModuleID = $0 })
        TwoPane(selection: selection, listWidth: 240) {
            #if os(macOS)
            ModuleColumn(modules: modules, assessments: sortedAssessments, selection: selection)
            #else
            YearOverview(modules: modules, year: year, assessments: sortedAssessments,
                         weekly: briefs.first { $0.kind == .weekly }, announcements: announcements)
            #endif
        } detail: { id in
            if let id, let module = modules.first(where: { $0.id == id }) {
                ModulePage(module: module,
                           standing: year.modules.first { $0.moduleCode == module.id },
                           assessments: sortedAssessments.filter { $0.moduleCode == module.id },
                           readings: readings.filter { $0.moduleCode == module.id },
                           announcements: announcements.filter { $0.moduleCode == module.id },
                           tasks: tasks)
                    .id(module.id)
            } else {
                YearOverview(modules: modules, year: year, assessments: sortedAssessments,
                             weekly: briefs.first { $0.kind == .weekly }, announcements: announcements)
            }
        }
        .navigationTitle("Uni")
        #if os(macOS)
        .toolbar {
            ToolbarItem {
                Button { showEd = true } label: { Label("Ed Discussion", systemImage: "bubble.left.and.bubble.right") }
                    .help("Ed Discussion: new threads, staff posts and replies")
            }
        }
        .sheet(isPresented: $showEd) {
            NavigationStack {
                EdView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showEd = false } } }
            }
            .frame(minWidth: 640, minHeight: 560)
        }
        #endif
    }
}

// MARK: - Module column

private struct ModuleColumn: View {
    @Environment(AppModel.self) private var app
    var modules: [StoredModule]
    var assessments: [StoredAssessment]
    @Binding var selection: String?

    var body: some View {
        let now = Date()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                row(title: "Overview", selected: selection == nil) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 16)
                }
                .onTapGesture { selection = nil }

                Text("Modules")
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.top, Theme.Space.l)
                    .padding(.bottom, Theme.Space.xs)

                if modules.isEmpty {
                    Text("Sign in to ELE in Settings to bring in your modules.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, Theme.Space.s)
                }
                ForEach(modules) { m in
                    let next = assessments.first { $0.moduleCode == m.id && !$0.submitted && $0.mark == nil && ($0.due ?? .distantPast) > now }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: Theme.Space.s) {
                            IconTile(symbol: ModuleLabel.symbol(m.id), color: Theme.moduleColor(m.id), size: 22)
                            Text(ModuleLabel.title(m.id))
                                .font(Theme.body.weight(.medium))
                                .lineLimit(1)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer(minLength: 0)
                            if let due = next?.due {
                                Text(Fmt.shortDue(due, app.calendar, now: now))
                                    .font(Theme.caption.monospacedDigit())
                                    .foregroundStyle(due < now.addingTimeInterval(3 * 86400) ? Theme.danger : Theme.textTertiary)
                            }
                        }
                        if !m.name.isEmpty {
                            Text(m.name)
                                .font(Theme.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .padding(.leading, 16 + Theme.Space.s)
                        }
                    }
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, 6)
                    .hoverRow(selected: selection == m.id)
                    .onTapGesture { selection = m.id }
                }
            }
            .padding(Theme.Space.s)
        }
    }

    private func row<Icon: View>(title: String, selected: Bool, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: Theme.Space.s) {
            icon()
            Text(title).font(Theme.body).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 30)
        .hoverRow(selected: selected)
    }
}

// MARK: - Year overview

struct YearOverview: View {
    @Environment(AppModel.self) private var app
    var modules: [StoredModule]
    var year: YearStanding
    var assessments: [StoredAssessment]
    var weekly: StoredBrief?
    var announcements: [StoredAnnouncement]

    var body: some View {
        let target = app.prefs.targetGrade
        let upcoming = assessments.filter { !$0.submitted && $0.mark == nil }
        Page {
            PageHeader(title: "Uni", subtitle: headerLine(target: target))

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ThinProgressBar(value: (year.currentAverage ?? 0) / 100, target: target / 100,
                                color: standingColor(year.currentAverage, target: target))
                    .frame(maxWidth: 320)
                Text(requiredText(year.requiredAverageOnRemaining))
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
            }

            if modules.isEmpty {
                EmptyState(title: "No modules yet.",
                           message: "Sign in to ELE in Settings and your modules, weeks, readings and assessments appear here.")
                    .padding(.top, Theme.Space.l)
            } else {
                PageSection(title: "Modules", count: modules.count) {
                    VStack(spacing: 0) {
                        ForEach(modules) { m in
                            ModuleStandingRow(module: m, standing: year.modules.first { $0.moduleCode == m.id }, target: target)
                                .onTapGesture { app.selectedModuleID = m.id }
                        }
                    }
                }
            }

            if !upcoming.isEmpty {
                PageSection(title: "Upcoming assessments", count: upcoming.count) {
                    VStack(spacing: 0) {
                        ForEach(upcoming.prefix(12)) { a in
                            AssessmentLine(assessment: a)
                                .onTapGesture { app.selectedModuleID = a.moduleCode }
                        }
                    }
                }
            }

            if let weekly {
                PageSection(title: "On track?") {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        if let review = weekly.weekly {
                            Text(review.status.label)
                                .font(Theme.caption.weight(.medium))
                                .foregroundStyle(review.status.color)
                        }
                        Text(weekly.narrative ?? weekly.plainText)
                            .font(Theme.body)
                            .foregroundStyle(Theme.textPrimary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Text("Weekly review · \(weekly.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }

            if !announcements.isEmpty {
                PageSection(title: "Announcements") {
                    VStack(spacing: 0) {
                        ForEach(announcements.prefix(8)) { AnnouncementRow(announcement: $0) }
                    }
                }
            }
        }
    }

    private func headerLine(target: Double) -> String {
        var parts = ["Aiming for \(Int(target))%"]
        if let avg = year.currentAverage { parts.append("average so far \(Int(avg.rounded()))%") }
        return parts.joined(separator: " · ")
    }

    private func requiredText(_ required: Double?) -> String {
        guard let required else { return "Marks show here as they come back." }
        if required <= 0 { return "You've already banked enough for your target." }
        return String(format: "Average %.0f%% on what's left to get there.", required)
    }
}

func standingColor(_ average: Double?, target: Double) -> Color {
    guard let average else { return Theme.textTertiary }
    return average >= target ? Theme.success : average >= target - 5 ? Theme.warning : Theme.danger
}

private struct ModuleStandingRow: View {
    var module: StoredModule
    var standing: ModuleStanding?
    var target: Double

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            IconTile(symbol: ModuleLabel.symbol(module.id), color: Theme.moduleColor(module.id), size: 24)
            Text(ModuleLabel.title(module.id)).font(Theme.body.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: Theme.Space.m)
            ThinProgressBar(value: (standing?.currentAverage ?? 0) / 100, target: target / 100,
                            color: standingColor(standing?.currentAverage, target: target))
                .frame(width: 80)
            Text(standing?.currentAverage.map { "\(Int($0.rounded()))%" } ?? "–")
                .font(Theme.caption.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, alignment: .trailing)
            Text(standing?.outlook.label ?? "No marks")
                .font(Theme.caption)
                .foregroundStyle(standing.map { $0.outlook.rag == .green ? Theme.textSecondary : $0.outlook.rag.color } ?? Theme.textTertiary)
                .frame(width: 80, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 32)
        .hoverRow()
    }
}

/// One assessment as a compact row: title, module, weight, due.
struct AssessmentLine: View {
    @Environment(AppModel.self) private var app
    var assessment: StoredAssessment
    var showModule: Bool = true

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: assessment.kind == .exam ? "pencil.and.list.clipboard" : "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 16)
            Text(assessment.title).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
            if showModule { ModuleTag(code: assessment.moduleCode) }
            Spacer(minLength: Theme.Space.s)
            if assessment.weightPercent > 0 {
                Text("\(Int(assessment.weightPercent))%")
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            if let due = assessment.due {
                DueText(date: due, calendar: app.calendar, style: .short)
            } else {
                Text("TBA").font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 32)
        .hoverRow()
    }
}

struct AnnouncementRow: View {
    var announcement: StoredAnnouncement
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Text(announcement.subject)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(expanded ? nil : 1)
                ModuleTag(code: announcement.moduleCode)
                Spacer(minLength: Theme.Space.s)
                if let d = announcement.posted {
                    Text(d.formatted(.dateTime.day().month(.abbreviated)))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if expanded {
                Text(announcement.message)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let s = announcement.url, let url = URL(string: s) {
                    Button("Open on ELE") { openExternal(url) }.buttonStyle(.orbitLink)
                }
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 7)
        .hoverRow()
        .onTapGesture { withAnimation(Motion.snappy) { expanded.toggle() } }
    }
}

// MARK: - Module page

struct ModulePage: View {
    @Environment(AppModel.self) private var app
    var module: StoredModule
    var standing: ModuleStanding?
    var assessments: [StoredAssessment]
    var readings: [StoredReading]
    var announcements: [StoredAnnouncement]
    var tasks: [StoredTask]

    enum Tab: String, Hashable { case overview, weeks, assessments, readings }
    @State private var tab: Tab = .overview
    @State private var replan: StoredAssessment? = nil

    private var courseURL: URL? {
        module.eleCourseID.flatMap { URL(string: "https://ele.exeter.ac.uk/course/view.php?id=\($0)") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, horizontalPadding)
            SegmentedHeader(options: [(Tab.overview, "Overview"), (Tab.weeks, "Weeks"),
                                      (Tab.assessments, "Assessments"), (Tab.readings, "Readings")],
                            selection: $tab)
                .padding(.horizontal, horizontalPadding - 10)
                .padding(.bottom, Theme.Space.s)
            Hairline()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .orbitBackground()
        .confirmationDialog("Replace the current plan?", isPresented: Binding(get: { replan != nil }, set: { if !$0 { replan = nil } }),
                            presenting: replan) { a in
            Button("Re-plan from now") { plan(a) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Unfinished steps for this assessment are replaced with a fresh plan.")
        }
    }

    private var horizontalPadding: CGFloat {
        #if os(macOS)
        return Theme.Space.xxxl
        #else
        return Theme.Space.l
        #endif
    }

    private var header: some View {
        let target = app.prefs.targetGrade
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                ModuleDot(code: module.id)
                Text("\(module.id) · \(module.credits) credits")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if let courseURL {
                    Button("Open on ELE") { openExternal(courseURL) }
                        .buttonStyle(.quiet)
                }
            }
            Text(ModuleNames.knownTitle(for: module.id) ?? (module.name.isEmpty ? module.id : module.name))
                .font(Theme.pageTitle)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.m) {
                ThinProgressBar(value: (standing?.currentAverage ?? 0) / 100, target: target / 100,
                                color: standingColor(standing?.currentAverage, target: target))
                    .frame(width: 200)
                Text(standingLine(target: target))
                    .font(Theme.body.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, Theme.Space.s)
        }
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.l)
    }

    private func standingLine(target: Double) -> String {
        guard let standing else { return "No marks yet · target \(Int(target))%" }
        var parts: [String] = []
        if let avg = standing.currentAverage { parts.append("\(Int(avg.rounded()))% so far") } else { parts.append("No marks yet") }
        parts.append("target \(Int(target))%")
        parts.append(standing.outlook.label)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview: overview
        case .weeks: weeks
        case .assessments: assessmentsTab
        case .readings: readingsTab
        }
    }

    // MARK: Overview

    private var overview: some View {
        let now = Date()
        let current = currentWeek(now)
        let next = assessments.first { !$0.submitted && $0.mark == nil && ($0.due ?? .distantFuture) > now }
        return Page {
            if let standing, let required = standing.requiredAverageOnRemaining, standing.remainingWeight > 0 {
                Text(required <= 0 ? "Target secured for this module."
                     : String(format: "You need about %.0f%% on the remaining %.0f%% of the module.", required, standing.remainingWeight))
                    .font(Theme.large)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, Theme.Space.xl)
            }
            if let next {
                PageSection(title: "Next deadline") { AssessmentLine(assessment: next, showModule: false) }
            }
            if let current {
                PageSection(title: "This week") {
                    WeekOutline(week: current, module: module, readings: readings, isCurrent: true, startExpanded: true)
                }
            }
            if !announcements.isEmpty {
                PageSection(title: "Announcements") {
                    VStack(spacing: 0) {
                        ForEach(announcements.prefix(5)) { AnnouncementRow(announcement: $0) }
                    }
                }
            }
            if next == nil && current == nil && announcements.isEmpty {
                EmptyState(title: "Nothing to show yet.", message: "Weeks and deadlines appear after the next ELE sync.")
                    .padding(.top, Theme.Space.xl)
            }
        }
    }

    private func currentWeek(_ now: Date) -> ELEModuleWeek? {
        module.weeks.first { w in
            guard let start = w.weekCommencing else { return false }
            return start <= now && now < start.addingTimeInterval(7 * 86400)
        }
    }

    // MARK: Weeks

    private var weeks: some View {
        let list = module.weeks
        let current = currentWeek(Date())
        return Page {
            if list.isEmpty {
                EmptyState(title: "No weeks yet.", message: "They appear after the next ELE sync.")
                    .padding(.top, Theme.Space.xl)
            }
            VStack(spacing: 0) {
                ForEach(list) { w in
                    WeekOutline(week: w, module: module, readings: readings,
                                isCurrent: w.week == current?.week, startExpanded: w.week == current?.week)
                }
            }
            .padding(.top, Theme.Space.l)
        }
    }

    // MARK: Assessments

    @ViewBuilder
    private var assessmentsTab: some View {
        if assessments.isEmpty {
            Page {
                EmptyState(title: "No assessments listed.", message: "They appear after the next ELE sync.")
                    .padding(.top, Theme.Space.xl)
            }
        } else {
            #if os(macOS)
            Table(assessments) {
                TableColumn("Assessment") { a in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.title).lineLimit(1)
                        if let d = a.details, !d.isEmpty {
                            Text(d).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                    }
                    .help(a.details ?? a.title)
                }
                .width(min: 180, ideal: 260)
                TableColumn("Weight") { a in
                    Text(a.weightPercent > 0 ? "\(Int(a.weightPercent))%" : "–").monospacedDigit()
                }
                .width(56)
                TableColumn("Due") { a in
                    if let due = a.due {
                        DueText(date: due, calendar: app.calendar, style: .short)
                    } else {
                        Text("TBA").foregroundStyle(Theme.textTertiary)
                    }
                }
                .width(84)
                TableColumn("Words") { a in
                    Text(a.wordCount.map { $0.formatted() } ?? "–").monospacedDigit().foregroundStyle(Theme.textSecondary)
                }
                .width(60)
                TableColumn("Status") { a in
                    Text(status(a)).foregroundStyle(Theme.textSecondary)
                }
                .width(min: 90, ideal: 110)
                TableColumn("") { a in
                    HStack(spacing: Theme.Space.xs) {
                        if !a.submitted && a.mark == nil {
                            Button(planTitle(a)) { requestPlan(a) }
                                .buttonStyle(.orbitLink)
                        }
                        if let s = a.eleURL, let url = URL(string: s) {
                            Button { openExternal(url) } label: { Image(systemName: "arrow.up.right") }
                                .buttonStyle(.borderless)
                                .help("Open on ELE")
                        }
                    }
                }
                .width(min: 100, ideal: 120)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            #else
            Page {
                VStack(spacing: 0) {
                    ForEach(assessments) { a in
                        AssessmentLine(assessment: a, showModule: false)
                            .contextMenu { Button(planTitle(a)) { requestPlan(a) } }
                    }
                }
                .padding(.top, Theme.Space.l)
            }
            #endif
        }
    }

    private func status(_ a: StoredAssessment) -> String {
        if let mark = a.mark { return "\(Int(mark.rounded()))%" }
        if a.submitted { return "Submitted" }
        let planned = tasks.filter { $0.assessmentID == a.id }
        if !planned.isEmpty {
            return "\(planned.filter(\.isDone).count) of \(planned.count) steps"
        }
        return "Not planned"
    }

    private func planTitle(_ a: StoredAssessment) -> String {
        if a.kind == .exam { return "Revision plan" }
        return tasks.contains { $0.assessmentID == a.id } ? "Re-plan" : "Plan"
    }

    private func requestPlan(_ a: StoredAssessment) {
        if tasks.contains(where: { $0.assessmentID == a.id && !$0.isDone }) { replan = a } else { plan(a) }
    }

    private func plan(_ a: StoredAssessment) {
        withAnimation(Motion.smooth) { _ = app.planAssessment(a) }
    }

    // MARK: Readings

    private var readingsTab: some View {
        let groups = Dictionary(grouping: readings) { $0.week ?? 0 }.sorted { $0.key < $1.key }
        return Page {
            if readings.isEmpty {
                EmptyState(title: "No reading list yet.", message: "Readings from ELE appear here.")
                    .padding(.top, Theme.Space.xl)
            }
            ForEach(groups, id: \.key) { week, items in
                PageSection(title: week == 0 ? "Unscheduled" : "Week \(week)", count: items.count) {
                    VStack(spacing: 0) {
                        ForEach(items.sorted { ($0.essential ? 0 : 1, $0.title) < ($1.essential ? 0 : 1, $1.title) }) { r in
                            ReadingRow(reading: r)
                        }
                    }
                }
            }
        }
    }
}

struct ReadingRow: View {
    @Environment(AppModel.self) private var app
    var reading: StoredReading

    var body: some View {
        HStack(spacing: 10) {
            CircleCheckbox(isOn: reading.done) {
                withAnimation(Motion.snappy) { app.toggle(reading) }
            }
            Text(reading.title)
                .font(Theme.body)
                .foregroundStyle(reading.done ? Theme.textTertiary : Theme.textPrimary)
                .strikethrough(reading.done, color: Theme.textTertiary)
                .lineLimit(2)
            if reading.essential {
                Text("Essential").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Space.s)
            if let s = reading.url, let url = URL(string: s) {
                Button { openExternal(url) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.textTertiary)
                    .help("Open")
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(minHeight: 32)
        .hoverRow()
    }
}

/// One teaching week as an outline: header line, then lectures, reading, tutorials.
struct WeekOutline: View {
    @Environment(AppModel.self) private var app
    var week: ELEModuleWeek
    var module: StoredModule
    var readings: [StoredReading]
    var isCurrent: Bool = false
    var startExpanded: Bool = false
    @State private var expanded: Bool? = nil

    var body: some View {
        let open = expanded ?? startExpanded
        let weekReadings = readings.filter { $0.week == week.week }
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.snappy) { expanded = !open }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12)
                    Text("Week \(week.week)")
                        .font(Theme.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let d = week.weekCommencing {
                        Text("w/c \(d.formatted(.dateTime.day().month(.abbreviated)))")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if !week.title.isEmpty && week.title != "Week \(week.week)" {
                        Text(week.title)
                            .font(Theme.body)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Theme.Space.s)
                    if isCurrent {
                        Text("This week").font(Theme.caption.weight(.medium)).foregroundStyle(Theme.accent)
                    }
                    Text(counts(weekReadings))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, Theme.Space.s)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverRow()

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(week.lectures.enumerated()), id: \.offset) { _, link in
                        linkLine(link, symbol: "doc.richtext")
                    }
                    if !weekReadings.isEmpty {
                        ForEach(weekReadings) { ReadingRow(reading: $0) }
                    } else {
                        ForEach(week.readings, id: \.self) { r in line(r, symbol: "book") }
                    }
                    ForEach(Array(week.readingGuides.enumerated()), id: \.offset) { _, link in
                        linkLine(link, symbol: "list.bullet.rectangle")
                    }
                    ForEach(week.tutorials, id: \.self) { t in line("Tutorial: \(t)", symbol: "person.2") }
                    ForEach(Array(week.other.enumerated()), id: \.offset) { _, link in linkLine(link, symbol: "link") }
                    #if os(macOS)
                    AcademicWeekExtras(moduleCode: module.id, week: week.week)
                    #endif
                    if week.isEmpty {
                        Text("Nothing posted yet.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, Theme.Space.s)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.leading, 20)
                .padding(.bottom, Theme.Space.s)
                .transition(.opacity)
            }
        }
    }

    private func counts(_ weekReadings: [StoredReading]) -> String {
        var parts: [String] = []
        if !week.lectures.isEmpty { parts.append("\(week.lectures.count) slides") }
        let r = weekReadings.isEmpty ? week.readings.count : weekReadings.count
        if r > 0 { parts.append("\(r) reading\(r == 1 ? "" : "s")") }
        if !week.tutorials.isEmpty { parts.append("tutorial") }
        return parts.joined(separator: " · ")
    }

    private func line(_ text: String, symbol: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.textTertiary).frame(width: 16)
            Text(text).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(minHeight: 28)
    }

    @ViewBuilder
    private func linkLine(_ link: ELEWebLink, symbol: String) -> some View {
        if let s = link.url, let url = URL(string: s) {
            Button { openExternal(url) } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.textTertiary).frame(width: 16)
                    Text(link.name).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.s)
                .frame(minHeight: 28)
                .hoverRow()
            }
            .buttonStyle(.plain)
        } else {
            line(link.name, symbol: symbol)
        }
    }
}
