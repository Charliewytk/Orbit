import Foundation

// Everything Orbit knows about the student's courses, indexed for retrieval:
// ELE pages and section text, every downloaded resource (slides, handouts,
// problem sheets, briefs, reading guides, past papers) with its text, lecture
// notes and reading lists — each tagged with module, term, week and kind.
// Full text stays on the Mac (Application Support); nothing here syncs.

public enum CourseDocKind: String, Codable, CaseIterable, Sendable {
    case elePage, slides, handout, homework, assessmentBrief, readingGuide, reading, readingList, pastPaper,
         exemplar, lectureNotes, recording, other

    public var label: String {
        switch self {
        case .elePage: "ELE page"
        case .slides: "slides"
        case .handout: "handout"
        case .homework: "homework"
        case .assessmentBrief: "assessment brief"
        case .readingGuide: "reading guide"
        case .reading: "reading"
        case .readingList: "reading list"
        case .pastPaper: "past paper"
        case .exemplar: "exemplar"
        case .lectureNotes: "your notes"
        case .recording: "recording"
        case .other: "resource"
        }
    }

    /// Kind of a downloadable ELE item.
    public static func from(role: ELEWebItem.Role, name: String) -> CourseDocKind {
        if HomeworkDetector.looksLikeHomework(name) && role != .pastPaper && role != .exemplar && role != .assessmentBrief {
            return .homework
        }
        switch role {
        case .slides: return .slides
        case .handout: return .handout
        case .reading: return .reading
        case .readingGuide: return .readingGuide
        case .readingList: return .readingList
        case .tutorial: return .homework
        case .recording: return .recording
        case .pastPaper: return .pastPaper
        case .exemplar: return .exemplar
        case .assessmentBrief, .submission: return .assessmentBrief
        case .other: return .other
        }
    }
}

/// A document without its text (for lists and citations).
public struct CourseDocumentInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var moduleCode: String?
    public var term: Int?
    public var week: Int?
    public var kind: CourseDocKind
    public var title: String
    public var section: String?
    public var url: String?
    public var characters: Int

    /// "BEE1022 · week 2 · Lecture 2 slides (slides)".
    public var citation: String {
        ([moduleCode, week.map { (term ?? 1) > 1 ? "T\(term!) week \($0)" : "week \($0)" }].compactMap { $0 } + ["\(title) (\(kind.label))"])
            .joined(separator: " · ")
    }
}

public struct CourseDocument: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var moduleCode: String?
    public var term: Int?
    public var week: Int?
    public var kind: CourseDocKind
    public var title: String
    /// ELE section title.
    public var section: String?
    public var url: String?
    public var cmid: Int?
    public var text: String
    public var modified: Date
    /// Changes when the text does (so unchanged documents keep their embeddings).
    public var contentHash: String

    public init(id: String, moduleCode: String?, term: Int? = nil, week: Int?, kind: CourseDocKind, title: String,
                section: String? = nil, url: String? = nil, cmid: Int? = nil, text: String, modified: Date = Date()) {
        self.id = id; self.moduleCode = moduleCode; self.term = term; self.week = week; self.kind = kind
        self.title = title; self.section = section; self.url = url; self.cmid = cmid; self.text = text
        self.modified = modified
        contentHash = MD5.hex("\(kind.rawValue)|\(moduleCode ?? "")|\(week ?? 0)|\(title)|\(text)")
    }

    public var info: CourseDocumentInfo {
        CourseDocumentInfo(id: id, moduleCode: moduleCode, term: term, week: week, kind: kind, title: title,
                           section: section, url: url, characters: text.count)
    }
}

/// A module as the knowledge base sees it.
public struct CourseModuleInfo: Codable, Hashable, Sendable {
    public var code: String
    public var name: String
    public var courseID: Int?
    public var url: String?
    /// Teaching term of its "Week N" sections, when known.
    public var term: Int?
    public var weeks: [ELEModuleWeek]

    public init(code: String, name: String, courseID: Int? = nil, url: String? = nil, term: Int? = nil, weeks: [ELEModuleWeek] = []) {
        self.code = code; self.name = name; self.courseID = courseID; self.url = url; self.term = term; self.weeks = weeks
    }
}

