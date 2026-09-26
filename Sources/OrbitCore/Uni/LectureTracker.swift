import Foundation

/// A timetabled teaching session matched to its ELE slides and the student's notes.
public struct TrackedLecture: Codable, Hashable, Sendable, Identifiable {
    public enum SessionKind: String, Codable, Sendable, CaseIterable {
        case lecture, tutorial, seminar, workshop, practical, other
    }

    public enum Status: String, Codable, Sendable {
        /// Hasn't happened yet.
        case upcoming
        /// Notes found and they look complete.
        case notesTaken
        /// Happened, no notes found.
        case noNotes
        /// Notes found but thin, or they miss a lot of the slides.
        case notesIncomplete
    }

    /// "<event id>@<start>" (recurring events share an id).
    public var id: String
    public var eventID: String
    public var moduleCode: String
    public var kind: SessionKind
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String?
    public var term: Int?
    public var week: Int?
    /// ELE slide decks for that module and week.
    public var slideDocumentIDs: [String]
    public var slideTitles: [String]
    public var noteIDs: [String]
    public var status: Status
}

/// Works out which lectures have happened (from the timetable) and matches each to
/// that week's ELE slides and the notes taken for it.
public struct LectureTracker: Sendable {
    public var calendar: AcademicCalendar
    public var modules: [CourseModuleInfo]
    public var events: [CalendarEvent]
    public var notes: [LectureNote]
    public var slides: [CourseDocumentInfo]
    /// Slide coverage from `NotesReview` (lecture id → 0…1), when known.
    public var coverage: [String: Double]
    public var now: Date
    /// Notes with less text than this count as incomplete.
    public var minimumNoteCharacters: Int

    public init(calendar: AcademicCalendar = .exeter, modules: [CourseModuleInfo] = [], events: [CalendarEvent],
                notes: [LectureNote], slides: [CourseDocumentInfo] = [], coverage: [String: Double] = [:],
                now: Date = Date(), minimumNoteCharacters: Int = 300) {
        self.calendar = calendar; self.modules = modules; self.events = events; self.notes = notes
        self.slides = slides; self.coverage = coverage; self.now = now; self.minimumNoteCharacters = minimumNoteCharacters
    }

    /// Uses the knowledge base's modules, timetable, slides and notes.
    public init(knowledge kb: CourseKnowledgeBase, notes: [LectureNote], coverage: [String: Double] = [:], now: Date = Date()) {
        self.init(calendar: kb.calendar, modules: Array(kb.modules.values), events: kb.timetable, notes: notes,
                  slides: kb.documents(kinds: [.slides]).map(\.info), coverage: coverage, now: now)
    }

    // MARK: Classifying events

    /// The module an event belongs to: a code in its title/notes, else a module name in the title.
    public static func moduleCode(of event: CalendarEvent, modules: [CourseModuleInfo]) -> String? {
        if let code = ModuleCode.find(in: event.title.uppercased()) ?? NoteMetadataDetector.moduleCode(in: [event.title, event.notes]) {
            if modules.isEmpty || modules.contains(where: { $0.code == code }) { return code }
        }
        let title = event.title.lowercased()
        return modules.filter { $0.name.count >= 6 && title.contains($0.name.lowercased()) }
            .max { $0.name.count < $1.name.count }?.code
    }

    public static func sessionKind(_ title: String) -> TrackedLecture.SessionKind {
        let t = title.lowercased()
        if UniRegex.first("\\b(lecture|lec)\\b", in: t) != nil { return .lecture }
        if UniRegex.first("\\b(tutorial|tut)\\b", in: t) != nil { return .tutorial }
        if UniRegex.first("\\bseminar\\b", in: t) != nil { return .seminar }
        if UniRegex.first("\\b(workshop|problem class|drop-?in)\\b", in: t) != nil { return .workshop }
        if UniRegex.first("\\b(practical|lab|computer class)\\b", in: t) != nil { return .practical }
        return .other
    }

    // MARK: Sessions

    /// Every teaching session for a module (or all), optionally since a date, oldest first.
    public func sessions(module: String? = nil, since: Date? = nil, kinds: Set<TrackedLecture.SessionKind>? = nil,
                         includeUpcoming: Bool = true) -> [TrackedLecture] {
        var out: [TrackedLecture] = []
        var seen = Set<String>()
        for e in events.sorted(by: { $0.start < $1.start }) where !e.isAllDay {
            guard let code = Self.moduleCode(of: e, modules: modules) else { continue }
            if let module, code.caseInsensitiveCompare(module) != .orderedSame { continue }
            if let since, e.start < since { continue }
            var kind = Self.sessionKind(e.title)
            // A timetabled module session with no type is almost always a lecture.
            if kind == .other { kind = .lecture }
            if let kinds, !kinds.contains(kind) { continue }
            if !includeUpcoming && e.end > now { continue }
            let id = "\(e.id)@\(Int(e.start.timeIntervalSince1970))"
            guard seen.insert(id).inserted else { continue }
            let aw = calendar.week(for: e.start)
            let moduleTerm = modules.first { $0.code == code }?.term
            let week = (moduleTerm == nil || moduleTerm == aw?.term) ? aw?.week : nil
            let deck = week.map { w in slides.filter { $0.moduleCode == code && $0.week == w } } ?? []
            let matched = matchNotes(code: code, week: week, start: e.start)
            let status: TrackedLecture.Status
            if e.end > now { status = .upcoming }
            else if matched.isEmpty { status = .noNotes }
            else {
                let chars = matched.reduce(0) { $0 + $1.allText.count }
                let covered = coverage[id] ?? 1
                status = chars < minimumNoteCharacters || covered < 0.5 ? .notesIncomplete : .notesTaken
            }
            out.append(TrackedLecture(id: id, eventID: e.id, moduleCode: code, kind: kind, title: e.title, start: e.start,
                                      end: e.end, location: e.location, term: aw?.term, week: week,
                                      slideDocumentIDs: deck.map(\.id), slideTitles: deck.map(\.title),
                                      noteIDs: matched.map(\.id), status: status))
        }
        return out
    }

    /// Lectures that have happened (per module, since a date), with their note status.
    public func lectures(module: String? = nil, since: Date? = nil) -> [TrackedLecture] {
        sessions(module: module, since: since, kinds: [.lecture], includeUpcoming: false)
    }

    /// Notes for a module's session: tagged with its week, or written that day or within two days after.
    func matchNotes(code: String, week: Int?, start: Date) -> [LectureNote] {
        let day = calendar.dayCalendar.startOfDay(start)
        let windowEnd = calendar.dayCalendar.addingDays(3, to: day)
        return notes.filter { n in
            guard n.moduleCode?.caseInsensitiveCompare(code) == .orderedSame else { return false }
            if let w = week, let nw = n.week { return nw == w }
            return n.created >= day && n.created < windowEnd
        }
    }
}
