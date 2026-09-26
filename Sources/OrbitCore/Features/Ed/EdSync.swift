import Foundation

/// One thing that happened on Ed (a new thread, a staff post, a reply to you).
public struct EdItem: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case announcement, staffPost, pinned, newThread, reply
    }

    public var id: String
    public var kind: Kind
    public var courseID: Int
    public var courseCode: String
    public var moduleCode: String?
    public var threadID: Int
    public var title: String
    public var category: String?
    public var author: String?
    public var authorIsStaff: Bool
    /// Up to a few thousand characters of the post.
    public var text: String
    public var date: Date
    public var url: String
    public var importance: EdImportance
    /// Found while baselining a course (shown in the feed, never notified).
    public var baseline: Bool

    public var snippet: String { EdText.snippet(text) }

    public var line: String {
        var s = [moduleCode ?? courseCode, category].compactMap { $0 }.joined(separator: " · ")
        s += ": "
        switch kind {
        case .announcement: s += "Announcement — "
        case .staffPost: s += "Staff post — "
        case .pinned: s += "Pinned — "
        case .reply: s += "New reply on "
        case .newThread: break
        }
        s += title
        if let author { s += " (\(author))" }
        return s
    }
}

/// What Orbit remembers about a thread between polls.
public struct EdThreadMark: Codable, Hashable, Sendable {
    public var replyCount: Int
    public var pinned: Bool
    public var updatedAt: String?
}

/// Ed state kept on the Mac (no token here).
public struct EdState: Codable, Hashable, Sendable {
    public var userID: Int?
    public var userName: String?
    public var courses: [EdCourse] = []
    public var marks: [Int: EdThreadMark] = [:]
    public var baselined: Set<Int> = []
    public private(set) var items: [EdItem] = []
    public var lastSync: Date?
    /// Deadline tasks already made ("threadID|yyyy-MM-dd").
    public var deadlineKeys: Set<String> = []
    public var limit = 500

    public init() {}

    enum CodingKeys: String, CodingKey {
        case userID, userName, courses, marks, baselined, items, lastSync, deadlineKeys
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try? c.decode(Int.self, forKey: .userID)
        userName = try? c.decode(String.self, forKey: .userName)
        courses = (try? c.decode([EdCourse].self, forKey: .courses)) ?? []
        marks = (try? c.decode([Int: EdThreadMark].self, forKey: .marks)) ?? [:]
        baselined = (try? c.decode(Set<Int>.self, forKey: .baselined)) ?? []
        items = (try? c.decode([EdItem].self, forKey: .items)) ?? []
        lastSync = try? c.decode(Date.self, forKey: .lastSync)
        deadlineKeys = (try? c.decode(Set<String>.self, forKey: .deadlineKeys)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(userID, forKey: .userID)
        try c.encodeIfPresent(userName, forKey: .userName)
        try c.encode(courses, forKey: .courses)
        try c.encode(marks, forKey: .marks)
        try c.encode(baselined, forKey: .baselined)
        try c.encode(items, forKey: .items)
        try c.encodeIfPresent(lastSync, forKey: .lastSync)
        try c.encode(deadlineKeys, forKey: .deadlineKeys)
    }

    /// Adds items not seen before (newest first) and returns them.
    @discardableResult
    public mutating func add(_ new: [EdItem]) -> [EdItem] {
        let known = Set(items.map(\.id))
        var fresh: [EdItem] = []
        for item in new where !known.contains(item.id) && !fresh.contains(where: { $0.id == item.id }) { fresh.append(item) }
        items = Array((items + fresh).sorted { $0.date > $1.date }.prefix(limit))
        return fresh
    }

