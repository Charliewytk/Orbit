import Foundation

/// Breakdown of a task's score, for debugging and "why is this first?" explanations.
public struct TaskScore: Codable, Hashable, Sendable {
    public var total: Double
    public var urgency: Double
    public var weightFactor: Double
    public var priorityFactor: Double
    public var isOverdue: Bool
}

/// Ranks tasks: `urgency × assessment weight × priority`.
///
/// Urgency grows as the deadline gets closer and as remaining work fills more
/// of the working time left before it. Overdue tasks get a large boost.
public struct TaskScorer: Sendable {
    /// assessmentID → percentage of the module mark (0–100).
    public var assessmentWeight: @Sendable (String) -> Double?
    /// Rough focused minutes available per day, used to judge time pressure.
    public var dailyCapacityMinutes: Double

    public init(assessmentWeights: [String: Double] = [:], dailyCapacityMinutes: Double = 240) {
        self.assessmentWeight = { assessmentWeights[$0] }
        self.dailyCapacityMinutes = dailyCapacityMinutes
    }

    public init(dailyCapacityMinutes: Double = 240, weightLookup: @escaping @Sendable (String) -> Double?) {
        self.assessmentWeight = weightLookup
        self.dailyCapacityMinutes = dailyCapacityMinutes
    }

    /// Builds a weight lookup from assessment records.
    public init(assessments: [Assessment], dailyCapacityMinutes: Double = 240) {
        let map = Dictionary(assessments.map { ($0.id, $0.weightPercent) }, uniquingKeysWith: { a, _ in a })
        self.init(assessmentWeights: map, dailyCapacityMinutes: dailyCapacityMinutes)
    }

    public static func priorityFactor(_ p: Priority) -> Double {
        switch p {
        case .low: 0.7
        case .normal: 1.0
        case .high: 1.4
        case .critical: 2.0
        }
    }

    public func score(_ task: OrbitTask, now: Date) -> TaskScore {
        let remaining = Double(max(task.remainingMinutes, 1))
        var urgency: Double
        var overdue = false
        if let deadline = task.deadline {
            let hoursLeft = deadline.timeIntervalSince(now) / 3600
            if hoursLeft <= 0 {
                overdue = true
                // 10 when just overdue, growing a little each day late (capped).
                urgency = 10 + min(5, -hoursLeft / 24)
            } else {
                let daysLeft = hoursLeft / 24
                let proximity = 1 / (1 + daysLeft / 2)             // 1 → 0 as the deadline recedes
                let workable = max(30, daysLeft * dailyCapacityMinutes)
                let pressure = min(3, remaining / workable)         // share of time left the work needs
                urgency = 1 + 4 * proximity + 3 * pressure
            }
        } else {
            urgency = 0.5
        }
        let weight = task.assessmentID.flatMap(assessmentWeight) ?? 0
        let weightFactor = 1 + max(0, min(100, weight)) / 50        // 50% assessment doubles the score
        let priorityFactor = Self.priorityFactor(task.priority)
        if task.priority == .critical && !overdue { urgency += 2 }
        return TaskScore(total: urgency * weightFactor * priorityFactor, urgency: urgency,
                         weightFactor: weightFactor, priorityFactor: priorityFactor, isOverdue: overdue)
    }

    /// Tasks sorted most-urgent first, with deterministic tie-breaks.
    public func rank(_ tasks: [OrbitTask], now: Date) -> [OrbitTask] {
        let scored = tasks.map { ($0, score($0, now: now).total) }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return Self.tieBreak(a.0, b.0)
        }.map(\.0)
    }

    static func tieBreak(_ a: OrbitTask, _ b: OrbitTask) -> Bool {
        switch (a.deadline, b.deadline) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        if a.priority != b.priority { return a.priority > b.priority }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }
}
