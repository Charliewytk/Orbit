import SwiftUI
import OrbitCore

/// Daily briefing, weekend review and economics news.
struct BriefingView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case today = "Today", review = "Weekly review", news = "News"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .today

    var body: some View {
        VStack(spacing: 0) {
            GlassSegmented(options: Tab.allCases.map { ($0, $0.rawValue) }, selection: $tab)
                .padding(.vertical, Theme.Space.m)
            ScrollView {
                Group {
                    switch tab {
                    case .today: BriefingTodayView()
                    case .review: WeekRecapView()
                    case .news: NewsListView()
                    }
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .orbitBackground()
        .navigationTitle("Briefing")
    }
}

struct BriefingTodayView: View {
    @State private var working = false
    private var companion: CompanionHub { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                Text(companion.state.briefing?.notificationTitle ?? "Your morning briefing").font(Theme.pageTitle)
                Spacer()
                Button(working ? "Working…" : "Refresh") {
                    working = true
                    Task { await companion.makeBriefing(now: Date(), notify: false); working = false }
                }
                .disabled(working)
            }
            if let b = companion.state.briefing {
                BriefingSections(briefing: b)
            } else {
                EmptyState(systemImage: "sunrise", title: "No briefing yet",
                           message: "It arrives every morning at your wake time (set in Settings), or tap Refresh.")
            }
        }
    }
}

struct BriefingSections: View {
    var briefing: DailyBriefing

    var body: some View {
        let cal = briefing.brief.calendar
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if let w = briefing.weather {
                DigestSection(title: "Weather in \(w.place)") {
                    Label(w.line, systemImage: w.symbol).font(Theme.body)
                }
            }
            if let n = briefing.brief.narrative {
                DigestSection(title: "Summary") { Text(n).font(Theme.body) }
            }
            DigestSection(title: "Today") {
                BulletList(items: scheduleLines(cal))
                if briefing.brief.events.isEmpty && briefing.brief.blocks.isEmpty {
                    Text("Nothing scheduled.").font(Theme.body).foregroundStyle(Theme.textSecondary)
                }
            }
            if !briefing.brief.dueSoon.isEmpty || !briefing.groupTasksDue.isEmpty {
                DigestSection(title: "Due") {
                    BulletList(items: dueLines(cal))
                }
            }
            if let exam = briefing.examLine {
                DigestSection(title: "Exam countdown") { Text(exam).font(Theme.body) }
            }
            if !briefing.newOnELE.isEmpty {
                DigestSection(title: "New on ELE and Ed") {
                    BulletList(items: newLines)
                }
            }
            if let e = briefing.keyEmail {
                DigestSection(title: "One email worth reading") {
                    Text(e.subject).font(Theme.body.weight(.semibold))
                    Text("\(e.from) · \(e.summary)").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            DigestSection(title: "Streak") {
                Label("\(briefing.streakDays) day\(briefing.streakDays == 1 ? "" : "s")", systemImage: "flame.fill").font(Theme.body)
            }
            if !briefing.news.isEmpty {
                DigestSection(title: "Economics news") {
                    ForEach(briefing.news) { NewsRow(item: $0) }
                }
            }
            if let recap = briefing.weeklyReview {
                DigestSection(title: "Weekly review") { WeekRecapBody(recap: recap) }
            }
        }
    }
}

extension BriefingSections {
    func scheduleLines(_ cal: DayCalendar) -> [String] {
        var lines: [String] = []
        for e in briefing.brief.events {
            var line = cal.time(e.start) + " " + e.title
            if let place = e.location { line += " · " + place }
            lines.append(line)
        }
        for b in briefing.brief.blocks { lines.append(cal.time(b.start) + " " + b.title + " (study)") }
        return lines
    }

    func dueLines(_ cal: DayCalendar) -> [String] {
        let due: [String] = briefing.brief.dueSoon.map { d in d.title + " · " + cal.shortDay(d.due) }
        return due + briefing.groupTasksDue
    }