public struct KBHit: Hashable, Sendable {
    public var document: CourseDocumentInfo
    /// "Title › Key points › Slide 12: Sampling distributions".
    public var heading: String
    public var text: String
    public var snippet: String
    public var score: Double
    /// Slide number when the chunk came from a deck.
    public var slide: Int?

    public var citation: String { document.citation + (slide.map { ", slide \($0)" } ?? "") }
}

/// A downloadable ELE item the Mac should fetch and index.
public struct ResourceTarget: Hashable, Sendable {
    public var cmid: Int
    public var moduleCode: String
    public var term: Int?
    public var week: Int?
    public var section: String
    public var name: String
    public var kind: CourseDocKind
    public var itemKind: ELEWebItem.Kind
    public var url: String
    public var documentID: String { "ele-cm-\(cmid)" }
}

// MARK: - Overviews

public struct WeekOverview: Hashable, Sendable {
    public var moduleCode: String
    public var moduleName: String
    public var week: AcademicWeek
    /// ELE section title, e.g. "Week 2 W/c 28 September: Probability".
    public var title: String?
    public var lectures: [String]
    public var tutorials: [String]
    public var readings: [String]
    public var materials: [CourseDocumentInfo]
    /// Timetabled sessions for this module in the week.
    public var sessions: [CalendarEvent]
    public var homeworkDue: [HomeworkItem]
    public var assessmentsDue: [Assessment]

    public var isEmpty: Bool {
        lectures.isEmpty && tutorials.isEmpty && readings.isEmpty && materials.isEmpty && sessions.isEmpty
            && homeworkDue.isEmpty && assessmentsDue.isEmpty
    }

    /// A few lines for chat and notifications.
    public func text(timeZone: TimeZone) -> String {
        let f = KBFormat(timeZone: timeZone)
        var lines = ["\(moduleCode) \(moduleName) — \(week.label)\(title.map { ": \($0)" } ?? "")"]
        if !sessions.isEmpty {
            lines.append("  Sessions: " + sessions.sorted { $0.start < $1.start }.map { "\($0.title) \(f.dayTime($0.start))" }.joined(separator: "; "))
        }
        if !lectures.isEmpty { lines.append("  Lecture materials: " + lectures.prefix(6).joined(separator: "; ")) }
        if !tutorials.isEmpty { lines.append("  Tutorials: " + tutorials.joined(separator: "; ")) }
        if !readings.isEmpty { lines.append("  Reading: " + readings.prefix(5).joined(separator: "; ")) }
        for h in homeworkDue { lines.append("  Homework: \(h.title)\(h.due.map { " — due \(f.dayTime($0))" } ?? "")") }
        for a in assessmentsDue { lines.append("  Assessment: \(a.title)\(a.due.map { " — due \(f.dayTime($0))" } ?? "")") }
        let other = materials.filter { ![.slides, .lectureNotes, .elePage].contains($0.kind) }
        if !other.isEmpty { lines.append("  Also on ELE: " + other.prefix(6).map(\.title).joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }
}

public struct ModuleOverview: Hashable, Sendable {
    public var module: CourseModuleInfo
    public var assessments: [Assessment]
    public var homework: [HomeworkItem]
    public var documentCounts: [CourseDocKind: Int]
    public var notesCount: Int

    public func text(timeZone: TimeZone) -> String {
        let f = KBFormat(timeZone: timeZone)
        var lines = ["\(module.code) \(module.name)\(module.term.map { " (term \($0))" } ?? "")"]
        for w in module.weeks {
            var s = "  Week \(w.week): \(w.title)"
            if !w.tutorials.isEmpty { s += " · tutorial: \(w.tutorials.joined(separator: "; "))" }
            lines.append(s)
        }
        for a in assessments {
            lines.append("  Assessment: \(a.title) (\(Int(a.weightPercent))%)\(a.due.map { " due \(f.dayTime($0))" } ?? "")")
        }
        for h in homework { lines.append("  Homework: \(h.title)\(h.due.map { " due \(f.dayTime($0))" } ?? "")") }
        let counts = documentCounts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.value) \($0.key.label)" }
        if !counts.isEmpty { lines.append("  Indexed: " + counts.joined(separator: ", ") + ", \(notesCount) note page(s)") }
        return lines.joined(separator: "\n")
    }
}

public struct WhatsHappening: Hashable, Sendable {
    public var now: Date
    public var currentWeek: AcademicWeek?
    public var nextWeek: AcademicWeek?
    public var thisWeek: [WeekOverview]
    public var comingWeek: [WeekOverview]
    /// Homework and assessments due in the next 14 days, soonest first.
    public var dueSoon: [(title: String, moduleCode: String, due: Date)]

