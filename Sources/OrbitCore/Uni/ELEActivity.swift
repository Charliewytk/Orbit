import Foundation

// "What's going on on ELE": notifications, messages, announcements, new files,
// grades and feedback, parsed from the logged-in website's AJAX calls (or HTML
// where AJAX isn't allowed) and kept as one activity feed. All pure and tested.

public struct ELEActivityItem: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case newFile, newContent, weekUpdated, newAssessment, deadlineChanged, announcement, forumPost, grade, feedback,
             notification, message, submission, homework, other

        public var emoji: String {
            switch self {
            case .newFile, .newContent: "📄"
            case .weekUpdated: "📚"
            case .newAssessment: "📝"
            case .deadlineChanged: "📅"
            case .announcement: "📣"
            case .forumPost: "💬"
            case .grade: "🎓"
            case .feedback: "✍️"
            case .notification: "🔔"
            case .message: "✉️"
            case .submission: "✅"
            case .homework: "🧮"
            case .other: "•"
            }
        }
    }

    /// Stable id so the same thing is never listed twice ("forum-post-123", "cm-456-new").
    public var id: String
    public var kind: Kind
    public var moduleCode: String?
    public var title: String
    public var detail: String
    public var date: Date
    public var url: String?
    /// Worth a notification.
    public var important: Bool

    public init(id: String, kind: Kind, moduleCode: String? = nil, title: String, detail: String = "", date: Date,
                url: String? = nil, important: Bool = false) {
        self.id = id; self.kind = kind; self.moduleCode = moduleCode; self.title = title; self.detail = detail
        self.date = date; self.url = url; self.important = important
    }

    /// "📄 BEE1022 · New file in week 3: Lecture 05 slides".
    public var line: String {
        "\(kind.emoji) " + [moduleCode, title].compactMap { $0 }.joined(separator: " · ") + (detail.isEmpty ? "" : " — \(detail.prefix(160))")
    }
}

/// The activity feed, newest first, de-duplicated by id.
public struct ELEActivityFeed: Codable, Hashable, Sendable {
    public private(set) var items: [ELEActivityItem] = []
    public var limit: Int = 600

    public init(items: [ELEActivityItem] = []) { self.items = items.sorted { $0.date > $1.date } }

    /// Adds items not seen before and returns them (for notifications).
    @discardableResult
    public mutating func add(_ new: [ELEActivityItem]) -> [ELEActivityItem] {
        let known = Set(items.map(\.id))
        var fresh: [ELEActivityItem] = []
        var seen = Set<String>()
        for item in new where !known.contains(item.id) && seen.insert(item.id).inserted { fresh.append(item) }
        items = Array((items + fresh).sorted { $0.date > $1.date }.prefix(limit))
        return fresh
    }

    public func recent(since: Date? = nil, moduleCode: String? = nil, limit: Int = 30) -> [ELEActivityItem] {
        Array(items.filter { (since == nil || $0.date >= since!) && (moduleCode == nil || $0.moduleCode == moduleCode) }.prefix(limit))
    }

