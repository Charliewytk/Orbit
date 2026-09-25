import Foundation

/// Where a module stands against the target grade.
public struct ModuleStanding: Codable, Hashable, Sendable {
    public enum Outlook: String, Codable, Sendable {
        /// Target reached even with zero on what's left.
        case secured
        /// Current marks (or no marks yet) are enough if kept up.
        case onTrack
        /// Reachable, but needs better marks than so far.
        case stretch
        /// Would need over 100% on what's left.
        case outOfReach
        /// All marked and below target.
        case missed
    }

    public var moduleCode: String
    public var credits: Int
    public var target: Double
    /// Sum of effective weights of marked / unmarked assessments (percent of module).
    public var markedWeight: Double
    public var remainingWeight: Double
    /// Weighted average of the marks so far.
    public var currentAverage: Double?
    /// Module-mark points already banked (e.g. 65% on a 40% essay = 26).
    public var securedPoints: Double
    /// Average needed across everything unmarked to finish on `target`.
    public var requiredAverageOnRemaining: Double?
    public var outlook: Outlook

    public var totalWeight: Double { markedWeight + remainingWeight }
}

/// The year across modules, weighted by credits.
public struct YearStanding: Codable, Hashable, Sendable {
    public var modules: [ModuleStanding]
    public var target: Double
    /// Credit-weighted average of module averages so far.
    public var currentAverage: Double?
    /// Average needed on all remaining assessed work (credit- and weight-adjusted) to hit the target.
    public var requiredAverageOnRemaining: Double?
}

/// The "get a First" brain: pure logic that turns marks, weights and deadlines
/// into standings, priorities and work plans. Only `narrate` uses the AI.
public struct StudyCoach: Sendable {
    public var prefs: UserPrefs
    public init(prefs: UserPrefs = UserPrefs()) { self.prefs = prefs }

    public var target: Double { prefs.targetGrade }

    // MARK: Weights and standing

    /// Weights to use for maths. Unstated weights on summative work share
    /// whatever the stated ones leave of 100%; totals over 100 are scaled down.
    /// Formative work and quizzes without a stated weight count as 0.
    public func effectiveWeights(_ assessments: [Assessment]) -> [String: Double] {
        var out: [String: Double] = [:]
        let known = assessments.filter { $0.weightPercent > 0 }
        let unknown = assessments.filter {
            $0.weightPercent <= 0 && $0.kind != .quiz && !AssessmentParsing.isFormative($0.title)
        }
        let knownSum = known.reduce(0) { $0 + $1.weightPercent }
        let scale = knownSum > 100 ? 100 / knownSum : 1
        for a in assessments { out[a.id] = a.weightPercent > 0 ? a.weightPercent * scale : 0 }
        if knownSum < 100, !unknown.isEmpty {
            let share = (100 - knownSum) / Double(unknown.count)
            for a in unknown { out[a.id] = share }
        }
        return out
    }

    public func moduleStanding(_ module: Module, assessments all: [Assessment]) -> ModuleStanding {
        let assessments = all.filter { $0.moduleCode == module.code }
        let weights = effectiveWeights(assessments)
        var markedWeight = 0.0, remainingWeight = 0.0, points = 0.0
        for a in assessments {
            let w = weights[a.id] ?? 0
            guard w > 0 else { continue }
            if let m = a.mark { markedWeight += w; points += m * w } else { remainingWeight += w }
        }
        let total = markedWeight + remainingWeight
        let current = markedWeight > 0 ? points / markedWeight : nil
        let secured = total > 0 ? points / total : 0
        var required: Double?
        if remainingWeight > 0 { required = (target * total - points) / remainingWeight }
        else if total == 0 { required = target }

        let outlook: ModuleStanding.Outlook
        switch (required, current) {
        case (nil, let c): outlook = (c ?? 0) >= target ? .secured : .missed
        case (let r?, _) where r <= 0: outlook = .secured
        case (let r?, let c?) where c >= r: outlook = .onTrack
        case (let r?, nil) where r <= target: outlook = .onTrack
        case (let r?, _) where r <= 100: outlook = .stretch
        default: outlook = .outOfReach
        }
        return ModuleStanding(moduleCode: module.code, credits: module.credits, target: target,
                              markedWeight: markedWeight, remainingWeight: remainingWeight, currentAverage: current,
                              securedPoints: secured, requiredAverageOnRemaining: required, outlook: outlook)
    }

