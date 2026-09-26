import Foundation

/// Rough kind of work a task is, used to learn how long each kind really takes.
public enum TaskKind: String, Codable, CaseIterable, Sendable {
    case reading, writing, problemSet, revision, notes, admin, other

    public var label: String {
        switch self {
        case .reading: "Reading"
        case .writing: "Writing"
        case .problemSet: "Problem sets"
        case .revision: "Revision"
        case .notes: "Notes"
        case .admin: "Admin"
        case .other: "Other"
        }
    }

    static let keywords: [(TaskKind, [String])] = [
        (.revision, ["revise", "revision", "flashcard", "past paper", "practice exam", "mock", "recap", "review session"]),
        (.problemSet, ["problem set", "problem sheet", "homework", "exercise", "worksheet", "tutorial prep", "question sheet",
                       "questions", "seminar prep", "workshop prep", "calculation", "problems"]),
        (.writing, ["essay", "draft", "write", "writing", "report", "outline", "edit", "proofread", "plan essay", "introduction",
                    "conclusion", "reference check"]),
        (.reading, ["read", "reading", "chapter", "article", "paper", "textbook", "pp.", "pages"]),
        (.notes, ["notes", "type up", "summarise", "summary", "lecture review", "catch up on lecture", "watch lecture", "recording"]),
        (.admin, ["email", "call", "book", "form", "apply", "register", "pay", "admin", "submit"]),
    ]

    /// Classifies by keywords in the title (first match in priority order).
    public static func classify(title: String, notes: String = "") -> TaskKind {
        let t = " " + title.lowercased() + " "
        for (kind, words) in keywords where words.contains(where: { t.contains($0) }) { return kind }
        let n = notes.lowercased()
        for (kind, words) in keywords where words.contains(where: { n.contains($0) }) { return kind }
        return .other
    }
}

/// A running (or finished) focus session on a task or planned block.
/// Pure value logic: the app owns the timer and just asks for `elapsed(at:)`.
public struct FocusSession: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var taskID: UUID?
    public var blockID: UUID?
    public var title: String
    public var moduleCode: String?
    public var kind: TaskKind
    /// Planned length (block length or a chosen timer), if any.
    public var plannedMinutes: Int?
    public var startedAt: Date
    public var endedAt: Date?
    public var pausedAt: Date?
    /// Total seconds spent paused so far (not counting a pause in progress).
    public var pausedSeconds: TimeInterval

    public init(id: UUID = UUID(), taskID: UUID? = nil, blockID: UUID? = nil, title: String, moduleCode: String? = nil,
                kind: TaskKind? = nil, plannedMinutes: Int? = nil, startedAt: Date) {
        self.id = id; self.taskID = taskID; self.blockID = blockID; self.title = title; self.moduleCode = moduleCode
        self.kind = kind ?? TaskKind.classify(title: title); self.plannedMinutes = plannedMinutes
        self.startedAt = startedAt; self.endedAt = nil; self.pausedAt = nil; self.pausedSeconds = 0
    }

    public var isPaused: Bool { pausedAt != nil && endedAt == nil }
    public var isRunning: Bool { endedAt == nil && pausedAt == nil }
    public var isFinished: Bool { endedAt != nil }

    /// Focused seconds (paused time excluded).
    public func elapsed(at now: Date) -> TimeInterval {
        let end = endedAt ?? now
        var paused = pausedSeconds
        if let p = pausedAt { paused += max(0, end.timeIntervalSince(p)) }
        return max(0, end.timeIntervalSince(startedAt) - paused)
    }

    /// Seconds left of the planned length (negative once over).
    public func remaining(at now: Date) -> TimeInterval? {
        plannedMinutes.map { Double($0 * 60) - elapsed(at: now) }
    }

    public mutating func pause(at now: Date) {
        guard endedAt == nil, pausedAt == nil else { return }
        pausedAt = now
    }

    public mutating func resume(at now: Date) {
        guard endedAt == nil, let p = pausedAt else { return }
        pausedSeconds += max(0, now.timeIntervalSince(p))
        pausedAt = nil
    }

    /// Ends the session and returns the log entry (nil for under a minute of focus).
    public mutating func finish(at now: Date) -> FocusLogEntry? {
        guard endedAt == nil else { return nil }
        if let p = pausedAt { pausedSeconds += max(0, now.timeIntervalSince(p)); pausedAt = nil }
        endedAt = now
        let minutes = Int((elapsed(at: now) / 60).rounded())
        guard minutes >= 1 else { return nil }
        return FocusLogEntry(id: id, taskID: taskID, blockID: blockID, title: title, moduleCode: moduleCode, kind: kind,
                             start: startedAt, end: now, minutes: minutes)
    }

    /// "24:13" style clock for the menu bar (counts down with a plan, up without).
    public func clock(at now: Date) -> String {
        let seconds: Int
        if let r = remaining(at: now) { seconds = Int(abs(r).rounded()) } else { seconds = Int(elapsed(at: now).rounded()) }
        let sign = (remaining(at: now) ?? 0) < 0 ? "+" : ""
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%@%d:%02d:%02d", sign, h, m, s) : String(format: "%@%02d:%02d", sign, m, s)
    }
}

