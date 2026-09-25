import Foundation

/// Everything Orbit knows from ELE at one moment. Saved between syncs so the
/// next sync can report only what changed.
public struct ELESnapshot: Codable, Hashable, Sendable {
    public var fetchedAt: Date
    public var siteName: String
    public var userID: Int
    public var userFullName: String
    public var modules: [Module]
    public var assessments: [Assessment]
    public var resources: [ELEResource]
    public var announcements: [ELEAnnouncement]
    public var grades: [ELEGrade]
    public var readingItems: [ReadingItem]
    /// Talis list links found on each module's page, by module code.
    public var readingListURLs: [String: [String]]
    /// Topic names from course sections, by module code (for revision planning).
    public var sectionTopics: [String: [String]]
    /// Non-fatal problems (a function switched off, one course failing).
    public var warnings: [String]

    public init(fetchedAt: Date = Date(), siteName: String = "", userID: Int = 0, userFullName: String = "",
                modules: [Module] = [], assessments: [Assessment] = [], resources: [ELEResource] = [],
                announcements: [ELEAnnouncement] = [], grades: [ELEGrade] = [], readingItems: [ReadingItem] = [],
                readingListURLs: [String: [String]] = [:], sectionTopics: [String: [String]] = [:], warnings: [String] = []) {
        self.fetchedAt = fetchedAt; self.siteName = siteName; self.userID = userID; self.userFullName = userFullName
        self.modules = modules; self.assessments = assessments; self.resources = resources
        self.announcements = announcements; self.grades = grades; self.readingItems = readingItems
        self.readingListURLs = readingListURLs; self.sectionTopics = sectionTopics; self.warnings = warnings
    }
}

/// What changed since the previous snapshot: the things worth a notification.
public struct ELEChanges: Codable, Hashable, Sendable {
    public struct DeadlineChange: Codable, Hashable, Sendable {
        public var assessment: Assessment
        public var oldDue: Date?
        public var newDue: Date?
    }

    /// True when there was no previous snapshot (everything is "new"; don't notify).
    public var isInitial: Bool
    public var newAssessments: [Assessment]
    public var changedDeadlines: [DeadlineChange]
    public var newResources: [ELEResource]
    public var newAnnouncements: [ELEAnnouncement]
    public var newGrades: [ELEGrade]

    public var isEmpty: Bool {
        newAssessments.isEmpty && changedDeadlines.isEmpty && newResources.isEmpty && newAnnouncements.isEmpty && newGrades.isEmpty
    }