    /// New files, weeks, assessments and deadline moves between two course-page syncs.
    public static func changes(from old: ELEWebSnapshot?, to new: ELEWebSnapshot) -> [ELEActivityItem] {
        guard let old else { return [] }
        var out: [ELEActivityItem] = []
        let date = new.fetchedAt
        for (code, content) in new.contents {
            guard let before = old.contents[code] else { continue }
            let oldIDs = Set(before.sections.flatMap(\.items).compactMap(\.cmid))
            for s in content.sections {
                for item in s.items where item.kind != .label {
                    guard let cmid = item.cmid, !oldIDs.contains(cmid) else { continue }
                    let place = s.kind == .week && s.week != nil ? "week \(s.week!)" : s.title
                    let kind: ELEActivityItem.Kind = item.kind == .resource || item.kind == .folder ? .newFile : .newContent
                    out.append(ELEActivityItem(id: "cm-\(cmid)-new", kind: kind, moduleCode: code,
                                               title: "New \(kind == .newFile ? "file" : item.kind.rawValue) in \(place): \(item.name)",
                                               date: date, url: item.url,
                                               important: item.role == .slides || item.role == .assessmentBrief || HomeworkDetector.looksLikeHomework(item.name)))
                }
            }
        }
        let diff = ELEWebChanges.diff(from: old, to: new)
        for a in diff.base.newAssessments {
            out.append(ELEActivityItem(id: "assessment-\(a.id)-new", kind: .newAssessment, moduleCode: a.moduleCode,
                                       title: "New assessment: \(a.title)", detail: a.due.map { "due \(ELELive.format($0))" } ?? "",
                                       date: date, url: a.eleURL, important: true))
        }
        for c in diff.base.changedDeadlines {
            out.append(ELEActivityItem(id: "assessment-\(c.assessment.id)-due-\(Int(c.newDue?.timeIntervalSince1970 ?? 0))",
                                       kind: .deadlineChanged, moduleCode: c.assessment.moduleCode,
                                       title: "Deadline changed: \(c.assessment.title)",
                                       detail: c.newDue.map { "now \(ELELive.format($0))" } ?? "date removed", date: date,
                                       url: c.assessment.eleURL, important: true))
        }
        for w in diff.updatedWeeks {
            out.append(ELEActivityItem(id: "week-\(w.moduleCode)-\(w.week)-\(MD5.hex(new.contents[w.moduleCode]?.weeks.first { $0.week == w.week }?.contentKey ?? "").prefix(8))",
                                       kind: .weekUpdated, moduleCode: w.moduleCode, title: "Week \(w.week) updated", detail: w.title, date: date))
        }
        return out
    }
}

// MARK: - Live data

public struct ELENotification: Codable, Hashable, Sendable {
    public var id: Int
    public var subject: String
    public var text: String
    public var url: String?
    public var date: Date
    public var read: Bool
    public var component: String?
    public var eventType: String?
}

public struct ELEConversation: Codable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var lastMessage: String
    public var lastMessageID: Int?
    public var date: Date
    public var unread: Int
}

public struct ELEForum: Codable, Hashable, Sendable {
    public var id: Int
    public var courseID: Int
    public var cmid: Int?
    public var name: String
    public var type: String
    public var isNews: Bool { type == "news" }
}

public struct ELEDiscussion: Codable, Hashable, Sendable {
    public var id: Int
    public var forumID: Int?
    public var subject: String
    public var message: String
    public var author: String
    public var created: Date
    public var modified: Date
}

public struct ELEGradeItem: Codable, Hashable, Sendable {
    public var id: Int
    public var courseID: Int
    public var name: String
    public var module: String?
    public var cmid: Int?
    /// The activity's instance id (e.g. the assignment id for mod_assign calls).
    public var instance: Int?
    public var grade: String?
    public var percentage: Double?
    public var feedback: String
    public var gradedAt: Date?
}

public struct ELESubmissionStatus: Codable, Hashable, Sendable {
    public var status: String?
    public var gradingStatus: String?
    public var grade: String?
    public var gradedAt: Date?
    public var feedbackComments: String
    public var hasFeedbackFiles: Bool
}

/// A row of Exeter's "My Assessments" dashboard block.
public struct ELEMyAssessmentRow: Codable, Hashable, Sendable {
    public var moduleCode: String?
    public var title: String
    public var dueText: String
    public var due: Date?
    public var status: String?
    public var url: String?
}