    public static func == (a: WhatsHappening, b: WhatsHappening) -> Bool {
        a.now == b.now && a.currentWeek == b.currentWeek && a.thisWeek == b.thisWeek && a.comingWeek == b.comingWeek
            && a.dueSoon.map(\.title) == b.dueSoon.map(\.title)
    }
    public func hash(into h: inout Hasher) { h.combine(now); h.combine(currentWeek) }

    public func text(calendar: AcademicCalendar) -> String {
        let tz = calendar.timeZone
        var lines: [String] = []
        if let w = currentWeek {
            lines.append("This week: \(calendar.describe(w))")
            lines += thisWeek.filter { !$0.isEmpty }.map { $0.text(timeZone: tz) }
        } else {
            lines.append("No teaching this week (holiday).")
        }
        if let n = nextWeek {
            lines.append("Next week: \(calendar.describe(n))")
            lines += comingWeek.filter { !$0.isEmpty }.map { $0.text(timeZone: tz) }
        }
        let f = KBFormat(timeZone: tz)
        if !dueSoon.isEmpty {
            lines.append("Due in the next two weeks:")
            lines += dueSoon.map { "  \($0.moduleCode) \($0.title) — \(f.dayTime($0.due))" }
        }
        return lines.joined(separator: "\n")
    }

    /// Two or three lines for the assistant's system prompt.
    public func compact(calendar: AcademicCalendar) -> String {
        let f = KBFormat(timeZone: calendar.timeZone)
        var lines: [String] = []
        if let w = currentWeek { lines.append("Academic week: \(calendar.describe(w)).") }
        else if let n = nextWeek { lines.append("Holiday; teaching resumes \(calendar.describe(n)).") }
        let topics = thisWeek.compactMap { o -> String? in
            guard let t = o.title ?? o.lectures.first else { return nil }
            return "\(o.moduleCode): \(t)"
        }
        if !topics.isEmpty { lines.append("This week on ELE: " + topics.prefix(6).joined(separator: "; ") + ".") }
        if !dueSoon.isEmpty {
            lines.append("Due soon: " + dueSoon.prefix(5).map { "\($0.moduleCode) \($0.title) (\(f.dayTime($0.due)))" }.joined(separator: "; ") + ".")
        }
        return lines.joined(separator: "\n")
    }
}

struct KBFormat {
    let timeZone: TimeZone
    func dayTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB"); f.timeZone = timeZone; f.dateFormat = "EEE d MMM HH:mm"
        return f.string(from: d)
    }
}

// MARK: - Knowledge base

public struct CourseKnowledgeBase: Codable, Sendable {
    public var calendarConfig: AcademicCalendarConfig
    public private(set) var modules: [String: CourseModuleInfo] = [:]
    public private(set) var documents: [String: CourseDocument] = [:]
    public var assessments: [Assessment] = []
    public var homework: [HomeworkItem] = []
    public var readings: [ReadingItem] = []
    /// Timetable / calendar events (lectures, tutorials…) near the present.
    public var timetable: [CalendarEvent] = []
    public private(set) var index: NoteIndex
    public var updatedAt: Date = .distantPast

    public init(calendar: AcademicCalendarConfig = .exeter2026, index: NoteIndex = NoteIndex(chunkSize: 900, overlap: 120, typedBoost: 1)) {
        calendarConfig = calendar
        self.index = index
    }

    public var calendar: AcademicCalendar { AcademicCalendar(config: calendarConfig) }
    public var isEmpty: Bool { documents.isEmpty && modules.isEmpty }

    // MARK: Documents

