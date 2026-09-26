import Foundation

// Parsers for ELE as the website serves it to a logged-in browser: the Moodle
// AJAX endpoint (/lib/ajax/service.php) and the course/section HTML pages.
// Everything here is pure so it can be tested on Linux with saved fixtures.

public enum ELEWebError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The browser session has expired (redirected to login, or Moodle said "requirelogin").
    case sessionExpired
    /// Moodle returned an error for an AJAX call.
    case ajax(code: String, message: String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .sessionExpired: "ELE sign-in expired"
        case let .ajax(code, message): "ELE \(code): \(message)"
        case let .badResponse(s): "Unexpected ELE response: \(s)"
        }
    }

    /// Moodle error codes that mean "log in again".
    public static let loginErrorCodes: Set<String> = [
        "servicerequireslogin", "requirelogin", "invalidsesskey", "sessionexpired", "sessiontimedout", "notloggedin",
    ]

    /// Error codes meaning the AJAX function isn't available to the browser (use the HTML fallback).
    public var isUnavailableFunction: Bool {
        guard case let .ajax(code, _) = self else { return false }
        return ["servicenotavailable", "invalidrecord", "webservicenotavailable", "nopermissions"].contains(code)
            || code.contains("notavailable")
    }
}

/// A course on the ELE dashboard ("My Courses").
public struct ELEWebCourse: Identifiable, Codable, Hashable, Sendable {
    public var id: Int
    public var fullName: String
    public var shortName: String
    public var viewURL: String
    public var progress: Double?
    public var category: String?
    /// "BEE1032" for module courses; nil for info courses (BUS_*, UNI_* …).
    public var moduleCode: String?
    /// Readable name: "History of Economic Thought".
    public var name: String
    /// First calendar year of the academic year ("202627" → 2026).
    public var academicYearStart: Int?

    public var isModule: Bool { moduleCode != nil }

    public init(id: Int, fullName: String, shortName: String, viewURL: String, progress: Double? = nil,
                category: String? = nil) {
        self.id = id; self.fullName = fullName; self.shortName = shortName; self.viewURL = viewURL
        self.progress = progress; self.category = category
        moduleCode = ELEWebParser.moduleCode(shortName: shortName)
        name = ELEWebParser.courseName(fullName: fullName, shortName: shortName)
        academicYearStart = ELEWebParser.academicYearStart(shortName: shortName)
    }
}

/// An item on a course page (a file, page, link, label, assignment…).
public struct ELEWebItem: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case resource, page, url, lti, assign, quiz, forum, folder, label, book, turnitin, other
    }
    /// What the item is for, guessed from its name and section.
    public enum Role: String, Codable, Sendable {
        case slides, handout, reading, readingGuide, readingList, tutorial, recording, pastPaper,
             exemplar, assessmentBrief, submission, other
    }

    /// Moodle course-module id (cmid), when known.
    public var cmid: Int?
    public var name: String
    public var kind: Kind
    public var role: Role
    public var url: String?
    /// Short text shown under the item (or a label's own text).
    public var text: String

    public init(cmid: Int?, name: String, kind: Kind, role: Role = .other, url: String? = nil, text: String = "") {
        self.cmid = cmid; self.name = name; self.kind = kind; self.role = role; self.url = url; self.text = text
    }
}

public struct ELEWebSection: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case general, assessment, readingList, recordings, week, pastPapers, exemplars, other
    }

    public var id: Int?
    public var number: Int?
    public var title: String
    public var kind: Kind
    public var week: Int?
    public var weekCommencing: Date?
    public var url: String?
    /// Plain text of the section summary.
    public var summary: String
    public var items: [ELEWebItem]
    /// Raw HTML, kept only for assessment sections (for the table extractor); not persisted.
    public var html: String?

    public init(id: Int? = nil, number: Int? = nil, title: String, kind: Kind = .other, week: Int? = nil,
                weekCommencing: Date? = nil, url: String? = nil, summary: String = "", items: [ELEWebItem] = [],
                html: String? = nil) {
        self.id = id; self.number = number; self.title = title; self.kind = kind; self.week = week
        self.weekCommencing = weekCommencing; self.url = url; self.summary = summary; self.items = items; self.html = html
    }

    enum CodingKeys: String, CodingKey { case id, number, title, kind, week, weekCommencing, url, summary, items }
}

