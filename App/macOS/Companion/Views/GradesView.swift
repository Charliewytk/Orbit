import SwiftUI
import OrbitCore

/// Grade tracker + First predictor, and the six-week exam countdown.
struct GradesView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case grades = "Grades", exams = "Exam countdown"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .grades

    var body: some View {
        VStack(spacing: 0) {
            GlassSegmented(options: Tab.allCases.map { ($0, $0.rawValue) }, selection: $tab)
                .padding(.vertical, Theme.Space.m)
            Group {
                switch tab {
                case .grades: GradeBookView()
                case .exams: ExamCountdownView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .orbitBackground()
        .navigationTitle("Grades")
    }
}

struct GradeBookView: View {
    private var companion: CompanionHub { .shared }

    var body: some View {
        let p = companion.projection
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                YearSummaryCard(projection: p)
                if p.modules.isEmpty {
                    EmptyState(systemImage: "graduationcap", title: "No modules yet",
                               message: "Modules and assessment weightings come from ELE after the next sync. You can edit any weight or mark here.")
                }
                ForEach(p.modules) { m in
                    ModuleGradeCard(result: m, targets: p.targets)
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
    }
}

struct YearSummaryCard: View {
    var projection: GradeProjection

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.xl) {
            stat("Average so far", projection.yearAverage.map { String(format: "%.1f", $0) } ?? "–")
            stat("Projected year", projection.yearProjected.map { String(format: "%.1f", $0) } ?? "–")
            stat("Outlook", projection.classification)
            ForEach(projection.targets, id: \.self) { t in
                stat("Needed for \(Int(t))", projection.yearRequired[t].map { String(format: "%.0f", max(0, $0)) } ?? "–")
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.l)
        .orbitGlassCard()
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.caption.weight(.bold)).foregroundStyle(Theme.textTertiary)
            Text(value).font(Theme.number(24)).foregroundStyle(Theme.textPrimary)
        }
    }
}

struct ModuleGradeCard: View {
    var result: GradeProjection.ModuleResult
    var targets: [Double]
    @State private var newTitle = ""
    @State private var newWeight = ""
    private var companion: CompanionHub { .shared }

    private var items: [GradeBook.Item] {
        companion.state.gradeBook.modules.first { $0.code == result.code }?.items ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            header
            if result.weightWarning {
                Text("Weights add up to \(Int(result.markedWeight + result.remainingWeight))%. Check them against the module handbook.")
                    .font(Theme.caption).foregroundStyle(Theme.warning)
            }
            ForEach(items) { item in
                GradeItemRow(moduleCode: result.code, item: item, needed: needed(for: item))
            }
            addRow
        }
        .padding(Theme.Space.l)
        .orbitGlassCard()
    }

    private var header: some View {
        HStack {
            ModuleDot(code: result.code, size: 9)
            Text("\(result.code) · \(result.name)").font(Theme.headline).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(result.average.map { String(format: "avg %.1f", $0) } ?? "no marks yet")
                .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            Text(result.projected.map { String(format: "→ %.1f", $0) } ?? "")
                .font(Theme.caption.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.accent)
        }
    }

    private func needed(for item: GradeBook.Item) -> String {
        guard item.mark == nil else { return "" }
        return targets.map { t in
            guard let r = result.requiredByTarget[t] else { return "" }
            if r <= 0 { return "\(Int(t)): secured" }
            return r > 100 ? "\(Int(t)): out of reach" : "\(Int(t)): need \(Int(r.rounded(.up)))"
        }.joined(separator: " · ")
    }

    private var addRow: some View {
        HStack {
            TextField("Add assessment", text: $newTitle).textFieldStyle(.roundedBorder)
            TextField("Weight %", text: $newWeight).textFieldStyle(.roundedBorder).frame(width: 80)
            Button("Add") {
                companion.addGradeItem(module: result.code, title: newTitle, weight: Double(newWeight) ?? 0)
                newTitle = ""; newWeight = ""
            }
            .disabled(newTitle.isEmpty)
        }
        .font(Theme.caption)
    }
}