    public func recent(since: Date? = nil, moduleCode: String? = nil, limit: Int = 40) -> [EdItem] {
        Array(items.filter { item in
            (since.map { item.date >= $0 } ?? true)
                && (moduleCode.map { item.moduleCode == $0 || item.courseCode.uppercased().contains($0) } ?? true)
        }.prefix(limit))
    }
}

/// Turns thread lists into Ed items. Pure.
public enum EdSync {
    /// Processes one course's newest threads. The first time a course is seen it
    /// is baselined: threads from the last `baselineDays` go in the feed, nothing notifies.
    public static func process(course: EdCourse, response: EdThreadsResponse, state: inout EdState,
                               region: EdRegion = .default, now: Date = Date(), baselineDays: Double = 14) -> [EdItem] {
        let users = Dictionary((response.users ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let firstRun = !state.baselined.contains(course.id)
        let me = state.userID
        var out: [EdItem] = []
        for t in response.threads {
            let author = t.user ?? t.userId.flatMap { users[$0] }
            let importance = EdImportance.classify(t, author: author)
            let date = t.created ?? now
            let mark = state.marks[t.id]
            let replies = t.replyCount ?? 0
            let pinned = t.isPinned ?? false
            func item(_ kind: EdItem.Kind, id: String, date: Date, importance: EdImportance, baseline: Bool) -> EdItem {
                EdItem(id: id, kind: kind, courseID: course.id, courseCode: course.code, moduleCode: course.moduleCode,
                       threadID: t.id, title: t.title, category: t.category,
                       author: t.isAnonymous == true ? nil : author?.name, authorIsStaff: author?.isStaff ?? false,
                       text: String(t.text.prefix(4000)), date: date, url: region.threadURL(courseID: course.id, threadID: t.id),
                       importance: importance, baseline: baseline)
            }
            let newKind: EdItem.Kind = t.isAnnouncement ? .announcement : (author?.isStaff ?? false) ? .staffPost
                : pinned ? .pinned : .newThread

            if firstRun {
                if now.timeIntervalSince(date) <= baselineDays * 86400 || pinned {
                    out.append(item(newKind, id: "ed-thread-\(t.id)", date: date, importance: importance, baseline: true))
                }
            } else if mark == nil {
                out.append(item(newKind, id: "ed-thread-\(t.id)", date: date, importance: importance, baseline: false))
            } else if let mark {
                if pinned && !mark.pinned {
                    var imp = importance
                    imp.level = .high
                    out.append(item(.pinned, id: "ed-pinned-\(t.id)", date: t.updated ?? now, importance: imp, baseline: false))
                }
                let mine = me != nil && t.userId == me
                if replies > mark.replyCount && (mine || t.isWatched == true) {
                    let n = replies - mark.replyCount
                    var imp = EdImportance(level: .high, reasons: [mine ? "reply to your thread" : "reply on a thread you watch"])
                    if t.isStaffAnswered == true { imp.reasons.append("staff answered") }
                    var reply = item(.reply, id: "ed-reply-\(t.id)-\(replies)", date: t.updated ?? now, importance: imp, baseline: false)
                    reply.text = "\(n) new repl\(n == 1 ? "y" : "ies")."
                    out.append(reply)
                }
            }
            state.marks[t.id] = EdThreadMark(replyCount: replies, pinned: pinned, updatedAt: t.updatedAt)
        }
        state.baselined.insert(course.id)
        return out
    }

    /// Future dates mentioned next to deadline words in a staff/important post
    /// ("Problem Set 2 is due Friday 10 October at 12:00").
    public static func deadlineMentions(in item: EdItem, extractor: DateExtractor, horizonDays: Double = 150) -> [DateMatch] {
        guard item.importance.isImportant, item.kind != .reply else { return [] }
        let text = item.title + ". " + item.text
        let cues = ["due", "deadline", "submit", "submission", "by ", "hand in", "closes", "exam", "quiz", "test", "assessment"]
        let now = extractor.now
        return extractor.extract(from: text).filter { m in
            guard m.date > now, m.date < now.addingTimeInterval(horizonDays * 86400) else { return false }
            // Look for a cue in the same sentence.
            let sentence = sentenceAround(m.range, in: text).lowercased()
            return cues.contains { sentence.contains($0) }
        }
    }

    static func sentenceAround(_ range: Range<String.Index>, in text: String) -> String {
        let stops: Set<Character> = [".", "!", "?", "\n"]
        var start = range.lowerBound
        while start > text.startIndex {
            let prev = text.index(before: start)
            if stops.contains(text[prev]) { break }
            start = prev
        }
        var end = range.upperBound
        while end < text.endIndex, !stops.contains(text[end]) { end = text.index(after: end) }
        return String(text[start..<end])
    }

    // MARK: Conversions

    /// For the ELE activity feed (one feed for "what's new").
    public static func activityItem(_ item: EdItem) -> ELEActivityItem {
        let kind: ELEActivityItem.Kind = item.kind == .announcement ? .announcement : .forumPost
        let detail = [item.author, item.snippet.isEmpty ? nil : item.snippet].compactMap { $0 }.joined(separator: ": ")
        return ELEActivityItem(id: item.id, kind: kind, moduleCode: item.moduleCode,
                               title: "Ed · " + (item.kind == .reply ? "New reply: " : "") + item.title,
                               detail: detail, date: item.date, url: item.url,
                               important: item.importance.isImportant && !item.baseline)
    }

    /// Staff posts, announcements and pinned threads go into the knowledge base
    /// so "Ask Orbit" can quote them.
    public static func document(_ item: EdItem) -> CourseDocument? {
        guard item.kind != .reply, item.authorIsStaff || item.kind == .announcement || item.kind == .pinned
            || item.importance.isImportant, !item.text.isEmpty else { return nil }
        let header = "Ed Discussion post in \(item.courseCode)\(item.category.map { " (\($0))" } ?? "")"
            + (item.author.map { " by \($0)" } ?? "") + "."
        return CourseDocument(id: "ed-\(item.threadID)", moduleCode: item.moduleCode, week: nil, kind: .announcement,
                              title: "Ed: \(item.title)", section: item.category, url: item.url,
                              text: header + "\n\n" + item.text, modified: item.date)
    }

    /// Plain text for the assistant.
    public static func text(_ items: [EdItem], timeZone: TimeZone) -> String {
        guard !items.isEmpty else { return "Nothing new on Ed in that time." }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = timeZone
        f.dateFormat = "EEE d MMM HH:mm"
        return items.map { i in
            var s = "\(f.string(from: i.date)) \(i.line)"
            if i.importance.isImportant { s += " [important: \(i.importance.reasons.joined(separator: "; "))]" }
            if !i.snippet.isEmpty && i.kind != .reply { s += "\n  " + i.snippet }
            return s
        }.joined(separator: "\n")
    }
}
