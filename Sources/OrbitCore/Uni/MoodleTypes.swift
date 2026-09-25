import Foundation

// Typed views of Moodle web-service responses, read leniently from MoodleJSON.
// They are close to the wire; ELEMapping turns them into Orbit models.

public struct MoodleSiteInfo: Hashable, Sendable {
    public var userID: Int
    public var fullName: String
    public var username: String?
    public var siteName: String
    public var siteURL: String?
    public var release: String?
    /// Web-service functions this token may call. Empty if the site didn't say.
    public var functions: Set<String>

    init(json j: MoodleJSON) {
        userID = j["userid"].int ?? 0
        fullName = j["fullname"].string ?? [j["firstname"].string, j["lastname"].string].compactMap { $0 }.joined(separator: " ")
        username = j["username"].string
        siteName = UniHTML.text(j["sitename"].string ?? "")
        siteURL = j["siteurl"].string
        release = j["release"].string
        functions = Set(j["functions"].array.compactMap { $0["name"].string })
    }

    public func allows(_ function: String) -> Bool { functions.isEmpty || functions.contains(function) }
}

public struct MoodleCourse: Identifiable, Hashable, Sendable {
    public var id: Int
    public var shortName: String
    public var fullName: String
    public var startDate: Date?
    public var endDate: Date?
    public var hidden: Bool
    public var lastAccess: Date?

    public init(id: Int, shortName: String, fullName: String, startDate: Date? = nil, endDate: Date? = nil,
                hidden: Bool = false, lastAccess: Date? = nil) {
        self.id = id; self.shortName = shortName; self.fullName = fullName; self.startDate = startDate
        self.endDate = endDate; self.hidden = hidden; self.lastAccess = lastAccess
    }

    init(json j: MoodleJSON) {
        self.init(id: j["id"].int ?? 0, shortName: UniHTML.decodeEntities(j["shortname"].string ?? ""),
                  fullName: UniHTML.decodeEntities(j["fullname"].string ?? j["displayname"].string ?? ""),
                  startDate: j["startdate"].date, endDate: j["enddate"].date,
                  hidden: j["hidden"].bool ?? (j["visible"].bool.map { !$0 } ?? false), lastAccess: j["lastaccess"].date)
    }

    /// Module code from the short name, then the full name.
    public var moduleCode: String? { ModuleCode.find(in: shortName) ?? ModuleCode.find(in: fullName) }
    /// Code if found, otherwise the short name, so every course has a stable key.
    public var moduleKey: String { moduleCode ?? shortName }
    public var moduleName: String { ModuleCode.name(from: fullName, code: moduleCode) }
}

public struct MoodleContentFile: Hashable, Sendable {
    public var type: String
    public var fileName: String
    public var fileURL: String?
    public var mimeType: String?
    public var timeModified: Date?

    init(json j: MoodleJSON) {
        type = j["type"].string ?? "file"
        fileName = j["filename"].string ?? ""
        fileURL = j["fileurl"].string
        mimeType = j["mimetype"].string
        timeModified = j["timemodified"].date
    }
}

/// An activity or resource on a course page ("course module").
public struct MoodleCourseModule: Identifiable, Hashable, Sendable {
    /// Course-module id (cmid), used in /mod/<name>/view.php?id=…
    public var id: Int
    /// Id of the activity itself (assignment id, quiz id, …).
    public var instance: Int?
    public var name: String
    /// "resource", "page", "url", "folder", "assign", "quiz", "forum", "lti", …
    public var modName: String
    public var url: String?
    public var description: String?
    public var visible: Bool
    public var contents: [MoodleContentFile]

    init(json j: MoodleJSON) {
        id = j["id"].int ?? 0
        instance = j["instance"].int
        name = UniHTML.decodeEntities(j["name"].string ?? "")
        modName = j["modname"].string ?? ""
        url = j["url"].string
        description = j["description"].string.map(UniHTML.text)
        visible = j["uservisible"].bool ?? j["visible"].bool ?? true
        contents = j["contents"].array.map(MoodleContentFile.init(json:))
    }

