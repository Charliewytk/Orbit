import Foundation

/// How much a thread matters to the student, with the reasons (shown in the UI).
public struct EdImportance: Codable, Hashable, Sendable {
    public enum Level: Int, Codable, Comparable, Sendable {
        case low = 0, normal = 1, high = 2
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public var level: Level
    public var reasons: [String]
    /// Keywords that matched ("deadline", "room change").
    public var keywords: [String]

    public var isImportant: Bool { level == .high }

    public init(level: Level, reasons: [String] = [], keywords: [String] = []) {
        self.level = level; self.reasons = reasons; self.keywords = keywords
    }

    /// Words that make a post matter. Checked on whole words / phrases.
    public static let keywords = ["deadline", "exam", "assessment", "extension", "cancelled", "canceled", "room change",
                                  "moved to", "quiz", "due", "resit", "mock", "test", "submission", "submit",
                                  "rescheduled", "postponed", "no lecture", "no seminar", "marks released", "feedback released",
                                  "mandatory", "compulsory", "attendance", "change of room", "venue"]

    /// Categories where anything new is course work.
    public static let courseworkCategories = ["assignments", "assignment", "problem sets", "problem set", "coursework", "assessments", "homework"]

    /// Rules:
    /// - announcement → high
    /// - staff author + (pinned, keyword or coursework category) → high; staff alone → high too (staff rarely post noise)
    /// - pinned → high
    /// - student post with keywords or in a coursework category → normal
    /// - Social / off-topic → low
    public static func classify(_ t: EdThread, author: EdAuthor?) -> EdImportance {
        var reasons: [String] = []
        let staff = author?.isStaff ?? false
        let category = (t.category ?? "").lowercased()
        let found = matchedKeywords(t.title + "\n" + t.text)
        let coursework = courseworkCategories.contains(category) || courseworkCategories.contains((t.subcategory ?? "").lowercased())

        if t.isAnnouncement { reasons.append("announcement") }
        if t.isPinned == true { reasons.append("pinned") }
        if staff { reasons.append("from staff (\(author?.name ?? "teaching team"))") }
        if !found.isEmpty { reasons.append("mentions " + found.prefix(3).joined(separator: ", ")) }
        if coursework { reasons.append("in \(t.category ?? "coursework")") }

        let level: Level
        if t.isAnnouncement || t.isPinned == true || staff {
            level = .high
        } else if !found.isEmpty || coursework {
            level = .normal
        } else if category == "social" || category == "off-topic" || category == "random" {
            level = .low
        } else {
            level = .normal
        }
        return EdImportance(level: level, reasons: reasons, keywords: found)
    }

    /// Keywords found in text (lowercased, whole words).
    public static func matchedKeywords(_ text: String) -> [String] {
        let lower = " " + text.lowercased().replacingOccurrences(of: "\n", with: " ") + " "
        return keywords.filter { k in
            let pattern = "(^|[^a-z])" + NSRegularExpression.escapedPattern(for: k) + "([^a-z]|$)"
            return lower.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