public enum ELELive {
    static func int(_ v: Any?) -> Int? { ELEWebParser.int(v) }
    static func date(_ v: Any?) -> Date? { int(v).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil } }
    static func str(_ v: Any?) -> String { UniHTML.decodeEntities(v as? String ?? "") }

    static func format(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB"); f.timeZone = ELEWebParser.london; f.dateFormat = "EEE d MMM HH:mm"
        return f.string(from: d)
    }

    /// The logged-in user's id from any ELE page.
    public static func userID(inHTML html: String) -> Int? {
        for p in ["\"userid\"\\s*:\\s*\"?(\\d+)", "data-userid=\"(\\d+)\"", "user/profile\\.php\\?id=(\\d+)", "data-user-id=\"(\\d+)\""] {
            if let m = UniRegex.first(p, in: html), let id = m[1].flatMap(Int.init), id > 1 { return id }
        }
        return nil
    }

    // MARK: AJAX parsers

    /// message_popup_get_popup_notifications.
    public static func notifications(fromAJAX data: Data) throws -> [ELENotification] {
        let payload = try ELEWebParser.ajaxData(data)
        let list = (payload as? [String: Any])?["notifications"] as? [[String: Any]] ?? []
        return list.compactMap { n in
            guard let id = int(n["id"]) else { return nil }
            let subject = str(n["subject"]).isEmpty ? str(n["shortenedsubject"]) : str(n["subject"])
            let text = UniHTML.text(str(n["smallmessage"]).isEmpty ? str(n["fullmessage"]) : str(n["smallmessage"]))
            return ELENotification(id: id, subject: subject, text: text, url: n["contexturl"] as? String,
                                   date: date(n["timecreated"]) ?? Date(), read: (n["read"] as? Bool) ?? (int(n["timeread"]) != nil),
                                   component: n["component"] as? String, eventType: n["eventtype"] as? String)
        }
    }

    /// core_message_get_conversations.
    public static func conversations(fromAJAX data: Data) throws -> [ELEConversation] {
        let payload = try ELEWebParser.ajaxData(data)
        let list = (payload as? [String: Any])?["conversations"] as? [[String: Any]] ?? []
        return list.compactMap { c in
            guard let id = int(c["id"]) else { return nil }
            let members = (c["members"] as? [[String: Any]] ?? []).map { str($0["fullname"]) }.filter { !$0.isEmpty }
            let name = str(c["name"]).isEmpty ? members.joined(separator: ", ") : str(c["name"])
            let last = (c["messages"] as? [[String: Any]] ?? []).max { (int($0["timecreated"]) ?? 0) < (int($1["timecreated"]) ?? 0) }
            return ELEConversation(id: id, name: name, lastMessage: UniHTML.text(str(last?["text"])),
                                   lastMessageID: int(last?["id"]), date: date(last?["timecreated"]) ?? Date.distantPast,
                                   unread: int(c["unreadcount"]) ?? ((c["isread"] as? Bool) == false ? 1 : 0))
        }
    }

    /// mod_forum_get_forums_by_courses.
    public static func forums(fromAJAX data: Data) throws -> [ELEForum] {
        let payload = try ELEWebParser.ajaxData(data)
        return (payload as? [[String: Any]] ?? []).compactMap { f in
            guard let id = int(f["id"]), let course = int(f["course"]) else { return nil }
            return ELEForum(id: id, courseID: course, cmid: int(f["cmid"]), name: str(f["name"]), type: f["type"] as? String ?? "general")
        }
    }

    /// mod_forum_get_forum_discussions (or _paginated).
    public static func discussions(fromAJAX data: Data, forumID: Int? = nil) throws -> [ELEDiscussion] {
        let payload = try ELEWebParser.ajaxData(data)
        let list = (payload as? [String: Any])?["discussions"] as? [[String: Any]] ?? []
        return list.compactMap { d in
            guard let id = int(d["discussion"]) ?? int(d["id"]) else { return nil }
            let created = date(d["created"]) ?? date(d["timemodified"]) ?? Date()
            return ELEDiscussion(id: id, forumID: forumID ?? int(d["forum"]), subject: str(d["subject"]).isEmpty ? str(d["name"]) : str(d["subject"]),
                                 message: UniHTML.text(str(d["message"])), author: str(d["userfullname"]),
                                 created: created, modified: date(d["timemodified"]) ?? date(d["modified"]) ?? created)
        }
    }

    /// gradereport_user_get_grade_items.
    public static func gradeItems(fromAJAX data: Data) throws -> [ELEGradeItem] {
        let payload = try ELEWebParser.ajaxData(data)
        let users = (payload as? [String: Any])?["usergrades"] as? [[String: Any]] ?? []
        return users.flatMap { u -> [ELEGradeItem] in
            let course = int(u["courseid"]) ?? 0
            return (u["gradeitems"] as? [[String: Any]] ?? []).compactMap { g in
                guard let id = int(g["id"]) else { return nil }
                let type = g["itemtype"] as? String ?? ""
                guard type != "course" && type != "category" else { return nil }
                let formatted = str(g["gradeformatted"]).trimmingCharacters(in: .whitespaces)
                let pct = str(g["percentageformatted"]).replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
                var percentage = Double(pct)
                if percentage == nil, let raw = g["graderaw"] as? Double, let max = g["grademax"] as? Double, max > 0 { percentage = raw / max * 100 }
                let hasGrade = !(formatted.isEmpty || formatted == "-") || percentage != nil
                return ELEGradeItem(id: id, courseID: course, name: str(g["itemname"]), module: g["itemmodule"] as? String,
                                    cmid: int(g["cmid"]), instance: int(g["iteminstance"]), grade: hasGrade ? (formatted.isEmpty ? nil : formatted) : nil,
                                    percentage: percentage, feedback: UniHTML.text(str(g["feedback"])),
                                    gradedAt: date(g["gradedategraded"]))
            }
        }
    }

    /// The user grade report page (grade/report/user/index.php) when the AJAX call isn't allowed.
    public static func gradeItems(fromReportHTML html: String, courseID: Int) -> [ELEGradeItem] {
        UniRegex.matches("<tr[^>]*>(.*?)</tr>", in: html, dotAll: true).enumerated().compactMap { i, row in
            let r = row[1] ?? ""
            guard let nameCell = UniRegex.first("<t[hd][^>]*class=\"[^\"]*column-itemname[^\"]*\"[^>]*>(.*?)</t[hd]>", in: r, dotAll: true)?[1] else { return nil }
            let name = UniHTML.text(UniRegex.replace("<span[^>]*class=\"[^\"]*(?:accesshide|sr-only)[^\"]*\"[^>]*>.*?</span>", in: nameCell, with: "", dotAll: true))
            func cell(_ c: String) -> String {
                UniHTML.text(UniRegex.first("<td[^>]*class=\"[^\"]*column-\(c)\\b[^\"]*\"[^>]*>(.*?)</td>", in: r, dotAll: true)?[1] ?? "")
            }
            let grade = cell("grade"), pct = cell("percentage").replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.lowercased().contains("course total") else { return nil }
            let cmid = UniRegex.first("/mod/[a-z]+/view\\.php\\?id=(\\d+)", in: nameCell)?[1].flatMap(Int.init)
            let module = UniRegex.first("/mod/([a-z]+)/", in: nameCell)?[1]
            return ELEGradeItem(id: cmid ?? (courseID * 1000 + i), courseID: courseID, name: name, module: module, cmid: cmid,
                                instance: nil, grade: grade.isEmpty || grade == "-" ? nil : grade, percentage: Double(pct),
                                feedback: cell("feedback"), gradedAt: nil)
        }
    }

    /// mod_assign_get_submission_status.
    public static func submissionStatus(fromAJAX data: Data) throws -> ELESubmissionStatus {
        let payload = try ELEWebParser.ajaxData(data) as? [String: Any] ?? [:]
        let attempt = payload["lastattempt"] as? [String: Any]
        let submission = attempt?["submission"] as? [String: Any] ?? attempt?["teamsubmission"] as? [String: Any]
        let feedback = payload["feedback"] as? [String: Any]
        let plugins = feedback?["plugins"] as? [[String: Any]] ?? []
        var comments: [String] = []
        var files = false
        for p in plugins {
            for f in p["editorfields"] as? [[String: Any]] ?? [] { comments.append(UniHTML.text(str(f["text"]))) }
            if !(p["fileareas"] as? [[String: Any]] ?? []).flatMap({ $0["files"] as? [[String: Any]] ?? [] }).isEmpty { files = true }
        }
        let grade = feedback?["grade"] as? [String: Any]
        return ELESubmissionStatus(status: submission?["status"] as? String, gradingStatus: attempt?["gradingstatus"] as? String,
                                   grade: (feedback?["gradefordisplay"] as? String).map(UniHTML.text),
                                   gradedAt: date(feedback?["gradeddate"]) ?? date(grade?["timemodified"]),
                                   feedbackComments: comments.filter { !$0.isEmpty }.joined(separator: "\n"), hasFeedbackFiles: files)
    }

    /// core_course_get_updates_since → cmids that changed (content files, configuration, new posts…).
    public static func updatedModules(fromAJAX data: Data) throws -> [Int: [String]] {
        let payload = try ELEWebParser.ajaxData(data)
        let list = (payload as? [String: Any])?["instances"] as? [[String: Any]] ?? []
        var out: [Int: [String]] = [:]
        for i in list where (i["contextlevel"] as? String ?? "module") == "module" {
            guard let id = int(i["id"]) else { continue }
            let names = (i["updates"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            if !names.isEmpty { out[id] = names }
        }
        return out
    }

    /// Exeter's "My Assessments" block on the dashboard: rows of module, assessment and deadline.
    public static func myAssessments(fromDashboardHTML html: String, academicYear: Int) -> [ELEMyAssessmentRow] {
        // The block's HTML: from its heading to the end of its section.
        guard let start = html.range(of: "My Assessments", options: .caseInsensitive) else { return [] }
        let tail = String(html[start.lowerBound...].prefix(200_000))
        let block = UniRegex.first("^(.*?)(?:</section>|<section\\b|data-block=)", in: tail, dotAll: true)?[1] ?? tail
        var rows: [String] = UniRegex.matches("<tr[^>]*>(.*?)</tr>", in: block, dotAll: true).compactMap { $0[1] }
        if rows.isEmpty { rows = UniRegex.matches("<li[^>]*>(.*?)</li>", in: block, dotAll: true).compactMap { $0[1] } }
        if rows.isEmpty {
            rows = UniRegex.matches("<div[^>]*class=\"[^\"]*(?:assessment|list-group-item|card)[^\"]*\"[^>]*>(.*?)</div>", in: block, dotAll: true).compactMap { $0[1] }
        }
        return rows.compactMap { r in
            let cells = UniRegex.matches("<t[hd][^>]*>(.*?)</t[hd]>", in: r, dotAll: true).map { UniHTML.text($0[1] ?? "") }
            let text = cells.isEmpty ? UniHTML.text(r) : cells.joined(separator: " | ")
            let flat = text.replacingOccurrences(of: "\n", with: " | ")
            guard !flat.isEmpty, UniRegex.first("^\\s*(module|assessment|title|deadline|due)\\b", in: flat) == nil || cells.count < 2 else { return nil }
            let code = ModuleCode.find(in: flat)
            let url = UniRegex.first("href=\"([^\"]+)\"", in: r)?[1].map(UniHTML.decodeEntities)
            var due: Date?
            var dueText = ""
            if let dm = ELEAssessmentExtractor.dayMonth(in: flat) {
                let t = ELEAssessmentExtractor.time(in: flat)
                due = ELEWebParser.date(day: dm.day, month: dm.month, academicYear: academicYear, hour: t?.hour ?? 12, minute: t?.minute ?? 0)
                dueText = UniRegex.first("(\\d{1,2}(?:st|nd|rd|th)?\\s+[A-Za-z]{3,9}(?:\\s+\\d{4})?(?:[^|]{0,20}?\\d{1,2}[:.]\\d{2}(?:\\s*[ap]m)?)?)", in: flat)?[1] ?? ""
            }
            let status = UniRegex.first("\\b(submitted|not submitted|overdue|graded|marked|draft|no submission|released)\\b", in: flat)?[1]
            var parts = cells.isEmpty ? flat.components(separatedBy: " | ") : cells
            parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != code && !$0.contains(dueText.isEmpty ? "\u{0}" : dueText) }
            let title = parts.first { ModuleCode.find(in: $0) == nil && $0.count > 3 } ?? parts.first ?? flat
            guard code != nil || due != nil else { return nil }
            return ELEMyAssessmentRow(moduleCode: code, title: String(title.prefix(160)), dueText: dueText, due: due, status: status, url: url)
        }
    }

    // MARK: To activity

    public static func activity(notifications: [ELENotification]) -> [ELEActivityItem] {
        notifications.map { n in
            let lower = (n.subject + " " + (n.component ?? "")).lowercased()
            let kind: ELEActivityItem.Kind = lower.contains("feedback") ? .feedback
                : lower.contains("grade") || lower.contains("graded") || lower.contains("mark") ? .grade
                : lower.contains("forum") || lower.contains("announcement") ? .announcement
                : lower.contains("submission") || lower.contains("submitted") ? .submission : .notification
            return ELEActivityItem(id: "notification-\(n.id)", kind: kind, moduleCode: ModuleCode.find(in: n.subject + " " + n.text),
                                   title: n.subject, detail: n.text, date: n.date, url: n.url,
                                   important: !n.read && [.feedback, .grade, .announcement].contains(kind))
        }
    }

    public static func activity(conversations: [ELEConversation]) -> [ELEActivityItem] {
        conversations.filter { $0.lastMessageID != nil }.map { c in
            ELEActivityItem(id: "message-\(c.id)-\(c.lastMessageID ?? 0)", kind: .message, title: "Message from \(c.name)",
                            detail: c.lastMessage, date: c.date, url: "\(ELEWebParser.site)/message/index.php?id=\(c.id)",
                            important: c.unread > 0)
        }
    }

    public static func activity(discussions: [ELEDiscussion], forum: ELEForum, moduleCode: String?) -> [ELEActivityItem] {
        discussions.map { d in
            ELEActivityItem(id: "forum-\(d.id)-\(Int(d.modified.timeIntervalSince1970))", kind: forum.isNews ? .announcement : .forumPost,
                            moduleCode: moduleCode, title: (forum.isNews ? "Announcement: " : "Forum: ") + d.subject,
                            detail: d.message, date: d.modified,
                            url: "\(ELEWebParser.site)/mod/forum/discuss.php?d=\(d.id)", important: forum.isNews)
        }
    }

    public static func activity(grades: [ELEGradeItem], moduleCode: String?) -> [ELEActivityItem] {
        grades.filter { $0.grade != nil || $0.percentage != nil }.map { g in
            let shown = g.percentage.map { String(format: "%.0f%%", $0) } ?? g.grade ?? ""
            return ELEActivityItem(id: "grade-\(g.courseID)-\(g.id)-\(shown)", kind: .grade, moduleCode: moduleCode,
                                   title: "Grade released: \(g.name)", detail: [shown, g.feedback].filter { !$0.isEmpty }.joined(separator: " · "),
                                   date: g.gradedAt ?? Date(), url: g.cmid.map { "\(ELEWebParser.site)/mod/\(g.module ?? "assign")/view.php?id=\($0)" },
                                   important: true)
        }
    }
}
