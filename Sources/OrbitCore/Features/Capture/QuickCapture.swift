import Foundation

/// What a quick-capture line turns into.
///
/// - plain text → a to-do (via `QuickAddParser`)
/// - `e:` / `event:` prefix → a calendar event ("e: dinner with Sam Fri 7pm @ Côte")
/// - `n:` / `note:` prefix → a quick note
/// - `t:` / `task:` prefix → a to-do (explicit)
public enum CaptureIntent: Hashable, Sendable {
    case task(OrbitTask)
    case event(CapturedEvent)
    case note(CapturedNote)
}

public struct CapturedEvent: Hashable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String?
    /// False when no time was given (it's put at 12:00 and flagged).
    public var hasTime: Bool
}

public struct CapturedNote: Hashable, Sendable {
    public var title: String
    public var body: String
    public var moduleCode: String?
}

public struct QuickCaptureParser: Sendable {
    public var now: Date
    public var timeZone: TimeZone

    public init(now: Date = Date(), timeZone: TimeZone = TimeZone(identifier: "Europe/London")!) {
        self.now = now; self.timeZone = timeZone
    }

    static let prefixes: [(String, Int)] = [("event:", 1), ("e:", 1), ("note:", 2), ("n:", 2), ("task:", 0), ("t:", 0)]

    public func parse(_ input: String) -> CaptureIntent? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var kind = 0
        var body = trimmed
        for (p, k) in Self.prefixes where trimmed.lowercased().hasPrefix(p) {
            kind = k
            body = String(trimmed.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard !body.isEmpty else { return nil }
        switch kind {
        case 1: return .event(event(body))
        case 2: return .note(note(body))
        default:
            var task = QuickAddParser(now: now, timeZone: timeZone).parse(body).task
            task.source = .manual
            return .task(task)
        }
    }

    func note(_ text: String) -> CapturedNote {
        let module = NoteMetadataDetector.moduleCode(in: [text])
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let title = firstLine.count > 60 ? String(firstLine.prefix(57)) + "…" : firstLine
        return CapturedNote(title: title, body: text, moduleCode: module)
    }

    static let durationRE = try! NSRegularExpression(
        pattern: "\\bfor\\s+(\\d+(?:\\.\\d+)?)\\s*(h|hr|hrs|hours?|m|mins?|minutes?)\\b|\\b(\\d+(?:\\.\\d+)?)\\s*(h|hr|hrs|hours?|mins?|minutes?)\\b",
        options: [.caseInsensitive])
    static let locationRE = try! NSRegularExpression(pattern: "\\s@\\s*([^@]+)$")

    func event(_ text: String) -> CapturedEvent {
        var s = " " + text
        var location: String?
        let ns = s as NSString
        if let m = Self.locationRE.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            location = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            s = ns.replacingCharacters(in: m.range, with: "")
        }
        var minutes: Int?
        let ns2 = s as NSString
        if let m = Self.durationRE.firstMatch(in: s, range: NSRange(location: 0, length: ns2.length)) {
            let numRange = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 3)
            let unitRange = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 4)
            if let n = Double(ns2.substring(with: numRange)) {
                let unit = ns2.substring(with: unitRange).lowercased()
                minutes = unit.hasPrefix("h") ? Int(n * 60) : Int(n)
                s = ns2.replacingCharacters(in: m.range, with: " ")
            }
        }

        let cal = DayCalendar(timeZone: timeZone)
        let matches = DateExtractor(now: now, timeZone: timeZone).extract(from: s)
        var start: Date
        var hasTime = false
        var end: Date?
        if let first = matches.first {
            start = first.date
            hasTime = first.hasTime
            if !hasTime { start = cal.date(minute: 12 * 60, of: first.date) }
            // A second time on the same day ("3pm to 5pm", "15:00-17:00") is the end.
            if let second = matches.dropFirst().first, second.hasTime, cal.isSameDay(second.date, start), second.date > start {
                end = second.date
            }
            let ranges = matches.prefix(end == nil ? 1 : 2).map { NSRange($0.range, in: s) }
                .sorted { $0.location > $1.location }
            var t = s as NSString
            for r in ranges where r.location != NSNotFound && NSMaxRange(r) <= t.length {
                t = t.replacingCharacters(in: r, with: " ") as NSString
            }
            s = t as String
        } else {
            start = cal.date(minute: 12 * 60, of: cal.addingDays(1, to: now))
        }
        let finish = end ?? start.addingTimeInterval(Double(minutes ?? 60) * 60)
        var title = s.replacingOccurrences(of: "\\s+(on|at|from|to|until|till|-|–)\\s*$", with: "", options: [.regularExpression, .caseInsensitive])
        title = title.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",-–")))
        if title.isEmpty { title = "Event" }
        return CapturedEvent(title: title.prefix(1).uppercased() + title.dropFirst(), start: start, end: finish,
                             location: location, hasTime: hasTime)
    }
}
