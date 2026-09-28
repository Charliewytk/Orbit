import Foundation

/// A student-editable grade book: modules with their assessments, weights and marks.
/// Prefilled from ELE (modules + assessments) and then kept as the student's own copy,
/// so edits to weights survive the next sync.
public struct GradeBook: Codable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        /// Percent of the module mark.
        public var weight: Double
        /// Mark out of 100, once known.
        public var mark: Double?
        public var due: Date?
        public var isExam: Bool
        /// True once the student changed weight or mark by hand (sync leaves it alone).
        public var edited: Bool

        public init(id: String = UUID().uuidString, title: String, weight: Double, mark: Double? = nil,
                    due: Date? = nil, isExam: Bool = false, edited: Bool = false) {
            self.id = id; self.title = title; self.weight = weight; self.mark = mark
            self.due = due; self.isExam = isExam; self.edited = edited
        }
    }

    public struct ModuleGrades: Codable, Hashable, Sendable, Identifiable {
        public var id: String { code }
        public var code: String
        public var name: String
        public var credits: Int
        public var items: [Item]

        public init(code: String, name: String, credits: Int = 15, items: [Item] = []) {
            self.code = code; self.name = name; self.credits = credits; self.items = items
        }

        public var totalWeight: Double { items.reduce(0) { $0 + max(0, $1.weight) } }
    }

    public var modules: [ModuleGrades]
    public var updatedAt: Date

    public init(modules: [ModuleGrades] = [], updatedAt: Date = .distantPast) {
        self.modules = modules; self.updatedAt = updatedAt
    }

    /// Merges ELE data in: new modules and assessments are added; weights, marks and dates
    /// update unless the student edited that row. Nothing the student added is removed.
    public mutating func merge(modules incoming: [Module], assessments: [Assessment], now: Date = Date()) {
        for m in incoming {
            var mod = modules.first { $0.code == m.code } ?? ModuleGrades(code: m.code, name: m.name, credits: m.credits)
            mod.name = m.name.isEmpty ? mod.name : m.name
            mod.credits = m.credits > 0 ? m.credits : mod.credits
            let weights = StudyCoach().effectiveWeights(assessments.filter { $0.moduleCode == m.code })
            for a in assessments where a.moduleCode == m.code {
                let w = weights[a.id] ?? a.weightPercent
                if a.kind == .quiz && w <= 0 { continue }
                if let i = mod.items.firstIndex(where: { $0.id == a.id }) {
                    guard !mod.items[i].edited else { continue }
                    mod.items[i].title = a.title
                    mod.items[i].weight = w
                    mod.items[i].mark = a.mark ?? mod.items[i].mark
                    mod.items[i].due = a.due
                } else {
                    mod.items.append(Item(id: a.id, title: a.title, weight: w, mark: a.mark, due: a.due, isExam: a.kind == .exam))
                }
            }
            mod.items.sort { ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title) }
            if let i = modules.firstIndex(where: { $0.code == m.code }) { modules[i] = mod } else { modules.append(mod) }
        }
        modules.sort { $0.code < $1.code }
        updatedAt = now
    }

    public mutating func edit(module code: String, item id: String, weight: Double? = nil, mark: Double?? = nil) {
        guard let mi = modules.firstIndex(where: { $0.code == code }),
              let ii = modules[mi].items.firstIndex(where: { $0.id == id }) else { return }
        if let weight { modules[mi].items[ii].weight = min(100, max(0, weight)) }
        if let mark { modules[mi].items[ii].mark = mark.map { min(100, max(0, $0)) } }
        modules[mi].items[ii].edited = true
    }
}

/// What it takes to finish a module (or the year) on a target.
public struct GradeProjection: Codable, Hashable, Sendable {
    public struct Requirement: Codable, Hashable, Sendable, Identifiable {
        public var id: String { "\(itemID)|\(target)" }
        public var itemID: String
        public var title: String
        public var target: Double
        /// Mark needed on this assessment (every remaining one scoring the same), nil when already secured.
        public var required: Double?
        public var achievable: Bool
    }

    public struct ModuleResult: Codable, Hashable, Sendable, Identifiable {
        public var id: String { code }
        public var code: String
        public var name: String
        public var credits: Int
        public var markedWeight: Double
        public var remainingWeight: Double
        /// Weighted average of marks so far.
        public var average: Double?
        /// Final module mark if everything left scores `average` (or the year average when nothing's marked).
        public var projected: Double?
        /// Required mark on the remaining work for each target (70, 80…).
        public var requiredByTarget: [Double: Double]
        public var requirements: [Requirement]
        /// True when the weights don't add up to 100.
        public var weightWarning: Bool
    }