    public func yearStanding(modules: [Module], assessments: [Assessment]) -> YearStanding {
        let standings = modules.map { moduleStanding($0, assessments: assessments) }
        var avgNum = 0.0, avgDen = 0.0, securedSum = 0.0, remainingSum = 0.0, credits = 0.0
        for s in standings {
            let c = Double(s.credits)
            credits += c
            if let avg = s.currentAverage { avgNum += avg * c; avgDen += c }
            if s.totalWeight > 0 {
                securedSum += c * s.securedPoints
                remainingSum += c * s.remainingWeight / s.totalWeight
            } else {
                remainingSum += c // nothing known yet: all still to play for
            }
        }
        let required = remainingSum > 0 ? (target * credits - securedSum) / remainingSum : nil
        return YearStanding(modules: standings, target: target, currentAverage: avgDen > 0 ? avgNum / avgDen : nil,
                            requiredAverageOnRemaining: required)
    }

    // MARK: Priorities

    /// How much doing well on this matters now: weight% × module credits / total
    /// credits × urgency. Submitted or marked work scores 0.
    public func impactScore(_ a: Assessment, modules: [Module], assessments: [Assessment] = [], now: Date = Date()) -> Double {
        guard !a.submitted, a.mark == nil else { return 0 }
        let totalCredits = max(1, modules.reduce(0) { $0 + $1.credits })
        let credits = modules.first { $0.code == a.moduleCode }?.credits ?? 15
        var weight = a.weightPercent
        if weight <= 0 {
            let siblings = assessments.filter { $0.moduleCode == a.moduleCode }
            weight = effectiveWeights(siblings.contains { $0.id == a.id } ? siblings : siblings + [a])[a.id] ?? 0
        }
        if weight <= 0 { weight = 5 } // unknown/formative still matters a little
        return weight * Double(credits) / Double(totalCredits) * urgency(due: a.due, now: now)
    }

    /// 2 when due today, 1 a week out, 0.5 three weeks out; 2.5 if overdue.
    public func urgency(due: Date?, now: Date) -> Double {
        guard let due else { return 0.3 }
        let days = due.timeIntervalSince(now) / 86400
        if days < 0 { return 2.5 }
        return min(3, 14 / (days + 7))
    }

    /// Unsubmitted assessments, most impactful first.
    public func rank(_ assessments: [Assessment], modules: [Module], now: Date = Date()) -> [(assessment: Assessment, score: Double)] {
        assessments.filter { !$0.submitted && $0.mark == nil }
            .map { ($0, impactScore($0, modules: modules, assessments: assessments, now: now)) }
            .sorted { $0.1 > $1.1 }
    }

    // MARK: Effort

    /// Total minutes of work an assessment is likely to need.
    /// Essays/reports ≈ 1h per 100 words (4–50h), then scaled by weight
    /// (×0.6 at 0%, ×1.0 at 50%, ×1.4 at 100%).
    public func estimateMinutes(_ a: Assessment) -> Int {
        let weight = a.weightPercent > 0 ? a.weightPercent : 25
        let scale = 0.6 + 0.8 * min(weight, 100) / 100
        let hours: Double
        switch a.kind {
        case .essay, .report:
            let base = a.wordCount.map { min(50, max(4, Double($0) / 100)) } ?? 15
            hours = base * scale
        case .exam: hours = 30 * scale
        case .presentation: hours = 12 * scale
        case .quiz: hours = max(1, 3 * scale)
        case .groupwork: hours = 15 * scale
        case .coursework, .other: hours = 12 * scale
        }
        return max(60, Int((hours * 4).rounded()) * 15)
    }

    // MARK: Planning

    struct Phase {
        var name: String
        var notes: String
        var share: Double
        /// When this phase should be finished, as a fraction of the time available.
        var endFraction: Double
        var energy: Energy
        var maxBlock: Int = 120
    }

