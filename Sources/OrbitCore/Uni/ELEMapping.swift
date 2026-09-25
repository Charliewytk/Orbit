import Foundation

/// A post in a course's Announcements forum.
public struct ELEAnnouncement: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var moduleCode: String
    public var courseID: Int
    public var subject: String
    /// Plain text of the post.
    public var message: String
    public var author: String?
    public var posted: Date?
    public var url: String?
    public var pinned: Bool

    public init(id: String, moduleCode: String, courseID: Int, subject: String, message: String,
                author: String? = nil, posted: Date? = nil, url: String? = nil, pinned: Bool = false) {
        self.id = id; self.moduleCode = moduleCode; self.courseID = courseID; self.subject = subject
        self.message = message; self.author = author; self.posted = posted; self.url = url; self.pinned = pinned
    }
}

/// Learning material on a course page: files, pages, links, folders, reading lists.
public struct ELEResource: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, page, link, folder, book, readingList, other }

    public var id: String
    public var moduleCode: String
    public var courseID: Int
    public var cmid: Int
    /// Course section name, e.g. "Week 3: Regression".
    public var section: String
    public var name: String
    public var kind: Kind
    /// The ELE page for it.
    public var url: String?
    /// Where a link points, or the first file's download URL (needs the token added).
    public var targetURL: String?
    public var modified: Date?

    public init(id: String, moduleCode: String, courseID: Int, cmid: Int, section: String, name: String,
                kind: Kind, url: String? = nil, targetURL: String? = nil, modified: Date? = nil) {
        self.id = id; self.moduleCode = moduleCode; self.courseID = courseID; self.cmid = cmid
        self.section = section; self.name = name; self.kind = kind; self.url = url
        self.targetURL = targetURL; self.modified = modified
    }
}

/// A released mark from the ELE gradebook.
public struct ELEGrade: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var moduleCode: String
    public var itemName: String
    /// 0–100.
    public var percent: Double
    /// Share of the module total in the gradebook (0–100), if set.
    public var weightPercent: Double?
    /// The Orbit assessment this mark belongs to, if matched.
    public var assessmentID: String?
    /// True for the module's overall total.
    public var isCourseTotal: Bool
    public var gradedAt: Date?
    public var feedback: String?

    public init(id: String, moduleCode: String, itemName: String, percent: Double, weightPercent: Double? = nil,
                assessmentID: String? = nil, isCourseTotal: Bool = false, gradedAt: Date? = nil, feedback: String? = nil) {
        self.id = id; self.moduleCode = moduleCode; self.itemName = itemName; self.percent = percent
        self.weightPercent = weightPercent; self.assessmentID = assessmentID; self.isCourseTotal = isCourseTotal
        self.gradedAt = gradedAt; self.feedback = feedback
    }
}

/// Converts Moodle records into Orbit's models.
public enum ELEMapping {
    public static func module(_ course: MoodleCourse, credits: Int = 15) -> Module {
        Module(code: course.moduleKey, name: course.moduleName, credits: credits, eleCourseID: course.id)
    }

    public static func assessmentID(module: String, instance: Int) -> String { "ele-\(module)-\(instance)" }

    public static func assessment(_ a: MoodleAssignment, moduleCode: String, status: MoodleSubmissionStatus? = nil,
                                  siteURL: String) -> Assessment {
        let intro = a.introText
        var mark: Double?
        if let g = status?.grade, let max = a.maxGrade, max > 0 { mark = g / max * 100 }
        return Assessment(
            id: assessmentID(module: "assign", instance: a.id), moduleCode: moduleCode, title: a.name,
            kind: AssessmentParsing.kind(title: a.name, brief: intro),
            weightPercent: AssessmentParsing.weightFromTitle(a.name) ?? AssessmentParsing.weightPercent(in: intro) ?? 0,
            due: status?.extensionDueDate ?? a.dueDate ?? a.cutoffDate,
            wordCount: AssessmentParsing.wordCount(in: a.name) ?? AssessmentParsing.wordCount(in: intro),
            mark: mark, submitted: status?.submitted ?? false,
            eleURL: "\(siteURL)/mod/assign/view.php?id=\(a.cmid)")
    }