    var newLines: [String] {
        briefing.newOnELE.map { item in
            let module: String = item.moduleCode.map { " " + $0 } ?? ""
            return item.source + module + ": " + item.title
        }
    }
}

struct WeekRecapView: View {
    private var companion: CompanionHub { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                Text("Weekly review").font(Theme.pageTitle)
                Spacer()
                Button("Update now") { companion.makeRecap(now: Date(), notify: false) }
            }
            Text("Runs Saturday and Sunday evenings. Weekends count as work days.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            if let recap = companion.state.recap {
                WeekRecapBody(recap: recap)
                    .padding(Theme.Space.l)
                    .orbitGlassCard()
            }
        }
    }
}

struct WeekRecapBody: View {
    var recap: WeekRecap

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(recap.headline).font(Theme.headline)
            Text("\(recap.tasksDone)/\(recap.tasksPlanned) to-dos · \(recap.studyMinutes / 60)h \(recap.studyMinutes % 60)m study · \(recap.activeDays) active days")
                .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            if !recap.marksReturned.isEmpty { labelled("Marks back", recap.marksReturned) }
            if !recap.wins.isEmpty { labelled("Wins", recap.wins) }
            if !recap.slipping.isEmpty { labelled("Slipping", recap.slipping) }
            labelled("Next week", recap.nextWeek.map(\.title))
            labelled("Focus", recap.focusSuggestions)
        }
    }

    private func labelled(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.caption.weight(.bold)).foregroundStyle(Theme.textTertiary)
            BulletList(items: items.isEmpty ? ["Nothing"] : items)
        }
    }
}

struct NewsListView: View {
    @AppStorage(CompanionHub.Keys.newsFullText) private var fullText = false
    private var companion: CompanionHub { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                Text("Today's three").font(Theme.pageTitle)
                Spacer()
                Button(companion.refreshingNews ? "Refreshing…" : "Refresh") {
                    Task { await companion.refreshNews(now: Date()) }
                }
                .disabled(companion.refreshingNews)
            }
            ForEach(companion.state.todaysNews) { item in
                NewsRow(item: item)
                    .padding(Theme.Space.m)
                    .orbitGlassCard()
            }
            Text("From BBC Business, FT, The Economist, Bank of England and ONS feeds, plus FT and Economist newsletters already in your mail.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            DigestSection(title: "Full articles (optional)") {
                Toggle("Fetch full text with my own subscriptions", isOn: $fullText)
                Text("Sign in on the publisher's own page. Orbit keeps only the website cookies on this Mac (like ELE) and never sees your password.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                HStack {
                    ForEach(NewsLogin.Site.allCases) { site in
                        Button("Sign in to \(site.rawValue)…") { NewsLogin.open(site) }
                    }
                }
            }
        }
    }
}

struct NewsRow: View {
    var item: LinkedStory
    @State private var text: String?
    @State private var loading = false
    private var companion: CompanionHub { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ModuleDot(code: item.moduleCode, size: 7)
                Text(item.story.source).font(Theme.caption.weight(.bold)).foregroundStyle(Theme.textTertiary)
                if !item.concepts.isEmpty {
                    Text(item.concepts.joined(separator: " · ")).font(Theme.caption).foregroundStyle(Theme.accent)
                }
            }
            if let raw = item.story.url, let url = URL(string: raw) {
                Link(item.story.title, destination: url).font(Theme.body.weight(.semibold))
            } else {
                Text(item.story.title).font(Theme.body.weight(.semibold))
            }
            if !item.story.summary.isEmpty {
                Text(item.story.summary).font(Theme.body).foregroundStyle(Theme.textSecondary).lineLimit(3)
            }
            Text(item.angle).font(Theme.caption).foregroundStyle(Theme.textPrimary)
            if let text {
                Text(text).font(Theme.body).textSelection(.enabled)
            } else if FeatureSettings.bool(CompanionHub.Keys.newsFullText, default: false) {
                Button(loading ? "Loading…" : "Read full article") {
                    loading = true
                    Task { text = await companion.fullText(for: item); loading = false }
                }
                .buttonStyle(.link)
            }
        }
    }
}