    func phases(for a: Assessment, estimate: Int) -> [Phase] {
        switch a.kind {
        case .essay, .report:
            let doc = a.kind == .essay ? "essay" : "report"
            return [
                Phase(name: "Understand brief & gather sources", notes: "Unpick the question and marking criteria; list 8–12 key sources.",
                      share: 0.10, endFraction: 0.12, energy: .medium, maxBlock: 90),
                Phase(name: "Read & take notes", notes: "Read the core sources; note arguments, evidence and quotes with page numbers.",
                      share: 0.30, endFraction: 0.35, energy: .medium, maxBlock: 90),
                Phase(name: "Outline", notes: "Argument, section plan and which evidence goes where.",
                      share: 0.10, endFraction: 0.42, energy: .high, maxBlock: 90),
                Phase(name: "Draft", notes: "Write the full \(doc)\(a.wordCount.map { " (~\($0) words)" } ?? "").",
                      share: 0.30, endFraction: 0.75, energy: .high),
                Phase(name: "Edit & reference check", notes: "Tighten the argument against the criteria; check every citation and the reference list.",
                      share: 0.15, endFraction: 0.92, energy: .medium, maxBlock: 90),
                Phase(name: "Final proofread & submit", notes: "Proofread, check word count and format, then submit on ELE.",
                      share: 0.05, endFraction: 1.0, energy: .low, maxBlock: 60),
            ]
        case .presentation:
            return [
                Phase(name: "Research", notes: "Gather the material and the key message.", share: 0.35, endFraction: 0.4, energy: .medium, maxBlock: 90),
                Phase(name: "Build slides", notes: "Storyline first, then slides and speaker notes.", share: 0.40, endFraction: 0.75, energy: .high),
                Phase(name: "Rehearse", notes: "Run through out loud and time it; trim to fit.", share: 0.25, endFraction: 1.0, energy: .medium, maxBlock: 60),
            ]
        case .quiz:
            return [
                Phase(name: "Review notes", notes: "Go over the lectures and readings it covers.", share: 0.6, endFraction: 0.7, energy: .medium, maxBlock: 60),
                Phase(name: "Practice questions", notes: "Test yourself, then do the quiz.", share: 0.4, endFraction: 1.0, energy: .high, maxBlock: 60),
            ]
        case .exam:
            return examPhases(estimate: estimate)
        case .groupwork, .coursework, .other:
            let first = a.kind == .groupwork ? "Agree plan & roles with group" : "Plan & gather sources"
            return [
                Phase(name: first, notes: "Pin down the brief, criteria and who does what.", share: 0.15, endFraction: 0.15, energy: .medium, maxBlock: 90),
                Phase(name: "Research", notes: "Collect evidence and data.", share: 0.25, endFraction: 0.4, energy: .medium, maxBlock: 90),
                Phase(name: "Produce", notes: "Build the main piece of work.", share: 0.40, endFraction: 0.8, energy: .high),
                Phase(name: "Review & refine", notes: "Check against the marking criteria.", share: 0.15, endFraction: 0.95, energy: .medium, maxBlock: 90),
                Phase(name: "Final check & submit", notes: "Format, proofread and submit on ELE.", share: 0.05, endFraction: 1.0, energy: .low, maxBlock: 60),
            ]
        }
    }

    /// Consolidation, then revision sessions that get closer together nearer
    /// the exam (ends at 0.3 + 0.6·√(k/n)), timed past papers and a final review.
    func examPhases(estimate: Int) -> [Phase] {
        let sessions = min(12, max(3, Int(Double(estimate) * 0.5 / 120)))
        var out = [Phase(name: "Consolidate notes", notes: "Fill gaps in lecture notes and list the topics.",
                         share: 0.15, endFraction: 0.3, energy: .medium, maxBlock: 90)]
        for k in 1...sessions {
            out.append(Phase(name: "Revision session \(k) of \(sessions)",
                             notes: "Active recall on the topics: flashcards, blurting, practice questions.",
                             share: 0.5 / Double(sessions), endFraction: 0.3 + 0.6 * (Double(k) / Double(sessions)).squareRoot(),
                             energy: .high, maxBlock: 90))
        }
        out.append(Phase(name: "Past paper (timed) 1", notes: "Exam conditions, then mark it against the model answers.",
                         share: 0.125, endFraction: 0.8, energy: .high, maxBlock: 180))
        out.append(Phase(name: "Past paper (timed) 2", notes: "Focus on the weakest topics from paper 1.",
                         share: 0.125, endFraction: 0.95, energy: .high, maxBlock: 180))
        out.append(Phase(name: "Final review", notes: "Key points and formulae only. Early night.",
                         share: 0.10, endFraction: 1.0, energy: .medium, maxBlock: 60))
        return out.sorted { $0.endFraction < $1.endFraction }
    }