    public static func assessment(_ q: MoodleQuiz, moduleCode: String, siteURL: String) -> Assessment {
        let intro = UniHTML.text(q.introHTML)
        return Assessment(
            id: assessmentID(module: "quiz", instance: q.id), moduleCode: moduleCode, title: q.name, kind: .quiz,
            weightPercent: AssessmentParsing.weightFromTitle(q.name) ?? AssessmentParsing.weightPercent(in: intro) ?? 0,
            due: q.timeClose, eleURL: "\(siteURL)/mod/quiz/view.php?id=\(q.cmid)")
    }

    /// Timeline items for activities not covered by assign/quiz (e.g. Turnitin submissions).
    public static func assessment(_ e: MoodleActionEvent, moduleCode: String) -> Assessment {
        let title = e.activityName ?? cleanDeadlineTitle(e.name)
        return Assessment(
            id: assessmentID(module: e.moduleName ?? "event", instance: e.instance ?? e.id), moduleCode: moduleCode,
            title: title, kind: AssessmentParsing.kind(title: title),
            weightPercent: AssessmentParsing.weightFromTitle(title) ?? 0, due: e.time,
            wordCount: AssessmentParsing.wordCount(in: title), eleURL: e.url)
    }

    /// "Essay 1 is due" → "Essay 1". Also strips "closes", "due", "should be completed".
    public static func cleanDeadlineTitle(_ s: String) -> String {
        let cleaned = UniRegex.replace("\\s*(?:[-:–]\\s*)?(?:is due|are due|due(?: date)?|closes|deadline|should be completed|submission)\\s*$",
                                       in: s.trimmingCharacters(in: .whitespaces), with: "")
        return cleaned.isEmpty ? s : cleaned
    }

    public static func resource(_ m: MoodleCourseModule, section: MoodleSection, courseID: Int, moduleCode: String) -> ELEResource? {
        let kind: ELEResource.Kind
        if m.isReadingList { kind = .readingList } else {
            switch m.modName {
            case "resource": kind = .file
            case "page": kind = .page
            case "url": kind = .link
            case "folder": kind = .folder
            case "book": kind = .book
            case "lti", "label", "assign", "quiz", "forum", "turnitintooltwo", "choice", "feedback", "attendance": return nil
            default: kind = .other
            }
        }
        guard m.visible else { return nil }
        return ELEResource(id: "ele-cm-\(m.id)", moduleCode: moduleCode, courseID: courseID, cmid: m.id,
                           section: section.name, name: m.name, kind: kind, url: m.url,
                           targetURL: m.externalURL ?? m.contents.first?.fileURL, modified: m.latestModified)
    }

    public static func announcement(_ d: MoodleDiscussion, forum: MoodleForum, moduleCode: String, siteURL: String) -> ELEAnnouncement {
        ELEAnnouncement(id: "ele-post-\(d.id)", moduleCode: moduleCode, courseID: forum.courseID, subject: d.subject,
                        message: UniHTML.text(d.messageHTML), author: d.author, posted: d.created,
                        url: "\(siteURL)/mod/forum/discuss.php?d=\(d.id)", pinned: d.pinned)
    }

    public static func grade(_ item: MoodleGradeItem, courseID: Int, moduleCode: String) -> ELEGrade? {
        guard let percent = item.percent else { return nil }
        var assessmentID: String?
        if item.itemType == "mod", let mod = item.itemModule, let inst = item.itemInstance {
            assessmentID = Self.assessmentID(module: mod, instance: inst)
        }
        return ELEGrade(id: "ele-grade-\(courseID)-\(item.id)", moduleCode: moduleCode, itemName: item.name,
                        percent: (percent * 10).rounded() / 10, weightPercent: item.weight.map { $0 * 100 },
                        assessmentID: assessmentID, isCourseTotal: item.itemType == "course",
                        gradedAt: item.gradedAt, feedback: item.feedback)
    }
}