    public static func diff(from old: ELESnapshot?, to new: ELESnapshot) -> ELEChanges {
        let oldAssessments = Dictionary((old?.assessments ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let oldResources = Set((old?.resources ?? []).map(\.id))
        let oldPosts = Set((old?.announcements ?? []).map(\.id))
        let oldGrades = Dictionary((old?.grades ?? []).map { ($0.id, $0.percent) }, uniquingKeysWith: { a, _ in a })

        var changed: [DeadlineChange] = []
        var added: [Assessment] = []
        for a in new.assessments {
            guard let prev = oldAssessments[a.id] else { added.append(a); continue }
            let moved = switch (prev.due, a.due) {
            case (nil, nil): false
            case let (x?, y?): abs(x.timeIntervalSince(y)) > 60
            default: true
            }
            if moved { changed.append(DeadlineChange(assessment: a, oldDue: prev.due, newDue: a.due)) }
        }
        return ELEChanges(
            isInitial: old == nil, newAssessments: added, changedDeadlines: changed,
            newResources: new.resources.filter { !oldResources.contains($0.id) },
            newAnnouncements: new.announcements.filter { !oldPosts.contains($0.id) },
            newGrades: new.grades.filter { g in oldGrades[g.id].map { abs($0 - g.percent) > 0.05 } ?? true })
    }
}

/// Pulls everything useful from ELE into an `ELESnapshot` and reports changes.
/// Each part (grades, forums, contents…) fails softly into `warnings`, since
/// sites often switch individual web-service functions off.
public actor ELESync {
    public struct Options: Sendable {
        public var includeContents = true
        public var includeGrades = true
        public var includeAnnouncements = true
        /// One extra call per assignment; skipped for ones already known to be submitted.
        public var checkSubmissions = true
        /// Fetch Talis lists linked from course pages.
        public var fetchReadingLists = false
        public var announcementsPerCourse = 5
        /// Ignore courses that ended more than this long ago.
        public var finishedCourseGrace: TimeInterval = 45 * 86400
        /// Module credits you've set (ELE doesn't publish them). Default 15.
        public var creditsByModule: [String: Int] = [:]
        public init() {}
    }

    public let client: MoodleClient
    public let talis: TalisReadingList
    public var options: Options
    public private(set) var lastSnapshot: ELESnapshot?

    public init(client: MoodleClient, talis: TalisReadingList = TalisReadingList(), options: Options = Options(),
                lastSnapshot: ELESnapshot? = nil) {
        self.client = client; self.talis = talis; self.options = options; self.lastSnapshot = lastSnapshot
    }

    public func setOptions(_ o: Options) { options = o }

    /// Syncs and diffs against `previous` (or the last snapshot this actor made).
    public func sync(previous: ELESnapshot? = nil, now: Date = Date()) async throws -> (snapshot: ELESnapshot, changes: ELEChanges) {
        let before = previous ?? lastSnapshot
        let snapshot = try await fetchSnapshot(previous: before, now: now)
        lastSnapshot = snapshot
        return (snapshot, ELEChanges.diff(from: before, to: snapshot))
    }

    public func fetchSnapshot(previous: ELESnapshot? = nil, now: Date = Date()) async throws -> ELESnapshot {
        let site = client.siteURL.absoluteString
        let info = try await client.siteInfo()
        var warnings: [String] = []

        /// Runs one part, turning failures (other than an expired token) into warnings.
        func soft<T>(_ what: String, _ function: String, _ fallback: T, _ body: () async throws -> T) async throws -> T {
            guard info.allows(function) else { warnings.append("\(what): not enabled on ELE"); return fallback }
            do { return try await body() } catch let e as MoodleError where e.needsReauthentication { throw e }
            catch { warnings.append("\(what): \(error)"); return fallback }
        }

        let courses = try await client.courses(userID: info.userID).filter { c in
            !c.hidden && (c.endDate.map { $0 > now.addingTimeInterval(-options.finishedCourseGrace) } ?? true)
        }
        let byCourse = Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = courses.map(\.id)
        func code(_ courseID: Int?) -> String { courseID.flatMap { byCourse[$0]?.moduleKey } ?? "" }

        var snap = ELESnapshot(fetchedAt: now, siteName: info.siteName, userID: info.userID, userFullName: info.fullName)
        snap.modules = courses.map { ELEMapping.module($0, credits: options.creditsByModule[$0.moduleKey] ?? 15) }

        // Assignments, with submission state and any released mark.
        let previousByID = Dictionary((previous?.assessments ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let assigns = try await soft("Assignments", "mod_assign_get_assignments", []) { try await client.assignments(courseIDs: ids) }
        for a in assigns {
            var status: MoodleSubmissionStatus?
            let id = ELEMapping.assessmentID(module: "assign", instance: a.id)
            let known = previousByID[id]
            let relevant = a.dueDate.map { $0 > now.addingTimeInterval(-60 * 86400) } ?? true
            if options.checkSubmissions, relevant, !(known?.submitted ?? false) {
                status = try await soft("Submission for \(a.name)", "mod_assign_get_submission_status", nil) {
                    try await client.submissionStatus(assignID: a.id)
                }
            }
            var assessment = ELEMapping.assessment(a, moduleCode: code(a.courseID), status: status, siteURL: site)
            if status == nil, let known {
                assessment.submitted = known.submitted
                assessment.mark = assessment.mark ?? known.mark
            }
            snap.assessments.append(assessment)
        }

        let quizzes = try await soft("Quizzes", "mod_quiz_get_quizzes_by_courses", []) { try await client.quizzes(courseIDs: ids) }
        snap.assessments += quizzes.map { ELEMapping.assessment($0, moduleCode: code($0.courseID), siteURL: site) }

        // Timeline items for other activity types (e.g. Turnitin) that aren't already covered.
        let events = try await soft("Timeline", "core_calendar_get_action_events_by_timesort", []) {
            try await client.actionEvents(from: now.addingTimeInterval(-7 * 86400), limit: 50)
        }
        let covered = Set(snap.assessments.map(\.id))
        for e in events where !["assign", "quiz", "forum", "choice", "feedback"].contains(e.moduleName ?? "") {
            guard e.courseID.map({ byCourse[$0] != nil }) ?? false else { continue }
            let a = ELEMapping.assessment(e, moduleCode: code(e.courseID))
            if !covered.contains(a.id), !snap.assessments.contains(where: { $0.id == a.id }) { snap.assessments.append(a) }
        }

        for course in courses {
            let moduleCode = course.moduleKey
            if options.includeGrades {
                let items = try await soft("Grades for \(moduleCode)", "gradereport_user_get_grade_items", []) {
                    try await client.gradeItems(courseID: course.id, userID: info.userID)
                }
                for item in items {
                    guard let g = ELEMapping.grade(item, courseID: course.id, moduleCode: moduleCode) else {
                        applyGradebookWeight(item, to: &snap.assessments)
                        continue
                    }
                    snap.grades.append(g)
                    applyGradebookWeight(item, to: &snap.assessments)
                    if let aid = g.assessmentID, let i = snap.assessments.firstIndex(where: { $0.id == aid }) {
                        snap.assessments[i].mark = g.percent
                    }
                }
            }
            if options.includeContents {
                let sections = try await soft("Contents of \(moduleCode)", "core_course_get_contents", []) {
                    try await client.contents(courseID: course.id)
                }
                for section in sections {
                    for m in section.modules {
                        guard let r = ELEMapping.resource(m, section: section, courseID: course.id, moduleCode: moduleCode) else {
                            continue
                        }
                        snap.resources.append(r)
                        if r.kind == .readingList, let link = r.targetURL, TalisReadingList.isTalisURL(link) {
                            snap.readingListURLs[moduleCode, default: []].append(link)
                        }
                    }
                }
                snap.sectionTopics[moduleCode] = RevisionPlanner.topics(fromSections: sections.map(\.name))
            }
        }

        if options.includeAnnouncements {
            let forums = try await soft("Forums", "mod_forum_get_forums_by_courses", []) { try await client.forums(courseIDs: ids) }
            for forum in forums where forum.isAnnouncements {
                let posts = try await soft("Announcements for \(code(forum.courseID))", "mod_forum_get_forum_discussions", []) {
                    try await client.discussions(forumID: forum.id, perPage: options.announcementsPerCourse)
                }
                snap.announcements += posts.map {
                    ELEMapping.announcement($0, forum: forum, moduleCode: code(forum.courseID), siteURL: site)
                }
            }
            snap.announcements.sort { ($0.posted ?? .distantPast) > ($1.posted ?? .distantPast) }
        }

        if options.fetchReadingLists {
            for (moduleCode, links) in snap.readingListURLs {
                for link in Set(links) {
                    guard let url = URL(string: link) else { continue }
                    do { snap.readingItems += try await talis.fetch(listURL: url, moduleCode: moduleCode).map(\.item) }
                    catch { warnings.append("Reading list for \(moduleCode): \(error)") }
                }
            }
        }
        // Keep "done" ticks from last time.
        let doneIDs = Set((previous?.readingItems ?? []).filter(\.done).map(\.id))
        for i in snap.readingItems.indices where doneIDs.contains(snap.readingItems[i].id) { snap.readingItems[i].done = true }

        snap.assessments.sort { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        snap.warnings = warnings
        return snap
    }

    /// Uses the gradebook weight for assessments whose brief didn't state one.
    private func applyGradebookWeight(_ item: MoodleGradeItem, to assessments: inout [Assessment]) {
        guard item.itemType == "mod", let mod = item.itemModule, let inst = item.itemInstance,
              let w = item.weight, w > 0 else { return }
        let id = ELEMapping.assessmentID(module: mod, instance: inst)
        if let i = assessments.firstIndex(where: { $0.id == id }), assessments[i].weightPercent == 0 {
            assessments[i].weightPercent = (w * 1000).rounded() / 10
        }
    }
}
