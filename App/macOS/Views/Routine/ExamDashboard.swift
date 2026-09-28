import SwiftUI
import SwiftData
import OrbitCore

/// Home in exam season: big countdowns, revision progress with today's target ring,
/// past papers (timed focus sessions), and a weak-topics checklist.
struct ExamDashboard: View {
    var width: CGFloat
    var now: Date
    private var exam: ExamService { FeatureHub.shared.exam }

    var body: some View {
        let countdowns = exam.countdowns(now: now)
        let progress = exam.progress(now: now)
        let wide = width > 900
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) {
                IconTile(symbol: "graduationcap.fill", color: Theme.danger, size: 26)
                Text("Exam mode").font(Theme.sectionTitle).foregroundStyle(Theme.textPrimary)
                Tag(text: countdowns.isEmpty ? "On" : "\(countdowns.count) exam\(countdowns.count == 1 ? "" : "s") ahead", color: Theme.danger)
                Spacer()
                Button("Turn off") {
                    FeatureHub.shared.routine.toggleExamMode(assessments: exam.assessments())
                }
                .orbitGlassButton()
            }
            countdownRow(countdowns)
            if wide {
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    RevisionCard(progress: progress).frame(maxWidth: .infinity)
                    PastPapersCard().frame(maxWidth: .infinity)
                    WeakTopicsCard().frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                RevisionCard(progress: progress)
                PastPapersCard()
                WeakTopicsCard()
            }
        }
    }

    @ViewBuilder
    private func countdownRow(_ list: [ExamMode.Countdown]) -> some View {
        if list.isEmpty {
            Text("No exam dates on ELE yet. Orbit will count down as soon as they appear.")
                .font(Theme.body).foregroundStyle(Theme.textSecondary)
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .orbitGlassCard()
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Space.l) {
                    ForEach(list) { c in CountdownTile(countdown: c, now: now) }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct CountdownTile: View {
    var countdown: ExamMode.Countdown
    var now: Date

    var body: some View {
        let cal = DayCalendar(timeZone: FeatureHub.shared.prefs.timeZone)
        let color = Theme.moduleColor(countdown.moduleCode)
        let soon = countdown.hours < 48
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ModuleTag(code: countdown.moduleCode)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(soon ? "\(countdown.hours)" : "\(countdown.days)")
                    .font(Theme.number(54))
                    .foregroundStyle(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                    .contentTransition(.numericText())
                Text(soon ? (countdown.hours == 1 ? "hour" : "hours") : (countdown.days == 1 ? "day" : "days"))
                    .font(Theme.headline).foregroundStyle(Theme.textSecondary)
            }
            Text(countdown.title).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(2)
            Text(cal.format(countdown.start, "EEE d MMM · HH:mm") + (countdown.weightPercent > 0 ? " · \(Int(countdown.weightPercent))%" : ""))
                .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Space.l)
        .frame(width: 220, alignment: .leading)
        .orbitGlassCard(tint: color.opacity(0.35))
        .hoverLift()
    }
}

struct RevisionCard: View {
    var progress: ExamService.Progress
    private var exam: ExamService { FeatureHub.shared.exam }

    var body: some View {
        HomeCard(title: "Revision plan", symbol: "chart.bar.doc.horizontal.fill", color: Theme.violet, destination: .tasks) {
            HStack(spacing: Theme.Space.l) {
                ZStack {
                    RingArc(progress: progress.todayFraction, start: Theme.ringStudy, end: Theme.ringStudyEnd, lineWidth: 12)
                        .frame(width: 96, height: 96)
                    VStack(spacing: 0) {
                        Text("\(progress.todayMinutes)").font(Theme.number(24)).foregroundStyle(Theme.textPrimary)
                        Text("of \(progress.todayTarget) min").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Today's revision target").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    ThinProgressBar(value: progress.fraction, color: Theme.violet)
                    Text("\(progress.doneTasks) of \(progress.totalTasks) sessions · \(Fmt.duration(progress.doneMinutes)) of \(Fmt.duration(progress.totalMinutes))")
                        .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    if progress.totalTasks == 0 {
                        Button("Plan revision") { exam.planRevision(force: false) }
                            .orbitGlassProminentButton(Theme.violet)
                    }
                }
            }
        }
    }
}

struct PastPapersCard: View {
    private var exam: ExamService { FeatureHub.shared.exam }

    var body: some View {
        let papers = exam.pastPapers()
        HomeCard(title: "Past papers", symbol: "doc.text.fill", color: Theme.indigo, destination: .uni) {
            if papers.isEmpty {
                Text("No past papers found on ELE yet.").font(Theme.body).foregroundStyle(Theme.textTertiary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(papers.prefix(6)) { p in
                    HStack(spacing: Theme.Space.s) {
                        CircleCheckbox(isOn: exam.isDone(p), size: 16) { exam.toggleDone(p) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.title).font(Theme.body.weight(.medium)).lineLimit(1)
                                .strikethrough(exam.isDone(p))
                            Text([p.moduleCode.map { ModuleLabel.title($0) }, Fmt.duration(p.minutes)].compactMap { $0 }.joined(separator: " · "))
                                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: 0)
                        Button("Start timed paper") { exam.startTimedPaper(p) }
                            .orbitGlassButton()
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

struct WeakTopicsCard: View {
    private var exam: ExamService { FeatureHub.shared.exam }
    @State private var newTopic = ""

    var body: some View {
        let topics = exam.weakTopics()
        let shaky = FeatureHub.shared.routine.state.shakyTopics
        HomeCard(title: "Weak topics", symbol: "exclamationmark.triangle.fill", color: Theme.warning, destination: .review) {
            VStack(alignment: .leading, spacing: 6) {
                if topics.isEmpty {
                    Text("Nothing flagged. Mark a topic shaky below.").font(Theme.body).foregroundStyle(Theme.textTertiary)
                }
                ForEach(topics.prefix(8), id: \.topic) { t in
                    HStack(spacing: Theme.Space.s) {
                        CircleCheckbox(isOn: false, color: Theme.warning, size: 16) {
                            // Ticking a topic clears "shaky" (it's been revised).
                            if shaky.contains(t.topic) { exam.toggleShaky(t.topic) }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.topic).font(Theme.body.weight(.medium)).lineLimit(1)
                            Text(([t.moduleCode.map { ModuleLabel.title($0) }].compactMap { $0 } + t.reasons).joined(separator: " · "))
                                .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                    }
                }
                HStack {
                    TextField("Mark a topic shaky…", text: $newTopic)
                        .textFieldStyle(.plain)
                        .onSubmit(add)
                    if !newTopic.isEmpty { Button("Add", action: add).orbitGlassButton() }
                }
                .padding(.top, 4)
            }
        }
    }

    private func add() {
        let t = newTopic.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        exam.toggleShaky(t)
        newTopic = ""
    }
}