/// A link shown in the Uni view.
public struct ELEWebLink: Codable, Hashable, Sendable {
    public var name: String
    public var url: String?
    public var kind: String
    public init(name: String, url: String?, kind: String) { self.name = name; self.url = url; self.kind = kind }
}

/// One teaching week of a module, ready for display (stored as JSON on the module).
public struct ELEModuleWeek: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { week }
    public var week: Int
    public var title: String
    public var weekCommencing: Date?
    public var lectures: [ELEWebLink]
    public var readings: [String]
    public var readingGuides: [ELEWebLink]
    public var tutorials: [String]
    public var other: [ELEWebLink]
    public var url: String?

    public init(week: Int, title: String, weekCommencing: Date? = nil, lectures: [ELEWebLink] = [], readings: [String] = [],
                readingGuides: [ELEWebLink] = [], tutorials: [String] = [], other: [ELEWebLink] = [], url: String? = nil) {
        self.week = week; self.title = title; self.weekCommencing = weekCommencing; self.lectures = lectures
        self.readings = readings; self.readingGuides = readingGuides; self.tutorials = tutorials; self.other = other; self.url = url
    }

    public var isEmpty: Bool { lectures.isEmpty && readings.isEmpty && readingGuides.isEmpty && tutorials.isEmpty && other.isEmpty }

    /// Stable fingerprint of the content, for "new this week" detection.
    public var contentKey: String {
        (lectures.map(\.name) + readings + readingGuides.map(\.name) + tutorials + other.map(\.name)).joined(separator: "|")
    }
}

/// A deadline from the ELE timeline (core_calendar_get_action_events_by_timesort).
public struct ELEWebEvent: Codable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var timesort: Date
    public var courseID: Int?
    public var courseShortName: String?
    public var url: String?
    public var moduleName: String?
    public var instance: Int?
    public var actionable: Bool
}

public enum ELEWebParser {
    public static let site = "https://ele.exeter.ac.uk"

    // MARK: Names

    /// "BEE1032_A_1_202627" → "BEE1032". Info courses ("UEBS_…") → nil.
    public static func moduleCode(shortName: String) -> String? {
        if let m = UniRegex.first("^([A-Z]{3}\\d{4}|[A-Z]{4}\\d{3})(?:_|$|\\s)", in: shortName, caseInsensitive: false) { return m[1] }
        return nil
    }

    /// "History of Economic Thought (BEE1032_A_1_202627)" → "History of Economic Thought".
    public static func courseName(fullName: String, shortName: String) -> String {
        var s = fullName.replacingOccurrences(of: "(\(shortName))", with: "")
        s = UniRegex.replace("\\s*\\([A-Z]{3,4}\\d{3,4}[^)]*\\)\\s*$", in: s, with: "", caseInsensitive: false)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = moduleCode(shortName: shortName) { s = ModuleCode.name(from: s, code: code) }
        return s.isEmpty ? fullName : UniHTML.decodeEntities(s)
    }

    /// "…_202627" → 2026.
    public static func academicYearStart(shortName: String) -> Int? {
        guard let m = UniRegex.first("_(20\\d{2})(\\d{2})$", in: shortName), let y = m[1].flatMap(Int.init),
              let next = m[2].flatMap(Int.init), (y + 1) % 100 == next else { return nil }
        return y
    }