    /// Breaks an assessment into tasks working back from its deadline.
    /// Minutes add up to `estimateMinutes`, every task finishes before the due
    /// date, and later phases can't start until earlier ones are mostly done.
    /// Exams with `topics` get a spaced revision timetable instead.
    public func planAssessment(_ a: Assessment, now: Date = Date(), topics: [String] = []) -> [OrbitTask] {
        guard !a.submitted, a.mark == nil else { return [] }
        let estimate = estimateMinutes(a)
        if a.kind == .exam, !topics.isEmpty, let due = a.due, due > now {
            return RevisionPlanner(prefs: prefs).plan(exams: [.init(assessment: a, topics: topics)], now: now)
        }
        if let due = a.due, due <= now {
            return [task(a, name: "Finish & submit (overdue)", notes: "This was due \(Self.dayFormatter(prefs).string(from: due)). Check ELE for a late or extension route.",
                         minutes: min(estimate, 180), deadline: nil, earliestStart: nil, energy: .high, maxBlock: 120, priority: .critical)]
        }

        let phases = phases(for: a, estimate: estimate)
        let minutes = Self.split(estimate, shares: phases.map(\.share))
        guard let due = a.due else {
            return zip(phases, minutes).map { p, m in
                task(a, name: p.name, notes: p.notes, minutes: m, deadline: nil, earliestStart: nil,
                     energy: p.energy, maxBlock: p.maxBlock, priority: .normal)
            }
        }

        let window = due.timeIntervalSince(now)
        // Leave slack before the real deadline: an hour for coursework, the evening before for exams.
        let slack: TimeInterval = window > 2 * 86400 ? (a.kind == .exam ? 10 * 3600 : 3600) : 0
        let end = due.addingTimeInterval(-slack)
        let span = end.timeIntervalSince(now)
        let priority = priorityFor(a, daysLeft: window / 86400)

        var out: [OrbitTask] = []
        var previousEnd = 0.0
        for (p, m) in zip(phases, minutes) {
            let startAt = now.addingTimeInterval(span * max(0, previousEnd - 0.05))
            let earliest = previousEnd == 0 ? now : max(now, startOfWorkDay(startAt))
            var deadline = now.addingTimeInterval(span * p.endFraction)
            if p.endFraction < 1 { deadline = snapToCutoff(deadline, after: earliest, limit: end) } else { deadline = end }
            out.append(task(a, name: p.name, notes: p.notes, minutes: m, deadline: deadline,
                            earliestStart: earliest < deadline ? earliest : now, energy: p.energy, maxBlock: p.maxBlock,
                            priority: priority))
            previousEnd = p.endFraction
        }
        return out
    }

    func priorityFor(_ a: Assessment, daysLeft: Double) -> Priority {
        if daysLeft <= 2 { return .critical }
        if a.weightPercent >= 40 || daysLeft <= 7 { return .high }
        if a.weightPercent > 0 && a.weightPercent < 10 { return .low }
        return .normal
    }

    func task(_ a: Assessment, name: String, notes: String, minutes: Int, deadline: Date?, earliestStart: Date?,
              energy: Energy, maxBlock: Int, priority: Priority) -> OrbitTask {
        OrbitTask(title: "\(a.title) · \(name)", notes: notes, estimateMinutes: minutes, deadline: deadline,
                  earliestStart: earliestStart, priority: priority, energy: energy, moduleCode: a.moduleCode,
                  assessmentID: a.id, source: .ele, sourceRef: a.eleURL,
                  minBlockMinutes: min(25, minutes), maxBlockMinutes: max(min(25, minutes), maxBlock))
    }

    /// Splits `total` minutes by `shares` in 5-minute steps; the last part takes the rounding.
    static func split(_ total: Int, shares: [Double]) -> [Int] {
        guard !shares.isEmpty else { return [] }
        let sum = shares.reduce(0, +)
        var out = shares.dropLast().map { max(5, Int((Double(total) * $0 / sum / 5).rounded()) * 5) }
        out.append(max(0, total - out.reduce(0, +)))
        return out
    }

    // MARK: Calendar helpers

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = prefs.timeZone
        return c
    }

    func at(_ minute: MinuteOfDay, on date: Date) -> Date {
        calendar.startOfDay(for: date).addingTimeInterval(TimeInterval(minute * 60))
    }

    func startOfWorkDay(_ date: Date) -> Date { min(date, at(prefs.dayStart, on: date)) }

    /// Moves a deadline to that day's work cut-off (e.g. 21:00) so it reads
    /// naturally, unless that would break the ordering.
    func snapToCutoff(_ date: Date, after earliest: Date, limit: Date) -> Date {
        let snapped = at(prefs.workCutoff, on: date)
        return snapped > earliest && snapped <= limit ? snapped : date
    }

    static func dayFormatter(_ prefs: UserPrefs) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = prefs.timeZone
        f.dateFormat = "EEE d MMM"
        return f
    }
}