    public var modules: [ModuleResult]
    public var targets: [Double]
    /// Credit-weighted average of marks so far.
    public var yearAverage: Double?
    /// Credit-weighted projection of the final year mark.
    public var yearProjected: Double?
    /// Average needed on all remaining work in the year to hit each target.
    public var yearRequired: [Double: Double]

    public var classification: String { GradePredictor.classification(yearProjected) }
}

public enum GradePredictor {
    public static let defaultTargets: [Double] = [70, 80]

    public static func classification(_ mark: Double?) -> String {
        guard let m = mark else { return "No marks yet" }
        switch m {
        case 80...: return "High First"
        case 70..<80: return "First"
        case 60..<70: return "2:1"
        case 50..<60: return "2:2"
        case 40..<50: return "Third"
        default: return "Below pass"
        }
    }

    /// Mark needed on remaining weight so a module totalling `total` weight ends on `target`.
    public static func required(target: Double, points: Double, total: Double, remaining: Double) -> Double? {
        guard remaining > 0 else { return nil }
        return (target * total - points) / remaining
    }

    public static func project(_ book: GradeBook, targets: [Double] = defaultTargets) -> GradeProjection {
        var results: [GradeProjection.ModuleResult] = []
        for m in book.modules {
            var marked = 0.0, remaining = 0.0, points = 0.0
            for i in m.items where i.weight > 0 {
                if let mark = i.mark { marked += i.weight; points += mark * i.weight } else { remaining += i.weight }
            }
            let total = marked + remaining
            let avg = marked > 0 ? points / marked : nil
            var byTarget: [Double: Double] = [:]
            var reqs: [GradeProjection.Requirement] = []
            for t in targets {
                let r = required(target: t, points: points, total: max(total, 0), remaining: remaining)
                if let r { byTarget[t] = r }
                for i in m.items where i.mark == nil && i.weight > 0 {
                    let needed = r.flatMap { $0 <= 0 ? nil : $0 }
                    reqs.append(.init(itemID: i.id, title: i.title, target: t, required: needed.map { (($0 * 10).rounded()) / 10 },
                                      achievable: (r ?? 0) <= 100))
                }
            }
            let projected: Double? = total > 0 ? (avg.map { (points + $0 * remaining) / total }) : nil
            results.append(.init(code: m.code, name: m.name, credits: m.credits, markedWeight: marked, remainingWeight: remaining,
                                 average: avg, projected: projected, requiredByTarget: byTarget, requirements: reqs,
                                 weightWarning: total > 0 && abs(total - 100) > 0.5))
        }
        // Year: credit-weighted. Modules with no marks project at the year average so far.
        var avgNum = 0.0, avgDen = 0.0
        for r in results { if let a = r.average { avgNum += a * Double(r.credits); avgDen += Double(r.credits) } }
        let yearAvg = avgDen > 0 ? avgNum / avgDen : nil
        var projNum = 0.0, projDen = 0.0, secured = 0.0, open = 0.0, credits = 0.0
        for r in results {
            let c = Double(r.credits)
            credits += c
            let total = r.markedWeight + r.remainingWeight
            if let p = r.projected ?? yearAvg { projNum += p * c; projDen += c }
            if total > 0 {
                let pts = (r.average ?? 0) * r.markedWeight
                secured += c * pts / total
                open += c * r.remainingWeight / total
            } else {
                open += c
            }
        }
        var yearReq: [Double: Double] = [:]
        if open > 0 { for t in targets { yearReq[t] = (t * credits - secured) / open } }
        return GradeProjection(modules: results, targets: targets, yearAverage: yearAvg,
                               yearProjected: projDen > 0 ? projNum / projDen : nil, yearRequired: yearReq)
    }

    /// One line per module for the assistant / briefing.
    public static func summary(_ p: GradeProjection) -> String {
        var lines = p.modules.map { m -> String in
            let avg = m.average.map { String(format: "%.1f", $0) } ?? "–"
            let need = p.targets.compactMap { t in m.requiredByTarget[t].map { "\(Int(t)): need \(String(format: "%.0f", max(0, $0)))" } }
            return "\(m.code): average \(avg), \(Int(m.remainingWeight))% left" + (need.isEmpty ? "" : " (" + need.joined(separator: ", ") + ")")
        }
        if let y = p.yearProjected { lines.append("Year projection \(String(format: "%.1f", y)) (\(p.classification)).") }
        return lines.joined(separator: "\n")
    }
}
