import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fallback when web services are blocked: the ELE calendar export.
/// The user copies the iCal URL from ELE → Calendar → Export calendar
/// (`…/calendar/export_execute.php?userid=…&authtoken=…`). Deadline events
/// ("… is due", "… closes") become Assessments; everything else stays an event.
public struct ELECalendarFeed: Sendable {
    public struct Result: Codable, Hashable, Sendable {
        public var assessments: [Assessment]
        public var events: [CalendarEvent]
    }

    public var url: URL
    public var http: HTTPClient

    public init(url: URL, http: HTTPClient = HTTPClient(timeout: 30)) {
        // webcal:// links from "Copy URL" work the same over https.
        if url.scheme?.lowercased() == "webcal", var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.scheme = "https"
            self.url = comps.url ?? url
        } else {
            self.url = url
        }
        self.http = http
    }

    public func fetch(knownModuleCodes: [String] = [], now: Date = Date()) async throws -> Result {
        let data = try await http.data("GET", url, headers: ["Accept": "text/calendar"])
        return Self.parse(String(decoding: data, as: UTF8.self), knownModuleCodes: knownModuleCodes, now: now)
    }

    public static func parse(_ ics: String, knownModuleCodes: [String] = [], now: Date = Date()) -> Result {
        let categories = categoriesByUID(ics)
        let events = ICSParser.parse(ics, source: .ele, calendarID: "ele", expandUntil: now.addingTimeInterval(400 * 86400))
        var result = Result(assessments: [], events: [])
        for e in events {
            let uid = String(e.id.split(separator: "#").first ?? Substring(e.id))
            let cats = categories[uid] ?? ""
            let code = ModuleCode.find(in: cats) ?? ModuleCode.find(in: e.title)
                ?? knownModuleCodes.first { e.title.localizedCaseInsensitiveContains($0) || cats.localizedCaseInsensitiveContains($0) }
            guard isDeadline(e.title) else {
                result.events.append(e)
                continue
            }
            let title = ELEMapping.cleanDeadlineTitle(e.title)
            let brief = e.notes ?? ""
            var kind = AssessmentParsing.kind(title: title, brief: brief)
            if kind == .coursework, e.title.lowercased().hasSuffix("closes") { kind = .quiz }
            result.assessments.append(Assessment(
                id: "ele-ics-\(uid)", moduleCode: code ?? "", title: title, kind: kind,
                weightPercent: AssessmentParsing.weightFromTitle(title) ?? AssessmentParsing.weightPercent(in: brief) ?? 0,
                due: e.isAllDay ? e.start.addingTimeInterval(86400 - 60) : e.start,
                wordCount: AssessmentParsing.wordCount(in: title) ?? AssessmentParsing.wordCount(in: brief)))
        }
        return result
    }

    /// Moodle names deadline events "X is due", "X closes", or with "due"/"deadline" in them.
    public static func isDeadline(_ title: String) -> Bool {
        let t = title.lowercased()
        if t.hasSuffix(" opens") || t.contains(" opens ") { return false }
        return t.contains("is due") || t.hasSuffix("closes") || t.contains(" closes")
            || UniRegex.first("\\b(due|deadline|submission)\\b", in: t) != nil
    }

    /// ICSParser doesn't keep CATEGORIES (Moodle puts the course short name there), so read it here.
    static func categoriesByUID(_ ics: String) -> [String: String] {
        var out: [String: String] = [:]
        var uid: String?, cats: String?
        for line in ICSParser.unfold(ics) {
            let upper = line.uppercased()
            if upper == "BEGIN:VEVENT" { uid = nil; cats = nil }
            else if upper.hasPrefix("UID"), let c = line.firstIndex(of: ":") { uid = String(line[line.index(after: c)...]) }
            else if upper.hasPrefix("CATEGORIES"), let c = line.firstIndex(of: ":") {
                cats = ICSParser.unescape(String(line[line.index(after: c)...]))
            } else if upper == "END:VEVENT", let u = uid, let c = cats { out[u] = c }
        }
        return out
    }
}
