import Foundation

/// Something worth telling the student about.
public struct CareersEvent: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case opened, closingSoon, newListing, stageChanged, expectedSoon, dateAnnounced
    }

    /// Stable key, so each event is sent once ("opened|<id>", "closing7|<id>").
    public var id: String
    public var kind: Kind
    public var opportunityID: String
    public var title: String
    public var body: String
    public var date: Date
    /// Worth a notification (watched programmes only).
    public var notify: Bool

    public init(id: String, kind: Kind, opportunityID: String, title: String, body: String, date: Date, notify: Bool) {
        self.id = id; self.kind = kind; self.opportunityID = opportunityID; self.title = title; self.body = body
        self.date = date; self.notify = notify
    }
}

/// A to-do Orbit adds when a watched programme opens.
public struct ApplyTaskPlan: Hashable, Sendable {
    public var opportunityID: String
    public var title: String
    public var notes: String
    public var deadline: Date
    public var estimateMinutes: Int
    /// `sourceRef` for the task (one task per programme).
    public var sourceRef: String { "careers:\(opportunityID)" }
}

/// Diffs Trackr snapshots into events, predicts openings and plans apply tasks. Pure.
public struct CareersTracker: Sendable {
    public var preferences: CareersPreferences
    public var now: Date

    public init(preferences: CareersPreferences, now: Date = Date()) {
        self.preferences = preferences; self.now = now
    }

    // MARK: Diff

