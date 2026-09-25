import Foundation

/// Traffic-light status for "on track for a First?".
public enum RAGStatus: String, Codable, Comparable, Sendable {
    case green, amber, red
    var rank: Int { switch self { case .green: 0; case .amber: 1; case .red: 2 } }
    public static func < (a: RAGStatus, b: RAGStatus) -> Bool { a.rank < b.rank }
}

public struct LectureCoverage: Codable, Hashable, Sendable {
    public var title: String
    public var start: Date
    public var hasNotes: Bool
    /// Notes exist and include a typed summary (the "key points").
    public var hasTypedSummary: Bool
}

public struct ModuleReview: Codable, Hashable, Sendable {
    public var moduleCode: String
    public var moduleName: String
    public var readingsDone: Int
    public var readingsTotal: Int
    /// Titles of essential readings not yet ticked off.
    public var essentialOutstanding: [String]
    /// Lectures in the review window and whether notes exist for each.
    public var lectures: [LectureCoverage]
    /// Unsubmitted assessments due in the next three weeks.
    public var upcomingDeadlines: [Assessment]
    public var hoursPlanned: Double
    public var hoursNeeded: Double
    public var standing: ModuleStanding
    public var status: RAGStatus
    public var reasons: [String]

    public var lecturesWithNotes: Int { lectures.filter(\.hasNotes).count }
    public var lecturesWithoutNotes: [LectureCoverage] { lectures.filter { !$0.hasNotes } }
}

public struct WeeklyReview: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var periodStart: Date
    public var target: Double
    public var modules: [ModuleReview]
    public var year: YearStanding
    public var status: RAGStatus
    /// The three things that would help most this week.
    public var topActions: [String]

    /// Plain-text version for notifications or when no AI is available.
    public var plainSummary: String {
        var lines = ["On track for a First? \(status.label)"]
        if let avg = year.currentAverage { lines.append(String(format: "Average so far: %.1f%%", avg)) }
        for m in modules {
            lines.append("\(m.moduleCode): \(m.status.label)" + (m.reasons.isEmpty ? "" : " – " + m.reasons.joined(separator: "; ")))
        }
        if !topActions.isEmpty { lines.append("This week:"); lines += topActions.enumerated().map { "\($0.offset + 1). \($0.element)" } }
        return lines.joined(separator: "\n")
    }

    /// A short, supportive and direct summary in UK English from the AI.
    public func narrate(using router: LLMRouter) async throws -> String {
        let system = """
        You are Orbit, a study coach for a University of Exeter undergraduate aiming for a First (70%+). \
        Write in UK English. Be warm but direct, like a good personal tutor: say plainly what's going well, \
        what's slipping and exactly what to do next. No waffle, no emojis, no invented facts; only use the data given. \
        Keep it under 180 words: one short paragraph on overall status, then the top actions as a numbered list.
        """
        let data = (try? String(decoding: HTTPClient.encoder.encode(NarrationInput(self)), as: UTF8.self)) ?? plainSummary
        return try await router.complete(system: system, user: "This week's review data:\n\(data)", purpose: .reasoning)
    }

    /// A slimmed-down view for the prompt (small models do better with less).
    struct NarrationInput: Encodable {
        struct M: Encodable {
            let module: String, status: String, reasons: [String], averageSoFar: Double?, neededOnRemaining: Double?
            let essentialReadingsOutstanding: Int, lecturesWithoutNotes: Int, hoursPlanned: Double, hoursNeeded: Double
            let deadlines: [String]
        }
        let overall: String, target: Double, yearAverage: Double?, neededOnRemaining: Double?, modules: [M], topActions: [String]

        init(_ r: WeeklyReview) {
            let f = StudyCoach.dayFormatter(UserPrefs())
            overall = r.status.rawValue; target = r.target; topActions = r.topActions
            yearAverage = r.year.currentAverage.map(Self.round); neededOnRemaining = r.year.requiredAverageOnRemaining.map(Self.round)
            modules = r.modules.map { m in
                M(module: "\(m.moduleCode) \(m.moduleName)", status: m.status.rawValue, reasons: m.reasons,
                  averageSoFar: m.standing.currentAverage.map(Self.round),
                  neededOnRemaining: m.standing.requiredAverageOnRemaining.map(Self.round),
                  essentialReadingsOutstanding: m.essentialOutstanding.count, lecturesWithoutNotes: m.lecturesWithoutNotes.count,
                  hoursPlanned: Self.round(m.hoursPlanned), hoursNeeded: Self.round(m.hoursNeeded),
                  deadlines: m.upcomingDeadlines.map { "\($0.title) (\(Int($0.weightPercent))%) due \($0.due.map(f.string(from:)) ?? "?")" })
            }
        }
        static func round(_ d: Double) -> Double { (d * 10).rounded() / 10 }
    }
}

