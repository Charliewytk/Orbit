import Foundation

/// Group projects: members, shared tasks, deadlines and a log of the student's own contributions.
public struct GroupProject: Codable, Hashable, Sendable, Identifiable {
    public struct Member: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var email: String?
        public var role: String?
        public var isMe: Bool
        public init(id: String = UUID().uuidString, name: String, email: String? = nil, role: String? = nil, isMe: Bool = false) {
            self.id = id; self.name = name; self.email = email; self.role = role; self.isMe = isMe
        }
    }

    public struct GroupTask: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var assigneeID: String?
        public var due: Date?
        public var done: Bool
        public init(id: String = UUID().uuidString, title: String, assigneeID: String? = nil, due: Date? = nil, done: Bool = false) {
            self.id = id; self.title = title; self.assigneeID = assigneeID; self.due = due; self.done = done
        }
    }

    public struct Contribution: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var date: Date
        public var summary: String
        public var minutes: Int
        public init(id: String = UUID().uuidString, date: Date, summary: String, minutes: Int = 0) {
            self.id = id; self.date = date; self.summary = summary; self.minutes = minutes
        }
    }

    public var id: String
    public var name: String
    public var moduleCode: String?
    public var deadline: Date?
    public var members: [Member]
    public var tasks: [GroupTask]
    public var contributions: [Contribution]
    public var notes: String
    public var archived: Bool

    public init(id: String = UUID().uuidString, name: String, moduleCode: String? = nil, deadline: Date? = nil,
                members: [Member] = [Member(name: "Me", isMe: true)], tasks: [GroupTask] = [],
                contributions: [Contribution] = [], notes: String = "", archived: Bool = false) {
        self.id = id; self.name = name; self.moduleCode = moduleCode; self.deadline = deadline; self.members = members
        self.tasks = tasks; self.contributions = contributions; self.notes = notes; self.archived = archived
    }

    public var me: Member? { members.first(where: \.isMe) }

    public var myOpenTasks: [GroupTask] {
        tasks.filter { !$0.done && $0.assigneeID != nil && $0.assigneeID == me?.id }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    public func overdue(now: Date) -> [GroupTask] { tasks.filter { !$0.done && ($0.due.map { $0 < now } ?? false) } }

    public var progress: Double { tasks.isEmpty ? 0 : Double(tasks.filter(\.done).count) / Double(tasks.count) }

    /// Share of completed tasks per member (fairness check).
    public var completedByMember: [String: Int] {
        var out: [String: Int] = [:]
        for t in tasks where t.done { out[t.assigneeID ?? "unassigned", default: 0] += 1 }
        return out
    }

    public var myMinutes: Int { contributions.reduce(0) { $0 + $1.minutes } }

    /// Plain text log for a peer-assessment form.
    public func contributionReport(calendar: DayCalendar) -> String {
        var lines = ["\(name)\(moduleCode.map { " (\($0))" } ?? ""): my contributions"]
        for c in contributions.sorted(by: { $0.date < $1.date }) {
            lines.append("- \(calendar.shortDay(c.date)): \(c.summary)" + (c.minutes > 0 ? " (\(c.minutes) min)" : ""))
        }
        let mine = tasks.filter { $0.done && $0.assigneeID == me?.id }
        if !mine.isEmpty { lines.append("Tasks completed: " + mine.map(\.title).joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }
}

public struct GroupWorkBoard: Codable, Hashable, Sendable {
    public var projects: [GroupProject] = []
    public init(projects: [GroupProject] = []) { self.projects = projects }

    public var active: [GroupProject] { projects.filter { !$0.archived }.sorted { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) } }

    /// My open group tasks due within `days`, soonest first (for the briefing and Home).
    public func myDue(now: Date, days: Int) -> [(project: GroupProject, task: GroupProject.GroupTask)] {
        let horizon = now.addingTimeInterval(Double(days) * 86400)
        return active.flatMap { p in p.myOpenTasks.filter { ($0.due ?? .distantFuture) <= horizon }.map { (p, $0) } }
            .sorted { ($0.task.due ?? .distantFuture) < ($1.task.due ?? .distantFuture) }
    }

    public mutating func update(_ project: GroupProject) {
        if let i = projects.firstIndex(where: { $0.id == project.id }) { projects[i] = project } else { projects.append(project) }
    }
}