    /// The academic year (Sept–Aug) containing `date`.
    public static func academicYearStart(for date: Date, timeZone: TimeZone = london) -> Int {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month], from: date)
        return (c.month ?? 1) >= 8 ? (c.year ?? 2026) : (c.year ?? 2026) - 1
    }

    public static let london = TimeZone(identifier: "Europe/London") ?? TimeZone(secondsFromGMT: 0)!

    static let months = ["january", "february", "march", "april", "may", "june", "july", "august",
                         "september", "october", "november", "december"]

    static func month(_ s: String) -> Int? {
        let l = s.lowercased()
        guard l.count >= 3 else { return nil }
        return months.firstIndex { $0.hasPrefix(l) || l.hasPrefix($0) }.map { $0 + 1 }
    }

    /// A day and month in the academic year starting `yearStart`: Sept–Dec in
    /// `yearStart`, Jan–Aug in the year after.
    public static func date(day: Int, month: Int, academicYear yearStart: Int, hour: Int = 0, minute: Int = 0,
                            timeZone: TimeZone = london) -> Date? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let year = month >= 8 ? yearStart : yearStart + 1
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
    }

    /// "Week 3 W/c 5 October" → (3, 2026-10-05). Also "Week 3: …", "Week 3 - w/c 5th Oct".
    public static func weekHeading(_ title: String, academicYear: Int?) -> (week: Int, commencing: Date?)? {
        guard let m = UniRegex.first("^\\s*week\\s*(\\d{1,2})\\b", in: title), let w = m[1].flatMap(Int.init) else { return nil }
        var date: Date?
        if let yearStart = academicYear,
           let d = UniRegex.first("w\\s*/\\s*c\\.?\\s*(?:\\w+day\\s+)?(\\d{1,2})(?:st|nd|rd|th)?\\s+([A-Za-z]{3,9})", in: title),
           let day = d[1].flatMap(Int.init), let mon = d[2].flatMap(month) {
            date = self.date(day: day, month: mon, academicYear: yearStart)
        }
        return (w, date)
    }

    // MARK: AJAX

    /// Unwraps `[{"error":false,"data":…}]` from /lib/ajax/service.php, throwing Moodle errors.
    public static func ajaxData(_ data: Data) throws -> Any {
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch {
            let text = String(decoding: data.prefix(300), as: UTF8.self)
            if looksLikeLoginPage(text) { throw ELEWebError.sessionExpired }
            throw ELEWebError.badResponse(text)
        }
        // A top-level error object (bad sesskey, not logged in) instead of an array.
        if let obj = json as? [String: Any] {
            if let code = obj["errorcode"] as? String {
                if ELEWebError.loginErrorCodes.contains(code) { throw ELEWebError.sessionExpired }
                throw ELEWebError.ajax(code: code, message: obj["error"] as? String ?? obj["message"] as? String ?? "")
            }
            throw ELEWebError.badResponse("object instead of array")
        }
        guard let first = (json as? [Any])?.first as? [String: Any] else { throw ELEWebError.badResponse("empty") }
        if (first["error"] as? Bool) == true || first["exception"] != nil {
            let ex = first["exception"] as? [String: Any] ?? [:]
            let code = ex["errorcode"] as? String ?? "error"
            if ELEWebError.loginErrorCodes.contains(code) { throw ELEWebError.sessionExpired }
            throw ELEWebError.ajax(code: code, message: ex["message"] as? String ?? "")
        }
        return first["data"] ?? NSNull()
    }

    /// Body for one AJAX call.
    public static func ajaxBody(method: String, args: [String: Any]) -> Data {
        let payload: [[String: Any]] = [["index": 0, "methodname": method, "args": args]]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("[]".utf8)
    }

    public static func ajaxURL(sesskey: String, method: String) -> URL {
        URL(string: "\(site)/lib/ajax/service.php?sesskey=\(sesskey)&info=\(method)")!
    }

    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    /// core_course_get_enrolled_courses_by_timeline_classification.
    public static func courses(fromAJAX data: Data) throws -> [ELEWebCourse] {
        let payload = try ajaxData(data)
        guard let list = (payload as? [String: Any])?["courses"] as? [[String: Any]] else { return [] }
        return list.compactMap { c in
            guard let id = int(c["id"]) else { return nil }
            let full = UniHTML.decodeEntities(c["fullname"] as? String ?? c["fullnamedisplay"] as? String ?? "")
            let short = UniHTML.decodeEntities(c["shortname"] as? String ?? "")
            let progress = (c["progress"] as? Double) ?? int(c["progress"]).map(Double.init)
            return ELEWebCourse(id: id, fullName: full, shortName: short,
                                viewURL: c["viewurl"] as? String ?? "\(site)/course/view.php?id=\(id)",
                                progress: progress, category: c["coursecategory"] as? String)
        }
    }

    /// core_calendar_get_action_events_by_timesort.
    public static func events(fromAJAX data: Data) throws -> [ELEWebEvent] {
        let payload = try ajaxData(data)
        guard let list = (payload as? [String: Any])?["events"] as? [[String: Any]] else { return [] }
        return list.compactMap { e in
            guard let id = int(e["id"]), let ts = int(e["timesort"]) ?? int(e["timestart"]) else { return nil }
            let course = e["course"] as? [String: Any]
            let action = e["action"] as? [String: Any]
            return ELEWebEvent(id: id, name: UniHTML.decodeEntities(e["name"] as? String ?? ""),
                               timesort: Date(timeIntervalSince1970: TimeInterval(ts)),
                               courseID: int(course?["id"]) ?? int(e["courseid"]),
                               courseShortName: course?["shortname"] as? String,
                               url: e["url"] as? String, moduleName: e["modulename"] as? String,
                               instance: int(e["instance"]),
                               actionable: (action?["actionable"] as? Bool) ?? true)
        }
    }

    /// Timeline events → assessments for module courses (ids match the Moodle-token sync).
    public static func assessments(fromEvents events: [ELEWebEvent], courses: [ELEWebCourse]) -> [Assessment] {
        let byID = Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Assessment] = []
        for e in events {
            guard let cid = e.courseID, let course = byID[cid], let code = course.moduleCode else { continue }
            guard !["forum", "choice", "feedback", "attendance", "scheduler"].contains(e.moduleName ?? "") else { continue }
            let id = e.instance.map { ELEMapping.assessmentID(module: e.moduleName ?? "event", instance: $0) } ?? "ele-event-\(e.id)"
            let title = ELEMapping.cleanDeadlineTitle(e.name)
            out.append(Assessment(id: id, moduleCode: code, title: title,
                                  kind: e.moduleName == "quiz" ? .quiz : AssessmentParsing.kind(title: title),
                                  weightPercent: AssessmentParsing.weightFromTitle(title) ?? 0, due: e.timesort,
                                  wordCount: AssessmentParsing.wordCount(in: title), eleURL: e.url))
        }
        return out
    }

    /// core_courseformat_get_state returns its state as a JSON string.
    public static func sections(fromCourseState data: Data, academicYear: Int?) throws -> [ELEWebSection] {
        var payload = try ajaxData(data)
        if let s = payload as? String, let inner = s.data(using: .utf8) {
            payload = (try? JSONSerialization.jsonObject(with: inner)) ?? [:]
        }
        guard let state = payload as? [String: Any] else { return [] }
        let cms = (state["cm"] as? [[String: Any]] ?? []).reduce(into: [Int: [String: Any]]()) { d, cm in
            if let id = int(cm["id"]) { d[id] = cm }
        }
        return (state["section"] as? [[String: Any]] ?? []).map { s in
            let title = UniHTML.text(s["title"] as? String ?? s["name"] as? String ?? "")
            let ids = (s["cmlist"] as? [Any] ?? []).compactMap(int)
            let items: [ELEWebItem] = ids.compactMap { id in
                guard let cm = cms[id] else { return nil }
                let mod = cm["module"] as? String ?? cm["modname"] as? String ?? ""
                return ELEWebItem(cmid: id, name: UniHTML.text(cm["name"] as? String ?? ""), kind: itemKind(mod),
                                  url: cm["url"] as? String)
            }
            var section = ELEWebSection(id: int(s["id"]), number: int(s["section"]) ?? int(s["number"]), title: title,
                                        url: s["sectionurl"] as? String, items: items)
            classify(&section, academicYear: academicYear)
            return section
        }
    }

    // MARK: Course HTML

    /// True when an HTML page is the ELE / Microsoft login page rather than content.
    public static func looksLikeLoginPage(_ html: String) -> Bool {
        let s = html.prefix(200_000)
        return s.contains("login.microsoftonline.com") || s.contains("id=\"login\"") && s.contains("logintoken")
            || s.contains("<body id=\"page-login-index\"") || s.contains("page-login-index")
    }

    /// `M.cfg.sesskey` from a page's inline config.
    public static func sesskey(inHTML html: String) -> String? {
        UniRegex.first("\"sesskey\"\\s*:\\s*\"([A-Za-z0-9]+)\"", in: html)?[1]
    }

    static func itemKind(_ mod: String) -> ELEWebItem.Kind {
        switch mod.lowercased() {
        case "resource": .resource
        case "page": .page
        case "url": .url
        case "lti": .lti
        case "assign": .assign
        case "quiz": .quiz
        case "forum": .forum
        case "folder": .folder
        case "label", "text", "subsection": .label
        case "book": .book
        case "turnitintooltwo", "turnitin": .turnitin
        default: .other
        }
    }

    /// Splits a course page (course/view.php or section.php) into sections with their items.
    public static func sections(fromCourseHTML html: String, academicYear: Int?) -> [ELEWebSection] {
        let ns = html as NSString
        let starts = UniRegex.regex("<li[^>]*\\bid=\"section-(\\d+)\"[^>]*>", caseInsensitive: true)
            .matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out: [ELEWebSection] = []
        for (i, m) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1].range.location : ns.length
            let tag = ns.substring(with: m.range)
            let chunk = ns.substring(with: NSRange(location: m.range.location, length: end - m.range.location))
            let number = Int(ns.substring(with: m.range(at: 1)))
            let sectionID = attr("data-sectionid", in: tag).flatMap(Int.init)
                ?? attr("data-id", in: tag).flatMap(Int.init)
            var title = attr("data-sectionname", in: tag).map(UniHTML.decodeEntities) ?? ""
            if title.isEmpty, let h = UniRegex.first("<h[2-4][^>]*class=\"[^\"]*sectionname[^\"]*\"[^>]*>(.*?)</h[2-4]>", in: chunk, dotAll: true) {
                title = UniHTML.text(h[1] ?? "")
            }
            if title.isEmpty, let a = attr("aria-label", in: tag) { title = UniHTML.decodeEntities(a) }
            let link = UniRegex.first("href=\"([^\"]*course/(?:section\\.php\\?id=\\d+|view\\.php\\?id=\\d+(?:&amp;|&)section=\\d+))\"", in: chunk)?[1]
                .map(UniHTML.decodeEntities)

            // Activities: each <li class="activity … modtype_x"> up to the next one.
            let actRegex = UniRegex.regex("<li[^>]*class=\"[^\"]*\\bactivity\\b[^\"]*\\bmodtype_([a-z0-9_]+)[^\"]*\"[^>]*>")
            let cns = chunk as NSString
            let acts = actRegex.matches(in: chunk, range: NSRange(location: 0, length: cns.length))
            let summaryEnd = acts.first?.range.location ?? cns.length
            var summaryHTML = cns.substring(to: summaryEnd)
            if let s = UniRegex.first("<div[^>]*class=\"[^\"]*summary(?:text)?[^\"]*\"[^>]*>(.*)", in: summaryHTML, dotAll: true) {
                summaryHTML = s[1] ?? summaryHTML
            } else {
                summaryHTML = UniRegex.replace("<h[2-4][^>]*sectionname.*?</h[2-4]>", in: summaryHTML, with: "", dotAll: true)
            }
            let summary = cleanText(summaryHTML)
            var items: [ELEWebItem] = []
            for (j, a) in acts.enumerated() {
                let aEnd = j + 1 < acts.count ? acts[j + 1].range.location : cns.length
                let body = cns.substring(with: NSRange(location: a.range.location, length: aEnd - a.range.location))
                let head = cns.substring(with: a.range)
                if let item = parseActivity(body: body, head: head, modtype: cns.substring(with: a.range(at: 1))) { items.append(item) }
            }
            var section = ELEWebSection(id: sectionID, number: number, title: title.isEmpty ? "Section \(number ?? 0)" : title,
                                        url: link, summary: summary, items: items)
            classify(&section, academicYear: academicYear)
            if section.kind == .assessment { section.html = chunk }
            out.append(section)
        }
        return out
    }

    static func parseActivity(body: String, head: String, modtype: String) -> ELEWebItem? {
        let kind = itemKind(modtype)
        let cmid = UniRegex.first("\\bid=\"module-(\\d+)\"", in: head)?[1].flatMap(Int.init)
            ?? attr("data-id", in: head).flatMap(Int.init)
        let url = UniRegex.first("href=\"([^\"]*/mod/[a-z0-9_]+/view\\.php\\?id=\\d+[^\"]*)\"", in: body)?[1].map(UniHTML.decodeEntities)
        var name = ""
        if let n = UniRegex.first("<span[^>]*class=\"[^\"]*instancename[^\"]*\"[^>]*>(.*?)</span>\\s*(?:</a>|</div>|<)", in: body, dotAll: true) {
            let inner = UniRegex.replace("<span[^>]*class=\"[^\"]*accesshide[^\"]*\"[^>]*>.*?</span>", in: n[1] ?? "", with: "", dotAll: true)
            name = UniHTML.text(inner)
        }
        if name.isEmpty, let n = attr("data-activityname", in: body) { name = UniHTML.decodeEntities(n) }
        // Description / label text.
        var text = ""
        for cls in ["activity-altcontent", "contentafterlink", "activity-description", "description", "no-overflow"] {
            if let d = UniRegex.first("<div[^>]*class=\"[^\"]*\\b\(cls)\\b[^\"]*\"[^>]*>(.*)", in: body, dotAll: true) {
                text = cleanText(d[1] ?? ""); if !text.isEmpty { break }
            }
        }
        if kind == .label {
            if text.isEmpty { text = cleanText(body) }
            if name.isEmpty { name = text.components(separatedBy: "\n").first ?? "" }
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty && text.isEmpty { return nil }
        if name.count > 200 { name = String(name.prefix(200)) }
        return ELEWebItem(cmid: cmid, name: name, kind: kind, url: url, text: String(text.prefix(600)))
    }

    /// Visible text with Moodle's accessibility and button chrome removed.
    static func cleanText(_ html: String) -> String {
        var s = UniRegex.replace("<span[^>]*class=\"[^\"]*(?:accesshide|sr-only|visually-hidden)[^\"]*\"[^>]*>.*?</span>", in: html, with: "", dotAll: true)
        s = UniRegex.replace("<(button|form|select)[^>]*>.*?</\\1>", in: s, with: "", dotAll: true)
        s = UniRegex.replace("<(div|span)[^>]*class=\"[^\"]*(?:activity-(?:information|dates|completion)|completion-info|automatic-completion|dropdown)[^\"]*\"[^>]*>.*?</\\1>", in: s, with: "", dotAll: true)
        return UniHTML.text(s)
    }

    static func attr(_ name: String, in tag: String) -> String? {
        UniRegex.first("\\b\(NSRegularExpression.escapedPattern(for: name))=\"([^\"]*)\"", in: tag)?[1]
    }

    /// Sets section kind/week and item roles.
    public static func classify(_ s: inout ELEWebSection, academicYear: Int?) {
        let t = s.title.lowercased()
        if let w = weekHeading(s.title, academicYear: academicYear) {
            s.kind = .week; s.week = w.week; s.weekCommencing = w.commencing
        } else if t.contains("assessment") || t.contains("coursework") && !t.contains("past") {
            s.kind = .assessment
        } else if t.contains("reading list") {
            s.kind = .readingList
        } else if t.contains("recording") || t.contains("recap") || t.contains("panopto") {
            s.kind = .recordings
        } else if t.contains("past paper") || t.contains("past exam") {
            s.kind = .pastPapers
        } else if t.contains("good answer") || t.contains("exemplar") || t.contains("example answer") {
            s.kind = .exemplars
        } else if s.number == 0 || t == "general" {
            s.kind = .general
        }
        for i in s.items.indices { s.items[i].role = role(of: s.items[i], in: s.kind) }
    }

    static func role(of item: ELEWebItem, in section: ELEWebSection.Kind) -> ELEWebItem.Role {
        let n = (item.name + " " + item.text.prefix(120)).lowercased()
        if item.kind == .assign || item.kind == .turnitin { return .submission }
        if item.kind == .lti && (n.contains("reading") || n.contains("talis")) || section == .readingList && item.kind != .label { return .readingList }
        if UniRegex.first("^\\s*reading\\s+for\\s+week", in: n) != nil { return .reading }
        if n.contains("guide to reading") || n.contains("reading guide") { return .readingGuide }
        if UniRegex.first("^\\s*tutorial\\b", in: n) != nil { return .tutorial }
        switch section {
        case .pastPapers: return .pastPaper
        case .exemplars: return .exemplar
        case .recordings: return .recording
        case .assessment:
            if [.resource, .page, .url, .folder].contains(item.kind) { return .assessmentBrief }
        default: break
        }
        if n.contains("recording") || n.contains("panopto") || n.contains("echo360") { return .recording }
        if n.contains("slide") || n.contains("lecture") || n.contains("powerpoint") || n.contains("pptx") { return .slides }
        if n.contains("handout") || n.contains("notes") || n.contains("worksheet") { return .handout }
        if item.kind == .resource && section == .week { return .handout }
        return .other
    }

    // MARK: Readings, tutorials, weeks

    /// "Reading for week 3: Smith, ch. 2" lines anywhere in a text → (3, "Smith, ch. 2").
    public static func readingLines(in text: String) -> [(week: Int, text: String)] {
        UniRegex.matches("reading\\s+for\\s+week\\s*(\\d{1,2})\\s*[:\\-–—]\\s*([^\\n]+)", in: text).compactMap { m in
            guard let w = m[1].flatMap(Int.init), let t = m[2]?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
            return (w, t)
        }
    }

    /// "Tutorial: Adam Smith and the division of labour" → the topic.
    public static func tutorialTopics(in text: String) -> [String] {
        UniRegex.matches("(?:^|\\n)\\s*tutorial\\s*(?:\\d+\\s*)?[:\\-–—]\\s*([^\\n]+)", in: text).compactMap {
            $0[1]?.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    /// Reading items for a module from its week sections.
    public static func readings(from sections: [ELEWebSection], moduleCode: String) -> [ReadingItem] {
        var out: [ReadingItem] = []
        var seen = Set<String>()
        for s in sections {
            var texts = [s.summary]
            for item in s.items { texts.append(item.name); texts.append(item.text) }
            for (week, text) in readingLines(in: texts.joined(separator: "\n")) {
                let key = "\(week)|\(text.lowercased())"
                guard seen.insert(key).inserted else { continue }
                let url = s.items.first { $0.role == .reading && $0.name.contains(text.prefix(20)) }?.url
                out.append(ReadingItem(id: "eleweb-\(moduleCode)-w\(week)-\(MD5.hex(text.lowercased()).prefix(10))",
                                       moduleCode: moduleCode, title: text, url: url ?? s.url, essential: true, week: week))
            }
        }
        return out
    }

    /// Display-ready weeks (only sections headed "Week N").
    public static func weeks(from sections: [ELEWebSection]) -> [ELEModuleWeek] {
        var byWeek: [Int: ELEModuleWeek] = [:]
        for s in sections where s.kind == .week {
            guard let w = s.week else { continue }
            var week = byWeek[w] ?? ELEModuleWeek(week: w, title: s.title, weekCommencing: s.weekCommencing, url: s.url)
            let all = ([s.summary] + s.items.flatMap { [$0.name, $0.text] }).joined(separator: "\n")
            week.readings += readingLines(in: all).map(\.text).filter { !week.readings.contains($0) }
            week.tutorials += tutorialTopics(in: all).filter { !week.tutorials.contains($0) }
            for item in s.items {
                let link = ELEWebLink(name: item.name, url: item.url, kind: item.kind.rawValue)
                switch item.role {
                case .slides, .handout, .recording: week.lectures.append(link)
                case .readingGuide: week.readingGuides.append(link)
                case .reading, .tutorial: if item.kind != .label { week.other.append(link) }
                default: if item.kind != .label { week.other.append(link) }
                }
            }
            byWeek[w] = week
        }
        return byWeek.values.sorted { $0.week < $1.week }
    }

    /// Course items → ELEResource (for change detection: "new files").
    public static func resources(from sections: [ELEWebSection], courseID: Int, moduleCode: String) -> [ELEResource] {
        sections.flatMap { s in
            s.items.compactMap { item -> ELEResource? in
                guard let cmid = item.cmid, item.kind != .label else { return nil }
                let kind: ELEResource.Kind = switch item.kind {
                case .resource: .file
                case .page: .page
                case .url: .link
                case .folder: .folder
                case .book: .book
                case .lti where item.role == .readingList: .readingList
                default: .other
                }
                return ELEResource(id: "ele-cm-\(cmid)", moduleCode: moduleCode, courseID: courseID, cmid: cmid,
                                   section: s.title, name: item.name, kind: kind, url: item.url)
            }
        }
    }

    /// URL that makes Moodle redirect straight to a resource's file.
    public static func downloadURL(for item: ELEWebItem) -> URL? {
        guard let s = item.url, var c = URLComponents(string: s) else { return nil }
        if s.contains("/mod/resource/view.php") {
            var q = c.queryItems ?? []
            if !q.contains(where: { $0.name == "redirect" }) { q.append(URLQueryItem(name: "redirect", value: "1")) }
            c.queryItems = q
        }
        return c.url
    }

    /// The first pluginfile.php link in an HTML page (resource pages that embed their file).
    public static func pluginFileURL(inHTML html: String) -> URL? {
        UniRegex.first("(https?://[^\"'\\s]+/pluginfile\\.php/[^\"'\\s<>]+)", in: html)?[1]
            .map(UniHTML.decodeEntities).flatMap(URL.init(string:))
    }
}
