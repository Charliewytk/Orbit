import Foundation

/// A piece of homework (problem sheet, tutorial questions, set reading counted as
/// homework) and whether it's done. The academic side supplies these; tasks can
/// stand in for them.
public struct HomeworkStatus: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var moduleCode: String
    public var title: String
    public var due: Date?
    public var done: Bool

    public init(id: String, moduleCode: String, title: String, due: Date? = nil, done: Bool = false) {
        self.id = id; self.moduleCode = moduleCode; self.title = title; self.due = due; self.done = done
    }

    public func isOverdue(at now: Date) -> Bool { !done && (due.map { $0 < now } ?? false) }
}

/// One line of the weekly report, with how much it matters.
public struct ReportReason: Codable, Hashable, Sendable {
    public var text: String
    public var status: RAGStatus
    public init(_ text: String, _ status: RAGStatus) { self.text = text; self.status = status }
}

public struct AssessmentProgress: Codable, Hashable, Sendable {
    public var assessmentID: String
    public var title: String
    public var due: Date?
    public var daysLeft: Int?
    public var weightPercent: Double
    /// Fraction of planned work done (nil if nothing is planned yet).
    public var progress: Double?
    public var status: RAGStatus
}

/// Per-module metrics for "on track for a First?".
public struct ModuleOnTrack: Codable, Hashable, Sendable, Identifiable {
    public var id: String { moduleCode }
    public var moduleCode: String
    public var moduleName: String
    public var readingsDone: Int
    public var readingsAssigned: Int
    public var lecturesHeld: Int
    public var lecturesWithNotes: Int
    public var homeworkDone: Int
    public var homeworkTotal: Int
    public var homeworkOverdue: [String]
    public var assessments: [AssessmentProgress]
    public var currentAverage: Double?
    public var requiredOnRemaining: Double?
    public var outlook: ModuleStanding.Outlook
    public var minutesPlanned: Int
    public var minutesDone: Int
    public var status: RAGStatus
    public var reasons: [ReportReason]
    public var wins: [String]
}

/// The weekly "on track for a First" report. Deterministic metrics; the AI only
/// writes a short narration on top.
public struct OnTrackReport: Codable, Hashable, Sendable, Identifiable {
    public var id: String { weekKey }
    /// "2026-W40" style key (the Sunday the report was made on).
    public var weekKey: String
    public var generatedAt: Date
    public var periodStart: Date
    public var periodEnd: Date
    public var target: Double
    public var modules: [ModuleOnTrack]
    public var overall: RAGStatus
    public var yearAverage: Double?
    public var requiredOnRemaining: Double?
    public var minutesPlanned: Int
    public var minutesDone: Int
    public var topActions: [String]
    public var narrative: String?

    public var headline: String {
        switch overall {
        case .green: "On track for a First"
        case .amber: "Nearly on track: a few things need attention"
        case .red: "At risk: act on the points below this week"
        }
    }

    public var plainText: String {
        var lines = [headline]
        if let avg = yearAverage { lines.append(String(format: "Average so far: %.1f%% (target %.0f%%)", avg, target)) }
        lines.append("Study this week: \(Self.hours(minutesDone)) of \(Self.hours(minutesPlanned)) planned")
        for m in modules {
            lines.append("\(m.moduleCode) [\(m.status.rawValue)]: " + (m.reasons.isEmpty ? "all good" : m.reasons.map(\.text).joined(separator: "; ")))
        }
        if !topActions.isEmpty { lines.append("Next week:"); lines += topActions.enumerated().map { "\($0.offset + 1). \($0.element)" } }
        return lines.joined(separator: "\n")
    }

    static func hours(_ minutes: Int) -> String {
        let h = Double(minutes) / 60
        return h == h.rounded() ? "\(Int(h))h" : String(format: "%.1fh", h)
    }