    /// Adds or replaces a document. Unchanged text is left alone (keeps embeddings). Returns true if indexed.
    @discardableResult
    public mutating func upsert(_ doc: CourseDocument) -> Bool {
        if let old = documents[doc.id], old.contentHash == doc.contentHash {
            documents[doc.id] = doc
            return false
        }
        documents[doc.id] = doc
        index.remove(noteID: doc.id)
        let text = doc.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let title = [doc.moduleCode, doc.week.map { "Week \($0)" }, doc.title].compactMap { $0 }.joined(separator: " ")
        index.add(LectureNote(id: doc.id, title: title, notebook: doc.kind.rawValue, section: doc.section ?? "",
                              moduleCode: doc.moduleCode, week: doc.week, created: doc.modified, modified: doc.modified,
                              segments: [NoteSegment(kind: doc.kind == .lectureNotes ? .typed : .typed, text: text)]))
        updatedAt = Date()
        return true
    }

    public mutating func remove(documentID: String) {
        documents[documentID] = nil
        index.remove(noteID: documentID)
    }

    public func document(id: String) -> CourseDocument? { documents[id] }

    /// Finds a document by id, exact title, or the best title match ("stats sheet", "week 2 slides").
    public func document(named query: String, moduleCode: String? = nil) -> CourseDocument? {
        if let d = documents[query] { return d }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let pool = documents.values.filter { moduleCode == nil || $0.moduleCode?.caseInsensitiveCompare(moduleCode!) == .orderedSame }
        if let exact = pool.first(where: { $0.title.lowercased() == q }) { return exact }
        let qTerms = Set(NoteIndex.terms(q))
        guard !qTerms.isEmpty else { return nil }
        let qWeek = UniRegex.first("\\bweek\\s*(\\d{1,2})", in: q)?[1].flatMap(Int.init)
        let scored = pool.map { d -> (CourseDocument, Double) in
            let hay = Set(NoteIndex.terms("\(d.title) \(d.moduleCode ?? "") \(d.kind.label) \(d.section ?? "")"))
            var s = Double(qTerms.intersection(hay).count) / Double(qTerms.count)
            if let qWeek, d.week == qWeek { s += 0.5 }
            if d.kind == .lectureNotes { s -= 0.05 }
            return (d, s)
        }
        return scored.filter { $0.1 >= 0.5 }.sorted { ($0.1, $1.0.id) > ($1.1, $0.0.id) }.first?.0
    }

    public func documents(moduleCode: String? = nil, week: Int? = nil, kinds: Set<CourseDocKind>? = nil) -> [CourseDocument] {
        documents.values.filter { d in
            (moduleCode == nil || d.moduleCode?.caseInsensitiveCompare(moduleCode!) == .orderedSame)
                && (week == nil || d.week == week) && (kinds == nil || kinds!.contains(d.kind))
        }.sorted { ($0.moduleCode ?? "", $0.week ?? 0, $0.kind.rawValue, $0.title) < ($1.moduleCode ?? "", $1.week ?? 0, $1.kind.rawValue, $1.title) }
    }

    /// What's on ELE for a module's week (slides, handouts, sheets…), without notes.
    public func materials(for moduleCode: String, week: Int) -> [CourseDocument] {
        documents(moduleCode: moduleCode, week: week).filter { $0.kind != .lectureNotes && $0.kind != .elePage }
    }

    /// Embeds chunks that don't have a vector yet.
    @discardableResult
    public mutating func embedMissing(using embedder: NoteEmbedder) async throws -> Int {
        var idx = index
        let n = try await idx.embedMissing(using: embedder)
        index = idx
        return n
    }

    // MARK: ELE

    /// Takes in module structure, section text, briefs, readings and assessments from an ELE sync.
    public mutating func update(from snap: ELEWebSnapshot) {
        let cal = calendar
        var liveSectionDocs = Set<String>()
        for course in snap.modules {
            guard let code = course.moduleCode else { continue }
            let content = snap.contents[code]
            let sections = content?.sections ?? []
            let term = cal.inferTerm(for: sections)
            modules[code] = CourseModuleInfo(code: code, name: course.name, courseID: course.id, url: course.viewURL,
                                             term: term, weeks: content?.weeks ?? [])
            for s in sections {
                let lines = [s.title, s.summary] + s.items.map { item in
                    item.text.isEmpty ? "• \(item.name)" : "• \(item.name): \(item.text)"
                }
                let text = lines.filter { !$0.isEmpty }.joined(separator: "\n")
                guard text.count > s.title.count + 2 else { continue }
                let id = "ele-section-\(code)-\(s.id ?? s.number ?? 0)"
                liveSectionDocs.insert(id)
                let week = s.kind == .week ? s.week : nil
                upsert(CourseDocument(id: id, moduleCode: code, term: week != nil ? (term ?? 1) : nil, week: week, kind: .elePage,
                                      title: s.title, section: s.title, url: s.url ?? course.viewURL, text: text,
                                      modified: snap.fetchedAt))
                // Assessment briefs already read during the sync.
                for item in s.items {
                    guard let cmid = item.cmid, let brief = snap.briefTexts[cmid], documents["ele-cm-\(cmid)"] == nil else { continue }
                    upsert(CourseDocument(id: "ele-cm-\(cmid)", moduleCode: code, week: nil, kind: .assessmentBrief, title: item.name,
                                          section: s.title, url: item.url, cmid: cmid, text: brief, modified: snap.fetchedAt))
                }
            }
        }
        for id in documents.keys where id.hasPrefix("ele-section-") && !liveSectionDocs.contains(id) { remove(documentID: id) }
        assessments = snap.assessments.map(\.assessment)
        readings = snap.contents.values.flatMap(\.readings)
        updatedAt = Date()
    }

