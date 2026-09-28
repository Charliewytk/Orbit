import Foundation

/// One module's course page as read from the ELE website.
public struct ELEWebCourseContent: Codable, Hashable, Sendable {
    public var courseID: Int
    public var moduleCode: String
    public var sections: [ELEWebSection]
    public var weeks: [ELEModuleWeek]
    public var readings: [ReadingItem]

    public init(courseID: Int, moduleCode: String, sections: [ELEWebSection]) {
        self.courseID = courseID; self.moduleCode = moduleCode; self.sections = sections
        weeks = ELEWebParser.weeks(from: sections)
        readings = ELEWebParser.readings(from: sections, moduleCode: moduleCode)
    }

    public var assessmentSections: [ELEWebSection] { sections.filter { $0.kind == .assessment } }
    public var tutorials: [(week: Int, topic: String)] { weeks.flatMap { w in w.tutorials.map { (w.week, $0) } } }
    public var pastPapers: [ELEWebItem] { sections.flatMap(\.items).filter { $0.role == .pastPaper } }
}

/// Everything read from the ELE website in one sync.
public struct ELEWebSnapshot: Codable, Hashable, Sendable {
    public var fetchedAt: Date
    /// Module courses (with a module code).
    public var modules: [ELEWebCourse]
    /// Info courses without a module code (BUS_*, UEBS_*, UNI_*…), treated as resources.
    public var resourceCourses: [ELEWebCourse]
    public var contents: [String: ELEWebCourseContent]
    public var assessments: [ELEWebAssessment]
    public var events: [ELEWebEvent]
    /// Extracted brief text by cmid, so briefs are downloaded once.
    public var briefTexts: [Int: String]
    public var warnings: [String]

    public init(fetchedAt: Date = Date(), modules: [ELEWebCourse] = [], resourceCourses: [ELEWebCourse] = [],
                contents: [String: ELEWebCourseContent] = [:], assessments: [ELEWebAssessment] = [],
                events: [ELEWebEvent] = [], briefTexts: [Int: String] = [:], warnings: [String] = []) {
        self.fetchedAt = fetchedAt; self.modules = modules; self.resourceCourses = resourceCourses
        self.contents = contents; self.assessments = assessments; self.events = events
        self.briefTexts = briefTexts; self.warnings = warnings
    }

    /// Splits dashboard courses into modules and resources.
    public static func split(_ courses: [ELEWebCourse]) -> (modules: [ELEWebCourse], resources: [ELEWebCourse]) {
        // Where a module has several ELE courses (e.g. two years), keep the latest academic year.
        var best: [String: ELEWebCourse] = [:]
        for c in courses {
            guard let code = c.moduleCode else { continue }
            if let prev = best[code], (prev.academicYearStart ?? 0) >= (c.academicYearStart ?? 0) { continue }
            best[code] = c
        }
        return (best.values.sorted { $0.moduleCode ?? "" < $1.moduleCode ?? "" }, courses.filter { !$0.isModule })
    }

    /// The same data in the shape the rest of Orbit uses (store, notifications, revision topics).
    public func eleSnapshot(credits: [String: Int] = [:], previous: ELESnapshot? = nil) -> ELESnapshot {
        var snap = ELESnapshot(fetchedAt: fetchedAt, siteName: "ELE")
        snap.modules = modules.compactMap { c in
            c.moduleCode.map { Module(code: $0, name: c.name, credits: credits[$0] ?? 15, eleCourseID: c.id) }
        }
        snap.assessments = assessments.map(\.assessment).sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        for (code, content) in contents.sorted(by: { $0.key < $1.key }) {
            snap.resources += ELEWebParser.resources(from: content.sections, courseID: content.courseID, moduleCode: code)
            snap.readingItems += content.readings
            snap.sectionTopics[code] = content.weeks.map { w in
                let topic = w.title.replacingOccurrences(of: "^\\s*week\\s*\\d+\\s*(?:w\\s*/\\s*c[^:–-]*)?[:–-]?\\s*",
                                                         with: "", options: [.regularExpression, .caseInsensitive])
                return topic.isEmpty ? (w.tutorials.first ?? w.title) : topic
            }
            let lists = content.sections.flatMap(\.items).filter { $0.role == .readingList }.compactMap(\.url)
            if !lists.isEmpty { snap.readingListURLs[code] = lists }
        }
        let done = Set((previous?.readingItems ?? []).filter(\.done).map(\.id))
        for i in snap.readingItems.indices where done.contains(snap.readingItems[i].id) { snap.readingItems[i].done = true }
        snap.warnings = warnings
        return snap
    }
}

/// What changed on the ELE website since last time.
public struct ELEWebChanges: Hashable, Sendable {
    public struct WeekUpdate: Hashable, Sendable {
        public var moduleCode: String
        public var week: Int
        public var title: String
    }

    /// New assessments, moved deadlines and new files (existing diff).
    public var base: ELEChanges
    /// Assessments whose weight, word count or title changed.
    public var changedAssessments: [ELEWebAssessment]
    /// Weeks that appeared or got new content.
    public var updatedWeeks: [WeekUpdate]

    public var isInitial: Bool { base.isInitial }
    public var isEmpty: Bool { base.isEmpty && changedAssessments.isEmpty && updatedWeeks.isEmpty }

    public static func diff(from old: ELEWebSnapshot?, to new: ELEWebSnapshot) -> ELEWebChanges {
        let base = ELEChanges.diff(from: old?.eleSnapshot(), to: new.eleSnapshot())
        let oldByID = Dictionary((old?.assessments ?? []).map { ($0.assessment.id, $0) }, uniquingKeysWith: { a, _ in a })
        let changed = new.assessments.filter { a in
            guard let o = oldByID[a.assessment.id] else { return false }
            return o.assessment.weightPercent != a.assessment.weightPercent || o.assessment.wordCount != a.assessment.wordCount
                || o.assessment.title != a.assessment.title
        }
        var weeks: [WeekUpdate] = []
        if let old {
            for (code, content) in new.contents {
                let before = Dictionary((old.contents[code]?.weeks ?? []).map { ($0.week, $0.contentKey) }, uniquingKeysWith: { a, _ in a })
                guard old.contents[code] != nil else { continue }
                for w in content.weeks where !w.isEmpty && before[w.week] != w.contentKey {
                    weeks.append(WeekUpdate(moduleCode: code, week: w.week, title: w.title))
                }
            }
        }
        return ELEWebChanges(base: base, changedAssessments: changed,
                             updatedWeeks: weeks.sorted { ($0.moduleCode, $0.week) < ($1.moduleCode, $1.week) })
    }
}