extension RAGStatus {
    public var label: String {
        switch self { case .green: "Yes, on track"; case .amber: "Nearly: a few things need attention"; case .red: "At risk" }
    }
}

extension StudyCoach {
    /// Is this calendar event a lecture? Titles with "lecture", or timetable
    /// entries that aren't seminars, tutorials, workshops or labs.
    public static func isLecture(_ e: CalendarEvent) -> Bool {
        let t = e.title.lowercased()
        if t.contains("lecture") { return true }
        guard e.source == .timetable else { return false }
        return !["seminar", "tutorial", "workshop", "lab", "practical", "office hour", "exam"].contains { t.contains($0) }
    }

    /// Builds the weekly "on track for a First?" review.
    /// - Parameters:
    ///   - lectures: timetable events; lectures in the past `days` are checked for notes.
    ///   - notes: lecture-note metadata (segments may be empty; only module/date/typed-ness are used).
    ///   - tasks, blocks: current plan, to compare hours planned vs needed over the next 3 weeks.
    public func weeklyReview(modules: [Module], assessments: [Assessment], readings: [ReadingItem],
                             notes: [LectureNote], lectures: [CalendarEvent], tasks: [OrbitTask] = [],
                             blocks: [ScheduledBlock] = [], now: Date = Date(), days: Int = 7) -> WeeklyReview {
        let periodStart = now.addingTimeInterval(-Double(days) * 86400)
        let horizon = now.addingTimeInterval(21 * 86400)
        let year = yearStanding(modules: modules, assessments: assessments)
        let fmt = Self.dayFormatter(prefs)
        var candidates: [(score: Double, text: String)] = []
        var reviews: [ModuleReview] = []

        for module in modules {
            let code = module.code
            let standing = year.modules.first { $0.moduleCode == code } ?? moduleStanding(module, assessments: assessments)

            // Readings
            let modReadings = readings.filter { $0.moduleCode == code }
            let essentialOutstanding = modReadings.filter { $0.essential && !$0.done }
                .sorted { ($0.week ?? 99) < ($1.week ?? 99) }

            // Lectures vs notes (same day, same module; each note used once)
            let modNotes = notes.filter { noteModule($0) == code }
            var usedNotes = Set<String>()
            let modLectures = lectures.filter {
                Self.isLecture($0) && $0.start >= periodStart && $0.start <= now
                    && (ModuleCode.find(in: $0.title) == code || $0.title.localizedCaseInsensitiveContains(code))
            }.sorted { $0.start < $1.start }
            let coverage: [LectureCoverage] = modLectures.map { lecture in
                let match = modNotes.first { n in
                    !usedNotes.contains(n.id) && calendar.isDate(n.created, inSameDayAs: lecture.start)
                } ?? modNotes.first { n in
                    // Allow notes written up within two days afterwards.
                    !usedNotes.contains(n.id) && n.created >= lecture.start.addingTimeInterval(-3600)
                        && n.created <= lecture.end.addingTimeInterval(2 * 86400)
                }
                if let match { usedNotes.insert(match.id) }
                return LectureCoverage(title: lecture.title, start: lecture.start, hasNotes: match != nil,
                                       hasTypedSummary: match?.hasTyped ?? false)
            }

            // Deadlines and workload
            let upcoming = assessments.filter {
                $0.moduleCode == code && !$0.submitted && $0.mark == nil && ($0.due.map { $0 >= now && $0 <= horizon } ?? false)
            }.sorted { $0.due! < $1.due! }
            let openTasks = tasks.filter { $0.moduleCode == code && !$0.isDone && ($0.deadline.map { $0 <= horizon } ?? false) }
            var neededMinutes = openTasks.reduce(0) { $0 + $1.remainingMinutes }
            let unplanned = upcoming.filter { a in !tasks.contains { $0.assessmentID == a.id } }
            neededMinutes += unplanned.reduce(0) { $0 + estimateMinutes($1) }
            let plannedMinutes = blocks.filter { $0.moduleCode == code && $0.start >= now && $0.start <= horizon }
                .reduce(0) { $0 + $1.minutes }
            let hoursNeeded = Double(neededMinutes) / 60, hoursPlanned = Double(plannedMinutes) / 60

            // Status and reasons
            var status = RAGStatus.green
            var reasons: [String] = []
            func flag(_ s: RAGStatus, _ reason: String) { status = max(status, s); reasons.append(reason) }

            if let req = standing.requiredAverageOnRemaining, standing.remainingWeight > 0 {
                if req > 100 { flag(.red, "A First is out of reach on the remaining work; aim to maximise the mark") }
                else if req > 80 { flag(.red, String(format: "Needs %.0f%% average on what's left", req)) }
                else if req > target + 0.5, standing.markedWeight > 0 { flag(.amber, String(format: "Needs %.0f%% on what's left (above your average so far)", req)) }
            } else if standing.outlook == .missed {
                flag(.amber, "All marks are in and below \(Int(target))%")
            }
            if let avg = standing.currentAverage, avg < target - 10 { flag(.red, String(format: "Average so far is %.0f%%", avg)) }
            else if let avg = standing.currentAverage, avg < target { flag(.amber, String(format: "Average so far is %.0f%%", avg)) }

            let soonest = upcoming.first?.due
            if hoursNeeded > 0.5 {
                let ratio = hoursPlanned / hoursNeeded
                let dueThisWeek = soonest.map { $0.timeIntervalSince(now) < 7 * 86400 } ?? false
                if ratio < 0.5 && dueThisWeek { flag(.red, String(format: "Only %.0fh planned of %.0fh needed before a deadline this week", hoursPlanned, hoursNeeded)) }
                else if ratio < 0.9 { flag(.amber, String(format: "%.0fh planned of %.0fh needed over the next 3 weeks", hoursPlanned, hoursNeeded)) }
            }
            if !unplanned.isEmpty { flag(.amber, "No plan yet for \(unplanned.map(\.title).joined(separator: ", "))") }
            if essentialOutstanding.count > 3 { flag(.amber, "\(essentialOutstanding.count) essential readings outstanding") }
            let missing = coverage.filter { !$0.hasNotes }
            if missing.count >= 2 { flag(.amber, "\(missing.count) lectures this week without notes") }
            if assessments.contains(where: { $0.moduleCode == code && !$0.submitted && $0.mark == nil && ($0.due.map { $0 < now } ?? false) }) {
                flag(.red, "Something is overdue")
            }

            reviews.append(ModuleReview(
                moduleCode: code, moduleName: module.name, readingsDone: modReadings.filter(\.done).count,
                readingsTotal: modReadings.count, essentialOutstanding: essentialOutstanding.map(\.title), lectures: coverage,
                upcomingDeadlines: upcoming, hoursPlanned: hoursPlanned, hoursNeeded: hoursNeeded, standing: standing,
                status: status, reasons: reasons))

            // Candidate actions, scored so the most valuable rise to the top.
            let creditShare = Double(module.credits) / Double(max(1, modules.reduce(0) { $0 + $1.credits }))
            for a in upcoming {
                let impact = impactScore(a, modules: modules, assessments: assessments, now: now)
                let due = a.due.map(fmt.string(from:)) ?? ""
                let weight = a.weightPercent > 0 ? ", \(Int(a.weightPercent))%" : ""
                if unplanned.contains(where: { $0.id == a.id }) {
                    candidates.append((impact * 1.5 + 2, "Plan and start \(a.title) (\(code)\(weight), due \(due))"))
                } else if let next = openTasks.filter({ $0.assessmentID == a.id }).min(by: { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }) {
                    candidates.append((impact, "\(next.title) (\(code), due \(due))"))
                }
            }
            if hoursNeeded - hoursPlanned >= 2 {
                candidates.append(((hoursNeeded - hoursPlanned) * creditShare * 2,
                                   String(format: "Block out %.0f more hours for %@", (hoursNeeded - hoursPlanned).rounded(.up), code)))
            }
            for l in missing.prefix(2) {
                candidates.append((3 * creditShare * 8, "Write up notes for the \(code) lecture on \(fmt.string(from: l.start))"))
            }
            let untyped = coverage.filter { $0.hasNotes && !$0.hasTypedSummary }
            if let l = untyped.first {
                candidates.append((1.5 * creditShare * 8, "Type up key points from the \(code) lecture on \(fmt.string(from: l.start))"))
            }
            for r in essentialOutstanding.prefix(2) {
                candidates.append((2 * creditShare * 8, "Read \"\(r.title)\" (\(code), essential)"))
            }
        }

        let overall = reviews.map(\.status).max() ?? .green
        var seen = Set<String>()
        let actions = candidates.sorted { $0.score > $1.score }.map(\.text).filter { seen.insert($0).inserted }.prefix(3)
        return WeeklyReview(generatedAt: now, periodStart: periodStart, target: target, modules: reviews, year: year,
                            status: overall, topActions: Array(actions))
    }

    func noteModule(_ n: LectureNote) -> String? {
        n.moduleCode ?? ModuleCode.find(in: n.title) ?? ModuleCode.find(in: n.section) ?? ModuleCode.find(in: n.notebook)
    }
}