    /// Downloadable items on the course pages (files, pages, folders), newest structure first.
    public func resourceTargets(from snap: ELEWebSnapshot) -> [ResourceTarget] {
        var out: [ResourceTarget] = []
        for (code, content) in snap.contents.sorted(by: { $0.key < $1.key }) {
            let term = modules[code]?.term
            for s in content.sections {
                for item in s.items where [.resource, .page, .folder].contains(item.kind) {
                    guard let cmid = item.cmid, let url = item.url, item.role != .recording, item.role != .readingList else { continue }
                    let week = s.kind == .week ? s.week : nil
                    out.append(ResourceTarget(cmid: cmid, moduleCode: code, term: week != nil ? (term ?? 1) : nil, week: week,
                                              section: s.title, name: item.name, kind: CourseDocKind.from(role: item.role, name: item.name),
                                              itemKind: item.kind, url: url))
                }
            }
        }
        return out
    }

    /// Adds (or refreshes) lecture notes. Notes with no text are skipped.
    public mutating func addNotes(_ notes: [LectureNote]) {
        let cal = calendar
        for n in notes {
            let term = n.moduleCode.flatMap { modules[$0]?.term } ?? cal.week(for: n.created)?.term
            var text = n.keyPoints
            let detail = n.segments.filter { $0.kind != .typed }.map(\.text).joined(separator: "\n")
            if !detail.isEmpty { text += (text.isEmpty ? "" : "\n\n# Lecture detail\n") + detail }
            upsert(CourseDocument(id: "note:\(n.id)", moduleCode: n.moduleCode, term: term, week: n.week ?? inferredWeek(n, cal),
                                  kind: .lectureNotes, title: n.title, section: n.section, text: text, modified: n.modified))
        }
    }

    func inferredWeek(_ n: LectureNote, _ cal: AcademicCalendar) -> Int? {
        guard let w = cal.week(for: n.created) else { return nil }
        if let code = n.moduleCode, let t = modules[code]?.term, t != w.term { return nil }
        return w.week
    }

    // MARK: Search

    /// Keyword (and optional semantic) search across everything, with filters.
    public func search(_ query: String, moduleCode: String? = nil, week: Int? = nil, kinds: Set<CourseDocKind>? = nil,
                       limit: Int = 8, queryEmbedding: [Double]? = nil) -> [KBHit] {
        let docs = documents
        let hits = index.search(query, moduleCode: moduleCode, limit: limit, queryEmbedding: queryEmbedding) { chunk in
            guard let d = docs[chunk.noteID] else { return false }
            if let week, d.week != week { return false }
            if let kinds, !kinds.contains(d.kind) { return false }
            return true
        }
        return hits.compactMap { h in
            guard let d = docs[h.chunk.noteID] else { return nil }
            return KBHit(document: d.info, heading: h.chunk.heading, text: h.chunk.text, snippet: h.snippet, score: h.score,
                         slide: Self.slideNumber(heading: h.chunk.heading, text: h.chunk.text))
        }
    }

    /// Hybrid search, embedding the query first.
    public func search(_ query: String, moduleCode: String? = nil, week: Int? = nil, kinds: Set<CourseDocKind>? = nil,
                       limit: Int = 8, embedder: NoteEmbedder) async -> [KBHit] {
        let q = try? await embedder.embed([query]).first
        return search(query, moduleCode: moduleCode, week: week, kinds: kinds, limit: limit, queryEmbedding: q ?? nil)
    }