    /// Short narration in UK English from the metrics only.
    public func narrate(using router: LLMRouter, purpose: LLMPurpose = .reasoning) async throws -> String {
        let system = """
        You are Orbit, a personal tutor for a first-year economics student at Exeter aiming for a First (70%+).
        From the weekly report below, write 3–4 sentences in UK English: overall verdict, the biggest risk, and what to do first.
        Be direct and kind. Only use the facts given; no emoji, no lists, no headings.
        """
        return try await router.complete(LLMRequest(messages: [.system(system), .user(plainText)], purpose: purpose,
                                                    temperature: 0.3, maxTokens: 300))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct OnTrackReportBuilder: Sendable {
    public var prefs: UserPrefs
    public var academic: AcademicCalendar
    public init(prefs: UserPrefs = UserPrefs(), academic: AcademicCalendar = .exeter) {
        self.prefs = prefs; self.academic = academic
    }

    public struct Inputs: Sendable {
        public var modules: [Module]
        public var assessments: [Assessment]
        public var readings: [ReadingItem]
        public var notes: [LectureNote]
        /// Timetabled lectures (all modules).
        public var lectures: [CalendarEvent]
        public var homework: [HomeworkStatus]
        public var tasks: [OrbitTask]
        public var blocks: [ScheduledBlock]
        public var focusLog: [FocusLogEntry]
        public var completedBlockIDs: Set<UUID>

        public init(modules: [Module], assessments: [Assessment] = [], readings: [ReadingItem] = [], notes: [LectureNote] = [],
                    lectures: [CalendarEvent] = [], homework: [HomeworkStatus] = [], tasks: [OrbitTask] = [],
                    blocks: [ScheduledBlock] = [], focusLog: [FocusLogEntry] = [], completedBlockIDs: Set<UUID> = []) {
            self.modules = modules; self.assessments = assessments; self.readings = readings; self.notes = notes
            self.lectures = lectures; self.homework = homework; self.tasks = tasks; self.blocks = blocks
            self.focusLog = focusLog; self.completedBlockIDs = completedBlockIDs
        }
    }

    var cal: DayCalendar { DayCalendar(timeZone: prefs.timeZone) }

    public func build(_ input: Inputs, now: Date) -> OnTrackReport {
        let periodEnd = now
        let periodStart = now.addingTimeInterval(-7 * 86400)
        let coach = StudyCoach(prefs: prefs)
        let year = coach.yearStanding(modules: input.modules, assessments: input.assessments)
        let currentWeek = academic.week(for: now)
        let termStart = currentWeek.flatMap { academic.termStart($0.term) } ?? now.addingTimeInterval(-28 * 86400)
        // If there's no focus log at all, fall back to completed blocks for "done".
        let useFocus = !input.focusLog.isEmpty

        var modules: [ModuleOnTrack] = []
        for module in input.modules.sorted(by: { $0.code < $1.code }) {
            let code = module.code
            var reasons: [ReportReason] = []
            var wins: [String] = []

            // Readings assigned so far (weeks up to now; undated essentials count).
            let modReadings = input.readings.filter { $0.moduleCode == code }
            let assigned = modReadings.filter { r in
                if let w = r.week, let cw = currentWeek?.week { return w <= cw }
                return r.week == nil ? r.essential : false
            }
            let readingsDone = assigned.filter(\.done).count
            if !assigned.isEmpty {
                let frac = Double(readingsDone) / Double(assigned.count)
                let text = "\(readingsDone) of \(assigned.count) readings done"
                if frac < 0.4 { reasons.append(.init(text, assigned.count - readingsDone >= 4 ? .red : .amber)) }
                else if frac < 0.75 { reasons.append(.init(text, .amber)) }
                else { wins.append(text) }
            }

            // Lectures this term with notes (a note for the module that day or up to 3 days after).
            let held = input.lectures.filter { e in
                !e.isAllDay && e.end <= now && e.start >= termStart
                    && (NoteMetadataDetector.moduleCode(in: [e.title, e.notes])?.caseInsensitiveCompare(code) == .orderedSame)
            }
            var seenDays = Set<Date>()
            var heldDays: [Date] = []
            for e in held.sorted(by: { $0.start < $1.start }) where seenDays.insert(cal.startOfDay(e.start)).inserted {
                heldDays.append(cal.startOfDay(e.start))
            }
            let withNotes = heldDays.filter { day in
                let limit = cal.addingDays(3, to: day)
                return input.notes.contains { n in
                    n.moduleCode?.caseInsensitiveCompare(code) == .orderedSame && n.created >= day && n.created < limit
                }
            }.count
            if !heldDays.isEmpty {
                let missing = heldDays.count - withNotes
                let text = "\(withNotes) of \(heldDays.count) lectures have notes"
                if missing >= 3 { reasons.append(.init(text, .red)) }
                else if missing >= 1 { reasons.append(.init(text, .amber)) }
                else { wins.append(text) }
            }

            // Homework.
            let hw = input.homework.filter { $0.moduleCode == code && ($0.due.map { $0 <= now.addingTimeInterval(7 * 86400) } ?? true) }
            let hwDone = hw.filter(\.done).count
            let overdue = hw.filter { $0.isOverdue(at: now) }.map(\.title)
            if !overdue.isEmpty {
                reasons.append(.init("\(overdue.count) homework overdue (\(overdue.prefix(2).joined(separator: ", ")))",
                                     overdue.count >= 2 ? .red : .amber))
            } else if !hw.isEmpty, hwDone == hw.count {
                wins.append("All \(hw.count) homework done")
            }

            // Assessments due in the next 4 weeks: planned work done vs time left.
            var progressList: [AssessmentProgress] = []
            for a in input.assessments where a.moduleCode == code && !a.submitted && a.mark == nil {
                guard let due = a.due, due > now, due < now.addingTimeInterval(28 * 86400) else { continue }
                let days = cal.days(from: now, to: due)
                let linked = input.tasks.filter { $0.assessmentID == a.id }
                let total = linked.reduce(0) { $0 + $1.estimateMinutes }
                let done = linked.reduce(0) { $0 + ($1.isDone ? $1.estimateMinutes : min($1.minutesDone, $1.estimateMinutes)) }
                let progress: Double? = total > 0 ? Double(done) / Double(total) : nil
                let status: RAGStatus
                if let p = progress {
                    if (days <= 3 && p < 0.8) || (days <= 7 && p < 0.4) { status = .red }
                    else if (days <= 7 && p < 0.7) || (days <= 14 && p < 0.25) { status = .amber }
                    else { status = .green }
                } else {
                    status = days <= 7 ? .red : (days <= 14 ? .amber : .green)
                }
                progressList.append(AssessmentProgress(assessmentID: a.id, title: a.title, due: due, daysLeft: days,
                                                       weightPercent: a.weightPercent, progress: progress, status: status))
                if status != .green {
                    let pct = progress.map { "\(Int(($0 * 100).rounded()))% done" } ?? "not planned yet"
                    reasons.append(.init("\(a.title): \(pct), due in \(days) day\(days == 1 ? "" : "s")", status))
                }
            }

            // Marks vs target.
            let standing = year.modules.first { $0.moduleCode == code } ?? coach.moduleStanding(module, assessments: input.assessments)
            switch standing.outlook {
            case .secured: wins.append("First already secured")
            case .onTrack:
                if let avg = standing.currentAverage { wins.append(String(format: "Averaging %.0f%%", avg)) }
            case .stretch:
                reasons.append(.init(String(format: "Averaging %.0f%%; needs %.0f%% on the rest", standing.currentAverage ?? 0,
                                            standing.requiredAverageOnRemaining ?? 0), .amber))
            case .outOfReach, .missed:
                reasons.append(.init("A First in this module is out of reach on current marks", .red))
            }

            // Study time this week: planned blocks vs focus done.
            let modBlocks = input.blocks.filter { $0.moduleCode == code && $0.start >= periodStart && $0.start < periodEnd }
            let planned = modBlocks.reduce(0) { $0 + $1.minutes }
            let doneMinutes: Int
            if useFocus {
                doneMinutes = input.focusLog.filter { $0.moduleCode == code && $0.start >= periodStart && $0.start < periodEnd }
                    .reduce(0) { $0 + $1.minutes }
            } else {
                doneMinutes = modBlocks.filter { input.completedBlockIDs.contains($0.id) }.reduce(0) { $0 + $1.minutes }
            }
            if planned >= 120 {
                let ratio = Double(doneMinutes) / Double(planned)
                let text = "Studied \(OnTrackReport.hours(doneMinutes)) of \(OnTrackReport.hours(planned)) planned"
                if ratio < 0.3 { reasons.append(.init(text, .red)) }
                else if ratio < 0.6 { reasons.append(.init(text, .amber)) }
                else { wins.append(text) }
            }

            let reds = reasons.filter { $0.status == .red }.count
            let ambers = reasons.filter { $0.status == .amber }.count
            let status: RAGStatus = reds > 0 || ambers >= 3 ? .red : (ambers > 0 ? .amber : .green)
            modules.append(ModuleOnTrack(
                moduleCode: code, moduleName: module.name, readingsDone: readingsDone, readingsAssigned: assigned.count,
                lecturesHeld: heldDays.count, lecturesWithNotes: withNotes, homeworkDone: hwDone, homeworkTotal: hw.count,
                homeworkOverdue: overdue, assessments: progressList, currentAverage: standing.currentAverage,
                requiredOnRemaining: standing.requiredAverageOnRemaining, outlook: standing.outlook,
                minutesPlanned: planned, minutesDone: doneMinutes, status: status,
                reasons: reasons.sorted { $0.status > $1.status }, wins: wins))
        }

        let overall: RAGStatus = modules.contains { $0.status == .red } ? .red
            : (modules.contains { $0.status == .amber } ? .amber : .green)
        return OnTrackReport(
            weekKey: cal.format(now, "YYYY-'W'ww"), generatedAt: now, periodStart: periodStart, periodEnd: periodEnd,
            target: prefs.targetGrade, modules: modules, overall: overall, yearAverage: year.currentAverage,
            requiredOnRemaining: year.requiredAverageOnRemaining,
            minutesPlanned: modules.reduce(0) { $0 + $1.minutesPlanned }, minutesDone: modules.reduce(0) { $0 + $1.minutesDone },
            topActions: topActions(modules), narrative: nil)
    }

    /// The three most useful things to do, reddest first.
    func topActions(_ modules: [ModuleOnTrack]) -> [String] {
        var actions: [(RAGStatus, String)] = []
        for m in modules {
            for a in m.assessments where a.status != .green {
                actions.append((a.status, a.progress == nil ? "Plan \(m.moduleCode) “\(a.title)” today" : "Put two focus blocks on \(m.moduleCode) “\(a.title)”"))
            }
            if let hw = m.homeworkOverdue.first { actions.append((.red, "Finish \(m.moduleCode) homework: \(hw)")) }
            let missing = m.lecturesHeld - m.lecturesWithNotes
            if missing > 0 { actions.append((missing >= 3 ? .red : .amber, "Type up notes for \(missing) \(m.moduleCode) lecture\(missing == 1 ? "" : "s")")) }
            let unread = m.readingsAssigned - m.readingsDone
            if unread > 0, Double(m.readingsDone) / Double(max(1, m.readingsAssigned)) < 0.75 {
                actions.append((.amber, "Catch up on \(unread) \(m.moduleCode) reading\(unread == 1 ? "" : "s")"))
            }
        }
        var seen = Set<String>()
        return actions.sorted { $0.0 > $1.0 }.map(\.1).filter { seen.insert($0).inserted }.prefix(3).map { $0 }
    }
}