    /// Events between the last snapshot and this one. `sent` holds event ids
    /// already delivered. With no previous snapshot (first run) only time-based
    /// events (closing soon, expected soon) are produced, so the first fetch
    /// doesn't announce 100 "new" programmes.
    public func events(old: [Opportunity]?, new: [Opportunity], sent: Set<String> = []) -> [CareersEvent] {
        let before = Dictionary((old ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [CareersEvent] = []
        func add(_ e: CareersEvent) { if !sent.contains(e.id) && !out.contains(where: { $0.id == e.id }) { out.append(e) } }

        for o in new {
            let watched = preferences.isWatched(o)
            let previous = before[o.id]
            if old != nil {
                if o.isOpen(now: now) && !(previous?.isOpen(now: now) ?? false) {
                    add(CareersEvent(id: "opened|\(o.id)", kind: .opened, opportunityID: o.id,
                                     title: "\(o.company) is open", body: openedBody(o), date: now, notify: watched))
                } else if previous == nil {
                    add(CareersEvent(id: "new|\(o.id)", kind: .newListing, opportunityID: o.id,
                                     title: "New on Trackr: \(o.company)", body: o.programme + listingDetail(o),
                                     date: now, notify: watched && preferences.isStarred(o)))
                } else if let previous, previous.openingDate == nil, let opening = o.openingDate, !o.isOpen(now: now) {
                    add(CareersEvent(id: "date|\(o.id)|\(CareersDay.short(opening))", kind: .dateAnnounced, opportunityID: o.id,
                                     title: "\(o.company) opens \(CareersDay.short(opening))", body: o.programme,
                                     date: now, notify: watched))
                }
                if let previous, let stage = o.latestStage, stage != previous.latestStage {
                    add(CareersEvent(id: "stage|\(o.id)|\(stage)", kind: .stageChanged, opportunityID: o.id,
                                     title: "\(o.company): \(stage)", body: "\(o.programme) has moved to \(stage).",
                                     date: now, notify: watched && preferences.isStarred(o)))
                }
            } else if o.isOpen(now: now), let opening = o.openingDate, CareersDay.days(from: opening, to: now) <= 1 {
                // First run, but it opened today: still news.
                add(CareersEvent(id: "opened|\(o.id)", kind: .opened, opportunityID: o.id,
                                 title: "\(o.company) is open", body: openedBody(o), date: now, notify: watched))
            }

            // Closing soon (7 days, then 2 days).
            if o.isOpen(now: now), let days = o.daysToClose(now: now), days >= 0 {
                for threshold in [2, 7] where days <= threshold {
                    add(CareersEvent(id: "closing\(threshold)|\(o.id)", kind: .closingSoon, opportunityID: o.id,
                                     title: days == 0 ? "\(o.company) closes today" : "\(o.company) closes in \(days) day\(days == 1 ? "" : "s")",
                                     body: "\(o.programme) closes \(CareersDay.short(o.closingDate!)).",
                                     date: now, notify: watched))
                    break
                }
            }

            // A week before last year's opening date comes round.
            if !o.isOpen(now: now), !o.isClosed(now: now), let expected = o.predictedOpening {
                let days = CareersDay.days(from: now, to: expected)
                if days >= 0 && days <= 7 {
                    add(CareersEvent(id: "expected|\(o.id)|\(CareersDay.short(expected))", kind: .expectedSoon, opportunityID: o.id,
                                     title: "\(o.company) usually opens around \(CareersDay.short(expected))",
                                     body: "\(o.programme) opened on \(CareersDay.short(o.lastYearOpening!)) last year. Get your CV and answers ready.",
                                     date: now, notify: watched))
                }
            }
        }
        return out
    }

    private func openedBody(_ o: Opportunity) -> String {
        var parts = [o.programme]
        if let c = o.closingDate { parts.append("closes \(CareersDay.short(c))") } else if o.rolling { parts.append("rolling — apply early") }
        if let t = o.testPrep ?? o.process.first { parts.append(t) }
        return parts.joined(separator: " · ")
    }

    private func listingDetail(_ o: Opportunity) -> String {
        if let opening = o.openingDate { return " · opens \(CareersDay.short(opening))" }
        if let p = o.predictedOpening { return " · expected ~\(CareersDay.short(p))" }
        return ""
    }

    // MARK: Lists

    public func openNow(_ all: [Opportunity], watchedOnly: Bool = false) -> [Opportunity] {
        all.filter { $0.isOpen(now: now) && (!watchedOnly || preferences.isWatched($0)) }
            .sorted { ($0.closingDate ?? .distantFuture, $0.company) < ($1.closingDate ?? .distantFuture, $1.company) }
    }

    /// When a programme should open: its announced date, or last year's plus a year.
    public func expectedOpening(_ o: Opportunity) -> (date: Date, predicted: Bool)? {
        if let d = o.openingDate { return (d, false) }
        if let p = o.predictedOpening { return (p, true) }
        return nil
    }

    /// Not open yet, sorted by (expected) opening. Predictions already in the past
    /// ("overdue") come first; they could open any day.
    public func openingSoon(_ all: [Opportunity], withinDays days: Int = 60, watchedOnly: Bool = false) -> [Opportunity] {
        let limit = now.addingTimeInterval(Double(days) * 86400)
        return all.filter { o in
            guard !o.isOpen(now: now), !o.isClosed(now: now), !watchedOnly || preferences.isWatched(o),
                  let e = expectedOpening(o) else { return false }
            return e.date <= limit && (e.predicted || CareersDay.days(from: now, to: e.date) > 0)
        }
        .sorted { (expectedOpening($0)?.date ?? .distantFuture) < (expectedOpening($1)?.date ?? .distantFuture) }
    }

    public func search(_ all: [Opportunity], query: String) -> [Opportunity] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return all }
        return all.filter { o in
            let hay = [o.company, o.programme, o.category.label, o.eligibility ?? "", o.testPrep ?? "", o.notes ?? "",
                       o.sectors.joined(separator: " "), o.process.joined(separator: " ")].joined(separator: " ").lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    // MARK: Apply tasks

    /// The "Apply: …" to-do for a programme that just opened. Deadline is the
    /// closing date; rolling programmes get two weeks (or the closing date if sooner).
    public func applyTask(for o: Opportunity) -> ApplyTaskPlan {
        let twoWeeks = now.addingTimeInterval(14 * 86400)
        var deadline: Date
        if let closing = o.closingDate {
            deadline = CareersDay.endOfDay(closing)
            if o.rolling { deadline = min(deadline, twoWeeks) }
        } else {
            deadline = twoWeeks
        }
        if deadline < now { deadline = now.addingTimeInterval(86400) }
        var notes: [String] = []
        notes.append("\(o.category.label) · \(o.company) — \(o.programme)")
        if let c = o.closingDate { notes.append("Closes \(CareersDay.short(c))\(o.rolling ? " (rolling: apply early, places go before the deadline)" : "").") }
        else if o.rolling { notes.append("Rolling applications: apply in the next two weeks.") }
        if !o.process.isEmpty { notes.append("Process: " + o.process.joined(separator: " → ") + ".") }
        if let test = CareersPrep.testName(o) { notes.append("Test: \(test). " + CareersPrep.suggestion(for: test)) }
        if o.process.contains(where: { $0.lowercased().contains("hirevue") }) && CareersPrep.testName(o)?.lowercased() != "hirevue" {
            notes.append(CareersPrep.suggestion(for: "HireVue"))
        }
        if let n = o.notes { notes.append("Trackr notes: \(n)") }
        if let a = o.acceptanceRate { notes.append("Acceptance: \(a).") }
        if let url = o.url { notes.append("Apply: \(url)") }
        return ApplyTaskPlan(opportunityID: o.id, title: "Apply: \(o.company) \(o.programme)",
                             notes: notes.joined(separator: "\n"), deadline: deadline,
                             estimateMinutes: o.process.isEmpty ? 60 : 90)
    }

    // MARK: Text for the assistant

    public func line(_ o: Opportunity) -> String {
        var s = "\(o.company) — \(o.programme) [\(o.category.label)]"
        if let e = o.eligibility { s += " (\(e) only)" }
        if o.isOpen(now: now) {
            s += ": OPEN"
            if let c = o.closingDate { s += ", closes \(CareersDay.short(c))" }
            if o.rolling { s += ", rolling" }
        } else if o.isClosed(now: now) {
            s += ": closed \(CareersDay.short(o.closingDate!))"
        } else if let e = expectedOpening(o) {
            s += e.predicted ? ": expected ~\(CareersDay.short(e.date)) (last year \(CareersDay.short(o.lastYearOpening!)))"
                : ": opens \(CareersDay.short(e.date))"
        }
        if let t = o.testPrep { s += "; test: \(t)" }
        if !o.process.isEmpty { s += "; process: \(o.process.joined(separator: " → "))" }
        if let a = o.acceptanceRate { s += "; acceptance \(a)" }
        if preferences.isStarred(o) { s += " ★" }
        return s
    }

    public func text(_ list: [Opportunity], empty: String, limit: Int = 25) -> String {
        guard !list.isEmpty else { return empty }
        var lines = list.prefix(limit).map(line)
        if list.count > limit { lines.append("…and \(list.count - limit) more.") }
        return lines.joined(separator: "\n")
    }
}

/// Test platforms and how to prepare.
public enum CareersPrep {
    /// The online test to prepare for, from the test-prep column or the process.
    public static func testName(_ o: Opportunity) -> String? {
        if let t = o.testPrep { return t }
        if o.process.contains(where: { $0.lowercased().contains("hirevue") }) { return "HireVue" }
        if o.process.contains(where: { $0.lowercased().contains("online test") }) { return "Online test" }
        return nil
    }

    public static func suggestion(for test: String) -> String {
        let t = test.lowercased()
        if t.contains("cut-e") || t.contains("cute") || t.contains("aon") {
            return "Aon/cut-e: short, speeded numerical (scales), verbal and inductive tests; do a couple of timed practice sets and get used to the calculator-in-browser."
        }
        if t.contains("shl") { return "SHL: numerical and verbal reasoning (Verify). Practise timed sets; read the question before the data." }
        if t.contains("pymetrics") { return "Pymetrics: 12 neuroscience games, no right answers. Do it rested, somewhere quiet; no revision needed." }
        if t.contains("hirevue") { return "HireVue: recorded video answers (about 30s to think, 2–3 min to answer). Practise STAR stories and 'why this firm/division'." }
        if t.contains("cappfinity") { return "Cappfinity: strengths-based situational and numbers questions, often untimed. Answer as yourself; read the firm's values." }
        if t.contains("suited") { return "Suited: a personality/behavioural assessment. Be consistent and honest; no prep beyond knowing the firm." }
        if t.contains("talent-q") || t.contains("talent q") { return "Talent Q: adaptive numerical/verbal tests with a timer per question. Practise quick percentage and ratio maths." }
        if t.contains("mckinsey") || t.contains("solve") { return "McKinsey Solve: ecosystem and redrock games. Watch walkthroughs and try the practice game." }
        if t.contains("plum") { return "Plum: puzzle and preference questions, around 25 minutes. Take it calmly; nothing to memorise." }
        if t.contains("wonderlic") { return "Wonderlic: 50 mixed questions in 12 minutes. Practise speed, skip what you can't do." }
        if t.contains("ccat") { return "CCAT: 50 questions in 15 minutes (maths, verbal, spatial). Practise under time." }
        if t.contains("predictive index") { return "Predictive Index: a quick cognitive test plus a behavioural survey. Practise speed maths." }
        if t.contains("prep") { return "The firm publishes its own prep: work through it before you start." }
        if t.contains("online test") { return "An online test comes first: do a timed numerical and verbal practice set." }
        return "Look up the test format and do one timed practice run first."
    }
}

// MARK: - Client

/// Fetches Trackr's public programme lists.
public struct TrackrClient: Sendable {
    public var http: HTTPClient

    public init(http: HTTPClient = HTTPClient(timeout: 30)) { self.http = http }

    public func fetch(category: OpportunityCategory, season: Int, region: String = "UK") async throws -> [Opportunity] {
        let url = TrackrParser.apiURL(category: category, season: season, region: region)
        let data = try await http.data("GET", url, headers: [
            "Accept": "application/json",
            "Origin": "https://app.the-trackr.com",
            "Referer": category.pageURL.absoluteString,
        ])
        return try TrackrParser.parseAPI(data, category: category)
    }
}