/// One finished focus session.
public struct FocusLogEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var taskID: UUID?
    public var blockID: UUID?
    public var title: String
    public var moduleCode: String?
    public var kind: TaskKind
    public var start: Date
    public var end: Date
    public var minutes: Int

    public init(id: UUID = UUID(), taskID: UUID?, blockID: UUID? = nil, title: String, moduleCode: String?, kind: TaskKind,
                start: Date, end: Date, minutes: Int) {
        self.id = id; self.taskID = taskID; self.blockID = blockID; self.title = title; self.moduleCode = moduleCode
        self.kind = kind; self.start = start; self.end = end; self.minutes = minutes
    }
}

public enum FocusLog {
    /// Minutes focused per module in [from, to).
    public static func minutesByModule(_ log: [FocusLogEntry], from: Date, to: Date) -> [String: Int] {
        var out: [String: Int] = [:]
        for e in log where e.start >= from && e.start < to { out[e.moduleCode ?? "", default: 0] += e.minutes }
        return out
    }

    public static func minutes(for taskID: UUID, in log: [FocusLogEntry]) -> Int {
        log.filter { $0.taskID == taskID }.reduce(0) { $0 + $1.minutes }
    }
}

/// Learns how long each kind of task really takes compared with its estimate
/// (actual / estimate), and scales new estimates by that.
///
/// - Each finished task gives one sample; ratios are clamped to 0.3–3 so one
///   odd task can't wreck the average.
/// - The average is exponentially weighted (recent tasks count more).
/// - The multiplier is blended towards 1 until there are enough samples
///   (weight n / (n + 3)), and kept within 0.6–2.
public struct DurationLearner: Codable, Hashable, Sendable {
    public struct Stats: Codable, Hashable, Sendable {
        public var samples: Int
        public var meanRatio: Double
        public init(samples: Int = 0, meanRatio: Double = 1) { self.samples = samples; self.meanRatio = meanRatio }
    }

    public var stats: [TaskKind: Stats]
    public var smoothing: Double
    public var minimumSamples: Int

    public init(stats: [TaskKind: Stats] = [:], smoothing: Double = 0.3, minimumSamples: Int = 2) {
        self.stats = stats; self.smoothing = smoothing; self.minimumSamples = minimumSamples
    }

    /// Records a finished task. `appliedMultiplier` is the multiplier that was
    /// already applied to `estimateMinutes` when the task was created (so the
    /// learner compares with the raw estimate and doesn't compound).
    public mutating func record(kind: TaskKind, estimateMinutes: Int, actualMinutes: Int, appliedMultiplier: Double = 1) {
        guard estimateMinutes > 0, actualMinutes > 0, appliedMultiplier > 0 else { return }
        let raw = Double(estimateMinutes) / appliedMultiplier
        let ratio = min(3, max(0.3, Double(actualMinutes) / raw))
        var s = stats[kind] ?? Stats()
        s.meanRatio = s.samples == 0 ? ratio : (1 - smoothing) * s.meanRatio + smoothing * ratio
        s.samples += 1
        stats[kind] = s
    }

    public func multiplier(for kind: TaskKind) -> Double {
        guard let s = stats[kind], s.samples >= minimumSamples else { return 1 }
        let n = Double(s.samples)
        let blended = 1 + (s.meanRatio - 1) * (n / (n + 3))
        return min(2, max(0.6, blended))
    }

    /// Estimate scaled by what's been learned, rounded to 5 minutes.
    public func adjustedEstimate(_ minutes: Int, kind: TaskKind) -> Int {
        let m = multiplier(for: kind)
        guard m != 1 else { return minutes }
        return max(5, Int((Double(minutes) * m / 5).rounded()) * 5)
    }

    public func adjusted(_ task: OrbitTask) -> (task: OrbitTask, multiplier: Double) {
        let kind = TaskKind.classify(title: task.title, notes: task.notes)
        let m = multiplier(for: kind)
        guard m != 1 else { return (task, 1) }
        var t = task
        t.estimateMinutes = adjustedEstimate(task.estimateMinutes, kind: kind)
        return (t, m)
    }

    /// "Reading takes you about 1.4× your estimates (6 tasks)".
    public var summary: [String] {
        TaskKind.allCases.compactMap { k in
            guard let s = stats[k], s.samples > 0 else { return nil }
            let m = multiplier(for: k)
            let pct = String(format: "%.1f×", s.meanRatio)
            return "\(k.label): about \(pct) your estimates (\(s.samples) task\(s.samples == 1 ? "" : "s"))"
                + (m == 1 ? " – not applied yet" : "")
        }
    }
}