    /// Where a `url` module points.
    public var externalURL: String? {
        modName == "url" ? contents.first(where: { $0.type == "url" })?.fileURL ?? contents.first?.fileURL : nil
    }

    /// Looks like a Talis Aspire reading list link.
    public var isReadingList: Bool {
        if name.lowercased().contains("reading list") { return true }
        return [externalURL, url].compactMap { $0?.lowercased() }.contains { $0.contains("rl.talis.com") }
    }

    public var latestModified: Date? { contents.compactMap(\.timeModified).max() }
}

public struct MoodleSection: Identifiable, Hashable, Sendable {
    public var id: Int
    public var number: Int
    public var name: String
    public var summary: String
    public var modules: [MoodleCourseModule]

    init(json j: MoodleJSON) {
        id = j["id"].int ?? 0
        number = j["section"].int ?? 0
        name = UniHTML.decodeEntities(j["name"].string ?? "")
        summary = UniHTML.text(j["summary"].string ?? "")
        modules = j["modules"].array.map(MoodleCourseModule.init(json:))
    }
}

public struct MoodleAssignment: Identifiable, Hashable, Sendable {
    public var id: Int
    public var cmid: Int
    public var courseID: Int
    public var name: String
    public var dueDate: Date?
    public var cutoffDate: Date?
    public var allowSubmissionsFrom: Date?
    public var introHTML: String
    /// Maximum grade (usually 100). Negative values are scales.
    public var maxGrade: Double?
    public var teamSubmission: Bool

    init(json j: MoodleJSON, courseID: Int?) {
        id = j["id"].int ?? 0
        cmid = j["cmid"].int ?? 0
        self.courseID = j["course"].int ?? courseID ?? 0
        name = UniHTML.decodeEntities(j["name"].string ?? "")
        dueDate = j["duedate"].date
        cutoffDate = j["cutoffdate"].date
        allowSubmissionsFrom = j["allowsubmissionsfromdate"].date
        introHTML = j["intro"].string ?? ""
        maxGrade = j["grade"].double
        teamSubmission = j["teamsubmission"].bool ?? false
    }

    public var introText: String { UniHTML.text(introHTML) }
}

public struct MoodleSubmissionStatus: Hashable, Sendable {
    /// "new", "draft", "submitted", "reopened".
    public var status: String?
    public var graded: Bool
    /// Raw grade (on the assignment's scale), if released.
    public var grade: Double?
    public var extensionDueDate: Date?

    public var submitted: Bool { status == "submitted" }

    init(json j: MoodleJSON) {
        let attempt = j["lastattempt"]
        let submission = attempt["submission"].isNull ? attempt["teamsubmission"] : attempt["submission"]
        status = submission["status"].string
        graded = attempt["graded"].bool ?? (attempt["gradingstatus"].string == "graded")
        grade = j["feedback"]["grade"]["grade"].double
        extensionDueDate = attempt["extensionduedate"].date
    }
}

public struct MoodleQuiz: Identifiable, Hashable, Sendable {
    public var id: Int
    public var cmid: Int
    public var courseID: Int
    public var name: String
    public var introHTML: String
    public var timeOpen: Date?
    public var timeClose: Date?
    public var timeLimitMinutes: Int?
    public var maxGrade: Double?

    init(json j: MoodleJSON) {
        id = j["id"].int ?? 0
        cmid = j["coursemodule"].int ?? 0
        courseID = j["course"].int ?? 0
        name = UniHTML.decodeEntities(j["name"].string ?? "")
        introHTML = j["intro"].string ?? ""
        timeOpen = j["timeopen"].date
        timeClose = j["timeclose"].date
        timeLimitMinutes = j["timelimit"].int.flatMap { $0 > 0 ? $0 / 60 : nil }
        maxGrade = j["grade"].double
    }
}