struct GradeItemRow: View {
    var moduleCode: String
    var item: GradeBook.Item
    var needed: String
    @State private var weight = ""
    @State private var mark = ""
    private var companion: CompanionHub { .shared }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: item.isExam ? "pencil.and.list.clipboard" : "doc.text")
                .foregroundStyle(Theme.textTertiary)
            Text(item.title).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer()
            Text(needed).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            TextField("%", text: $weight)
                .onSubmit(commitWeight)
                .textFieldStyle(.roundedBorder).frame(width: 54)
                .help("Weight (% of module)")
            TextField("mark", text: $mark)
                .onSubmit(commitMark)
                .textFieldStyle(.roundedBorder).frame(width: 60)
                .help("Mark out of 100")
            Button(role: .destructive) {
                companion.removeGradeItem(module: moduleCode, item: item.id)
            } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
        }
        .onAppear(perform: load)
        .onChange(of: item) { load() }
    }

    private func load() {
        weight = String(format: "%g", item.weight)
        mark = item.mark.map { String(format: "%g", $0) } ?? ""
    }

    private func commitWeight() {
        guard let w = Double(weight) else { return }
        companion.editGrade(module: moduleCode, item: item.id, weight: w, mark: nil)
    }

    private func commitMark() {
        let value: Double? = mark.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Double(mark)
        companion.editGrade(module: moduleCode, item: item.id, weight: nil, mark: .some(value))
    }
}

struct ExamCountdownView: View {
    private var companion: CompanionHub { .shared }

    var body: some View {
        let now = Date()
        let plan = companion.examPlan(now: now)
        let cal = companion.cal
        let days = Array(Set(plan.sessions.map { cal.startOfDay($0.day) })).sorted().prefix(14)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ForEach(plan.exams) { e in
                    ExamCountdownRow(exam: e, calendar: cal)
                }
                if plan.exams.isEmpty {
                    EmptyState(systemImage: "calendar.badge.clock", title: "No exams on the calendar",
                               message: "Exams from ELE appear here. From six weeks out, Orbit plans past papers and weak topics day by day.")
                } else if !plan.isActive {
                    Text("The revision plan starts six weeks before your first exam.")
                        .font(Theme.body).foregroundStyle(Theme.textSecondary)
                }
                ForEach(days, id: \.self) { day in
                    ExamDayCard(day: day, sessions: plan.sessions(on: day, calendar: cal), calendar: cal)
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }
}

struct ExamCountdownRow: View {
    var exam: ExamRevisionPlan.ExamEntry
    var calendar: DayCalendar

    var body: some View {
        HStack {
            ModuleDot(code: exam.moduleCode, size: 9)
            Text("\(exam.moduleCode) · \(exam.title)").font(Theme.headline)
            Spacer()
            Text(calendar.shortDay(exam.date)).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Text("\(exam.daysLeft) days").font(Theme.number(16)).foregroundStyle(exam.inWindow ? Theme.warning : Theme.textSecondary)
        }
        .padding(Theme.Space.m)
        .orbitGlassCard()
    }
}

struct ExamDayCard: View {
    var day: Date
    var sessions: [ExamRevisionPlan.Session]
    var calendar: DayCalendar

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(calendar.format(day, "EEEE d MMMM")).font(Theme.headline)
            ForEach(sessions) { s in
                HStack {
                    Image(systemName: symbol(s.kind)).foregroundStyle(Theme.moduleColor(s.moduleCode))
                    Text(s.title).font(Theme.body).lineLimit(1)
                    Spacer()
                    Text("\(s.minutes) min").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(Theme.Space.m)
        .orbitGlassCard()
    }

    private func symbol(_ kind: ExamRevisionPlan.Session.Kind) -> String {
        switch kind {
        case .pastPaper: "doc.on.clipboard"
        case .weakTopic: "exclamationmark.triangle"
        case .review: "arrow.triangle.2.circlepath"
        case .mock: "stopwatch"
        }
    }
}