    static func slideNumber(heading: String, text: String) -> Int? {
        if let m = UniRegex.first("slide\\s*(\\d+)", in: heading), let n = m[1].flatMap(Int.init) { return n }
        if let m = UniRegex.first("^#\\s*slide\\s*(\\d+)", in: text), let n = m[1].flatMap(Int.init) { return n }
        return nil
    }

    // MARK: Overviews

    func moduleWeek(_ code: String, _ week: Int) -> ELEModuleWeek? { modules[code]?.weeks.first { $0.week == week } }

    /// Everything about one module's teaching week.
    public func weekOverview(module code: String, week: Int, term: Int? = nil) -> WeekOverview? {
        let cal = calendar
        let t = term ?? modules[code]?.term ?? 1
        guard let aw = cal.academicWeek(term: t, week: week) else { return nil }
        let end = aw.end(in: cal.dayCalendar.calendar)
        let ele = moduleWeek(code, week)
        let docs = documents(moduleCode: code, week: week).filter { $0.kind != .elePage && $0.kind != .lectureNotes }
        let sessions = timetable.filter { e in
            e.start >= aw.start && e.start <= end && LectureTracker.moduleCode(of: e, modules: Array(modules.values)) == code
        }
        let hw = homework.filter { h in
            h.moduleCode == code && ((h.due.map { $0 >= aw.start && $0 <= end } ?? false) || (h.due == nil && h.week == week))
        }
        let due = assessments.filter { a in a.moduleCode == code && (a.due.map { $0 >= aw.start && $0 <= end } ?? false) }
        return WeekOverview(moduleCode: code, moduleName: modules[code]?.name ?? code, week: aw, title: ele?.title,
                            lectures: ele?.lectures.map(\.name) ?? [], tutorials: ele?.tutorials ?? [],
                            readings: ele?.readings ?? [], materials: docs.map(\.info), sessions: sessions,
                            homeworkDue: hw, assessmentsDue: due)
    }

    public func moduleOverview(module code: String) -> ModuleOverview? {
        guard let m = modules[code] ?? modules.values.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame }) else { return nil }
        let docs = documents(moduleCode: m.code)
        var counts: [CourseDocKind: Int] = [:]
        for d in docs where d.kind != .lectureNotes && d.kind != .elePage { counts[d.kind, default: 0] += 1 }
        return ModuleOverview(module: m, assessments: assessments.filter { $0.moduleCode == m.code }
                                .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) },
                              homework: homework.filter { $0.moduleCode == m.code }, documentCounts: counts,
                              notesCount: docs.filter { $0.kind == .lectureNotes }.count)
    }

    /// This week and next across all modules: sessions, ELE content, readings, homework and assessments.
    public func whatsHappening(now: Date = Date()) -> WhatsHappening {
        let cal = calendar
        let current = cal.week(for: now)
        let next = current.flatMap { cal.next(after: $0) } ?? cal.currentOrNextWeek(now)
        func overviews(_ w: AcademicWeek?) -> [WeekOverview] {
            guard let w else { return [] }
            return modules.keys.sorted().compactMap { code in
                let t = modules[code]?.term
                guard t == nil || t == w.term else { return nil }
                return weekOverview(module: code, week: w.week, term: w.term)
            }
        }
        let horizon = now.addingTimeInterval(14 * 86400)
        var due: [(title: String, moduleCode: String, due: Date)] = homework.compactMap { h in
            guard let d = h.due, d >= now, d <= horizon else { return nil }
            return (h.title, h.moduleCode, d)
        }
        due += assessments.compactMap { a in
            guard let d = a.due, d >= now, d <= horizon, !a.submitted else { return nil }
            return (a.title, a.moduleCode, d)
        }
        return WhatsHappening(now: now, currentWeek: current, nextWeek: next, thisWeek: overviews(current),
                              comingWeek: overviews(next), dueSoon: due.sorted { $0.due < $1.due })
    }

    // MARK: Persistence

    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> CourseKnowledgeBase {
        try JSONDecoder().decode(CourseKnowledgeBase.self, from: Data(contentsOf: url))
    }
}