/// An item on the ELE timeline ("action events"): things you need to do.
public struct MoodleActionEvent: Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var activityName: String?
    public var courseID: Int?
    public var courseShortName: String?
    public var courseFullName: String?
    /// Activity type, e.g. "assign", "quiz", "turnitintooltwo".
    public var moduleName: String?
    public var instance: Int?
    public var eventType: String?
    public var time: Date
    public var url: String?
    public var actionable: Bool

    init(json j: MoodleJSON) {
        id = j["id"].int ?? 0
        name = UniHTML.decodeEntities(j["name"].string ?? "")
        activityName = j["activityname"].string.map(UniHTML.decodeEntities)
        courseID = j["course"]["id"].int ?? j["courseid"].int
        courseShortName = j["course"]["shortname"].string
        courseFullName = j["course"]["fullname"].string
        moduleName = j["modulename"].string
        instance = j["instance"].int
        eventType = j["eventtype"].string
        time = j["timesort"].date ?? j["timestart"].date ?? Date(timeIntervalSince1970: 0)
        url = j["url"].string ?? j["action"]["url"].string
        actionable = j["action"]["actionable"].bool ?? true
    }
}

public struct MoodleGradeItem: Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String
    /// "mod", "course", "category", "manual".
    public var itemType: String
    public var itemModule: String?
    public var itemInstance: Int?
    public var cmid: Int?
    /// Weight within the course total, 0–1.
    public var weight: Double?
    public var rawGrade: Double?
    public var gradeMin: Double
    public var gradeMax: Double
    public var gradedAt: Date?
    public var hidden: Bool
    public var feedback: String?

    init(json j: MoodleJSON) {
        id = j["id"].int ?? 0
        itemType = j["itemtype"].string ?? ""
        name = UniHTML.decodeEntities(j["itemname"].string ?? (itemType == "course" ? "Course total" : ""))
        itemModule = j["itemmodule"].string
        itemInstance = j["iteminstance"].int
        cmid = j["cmid"].int
        weight = j["weightraw"].double
        rawGrade = j["graderaw"].double
        gradeMin = j["grademin"].double ?? 0
        gradeMax = j["grademax"].double ?? 100
        gradedAt = j["gradedategraded"].date
        hidden = j["gradeishidden"].bool ?? false
        feedback = j["feedback"].string.map(UniHTML.text).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Grade as a percentage of the range, if released.
    public var percent: Double? {
        guard let raw = rawGrade, !hidden, gradeMax > gradeMin else { return nil }
        return (raw - gradeMin) / (gradeMax - gradeMin) * 100
    }
}

public struct MoodleForum: Identifiable, Hashable, Sendable {
    public var id: Int
    public var courseID: Int
    public var cmid: Int?
    /// "news" is the course Announcements forum.
    public var type: String
    public var name: String

    init(json j: MoodleJSON) {
        id = j["id"].int ?? 0
        courseID = j["course"].int ?? 0
        cmid = j["cmid"].int
        type = j["type"].string ?? "general"
        name = UniHTML.decodeEntities(j["name"].string ?? "")
    }

    public var isAnnouncements: Bool { type == "news" || name.lowercased().contains("announcement") }
}

public struct MoodleDiscussion: Identifiable, Hashable, Sendable {
    /// Discussion id (for discuss.php?d=…).
    public var id: Int
    public var subject: String
    public var messageHTML: String
    public var author: String?
    public var created: Date?
    public var modified: Date?
    public var pinned: Bool

    init(json j: MoodleJSON) {
        id = j["discussion"].int ?? j["id"].int ?? 0
        subject = UniHTML.decodeEntities(j["subject"].string ?? j["name"].string ?? "")
        messageHTML = j["message"].string ?? ""
        author = j["userfullname"].string
        created = j["created"].date ?? j["timemodified"].date
        modified = j["modified"].date ?? j["timemodified"].date
        pinned = j["pinned"].bool ?? false
    }
}

public struct MoodleCourseUpdate: Hashable, Sendable {
    /// "module" or "section"-level context.
    public var contextLevel: String
    /// Course-module id when `contextLevel` is "module".
    public var id: Int
    /// What changed, e.g. ["configuration", "fileareas", "gradeitems"].
    public var areas: [String]
    public var lastChange: Date?

    init(json j: MoodleJSON) {
        contextLevel = j["contextlevel"].string ?? ""
        id = j["id"].int ?? 0
        areas = j["updates"].array.compactMap { $0["name"].string }
        lastChange = j["updates"].array.compactMap { $0["timeupdated"].date }.max()
    }
}
