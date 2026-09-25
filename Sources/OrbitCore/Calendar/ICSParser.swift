import Foundation

/// Minimal iCalendar (.ics) reader for ELE calendar exports and the Exeter
/// timetable feed. Handles line folding, TZID/UTC/all-day dates and escapes.
/// Recurring events (RRULE) are expanded for WEEKLY/DAILY rules with COUNT/UNTIL.
public enum ICSParser {
    public static func parse(_ text: String, source: CalendarSource = .timetable, calendarID: String = "ics",
                             defaultTimeZone: TimeZone = TimeZone(identifier: "Europe/London")!,
                             expandUntil: Date = Date().addingTimeInterval(200 * 86400)) -> [CalendarEvent] {
        let lines = unfold(text)
        var events: [CalendarEvent] = []
        var cur: [(name: String, params: [String: String], value: String)]? = nil
        for line in lines {
            if line == "BEGIN:VEVENT" { cur = []; continue }
            if line == "END:VEVENT" {
                if let props = cur { events += build(props, source: source, calendarID: calendarID, tz: defaultTimeZone, until: expandUntil) }
                cur = nil; continue
            }
            guard cur != nil, let colon = firstUnquotedColon(line) else { continue }
            let head = String(line[..<colon]), value = String(line[line.index(after: colon)...])
            var parts = head.split(separator: ";").map(String.init)
            let name = parts.removeFirst().uppercased()
            var params: [String: String] = [:]
            for p in parts {
                let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { params[kv[0].uppercased()] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            }
            cur?.append((name, params, value))
        }
        return events.sorted { $0.start < $1.start }
    }

    static func firstUnquotedColon(_ s: String) -> String.Index? {
        var inQuote = false
        for i in s.indices {
            if s[i] == "\"" { inQuote.toggle() } else if s[i] == ":" && !inQuote { return i }
        }
        return nil
    }

    static func unfold(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(raw)
            if (l.hasPrefix(" ") || l.hasPrefix("\t")), !out.isEmpty { out[out.count - 1] += l.dropFirst() }
            else { out.append(l) }
        }
        return out
    }

    public static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    public static func parseDate(_ value: String, params: [String: String], tz: TimeZone) -> (Date, Bool)? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if params["VALUE"] == "DATE" || value.count == 8 {
            f.dateFormat = "yyyyMMdd"; f.timeZone = tz
            return f.date(from: value).map { ($0, true) }
        }
        if value.hasSuffix("Z") {
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; f.timeZone = TimeZone(identifier: "UTC")
        } else {
            f.dateFormat = "yyyyMMdd'T'HHmmss"
            f.timeZone = params["TZID"].flatMap(TimeZone.init(identifier:)) ?? tz
        }
        return f.date(from: value).map { ($0, false) }
    }

    static func build(_ props: [(name: String, params: [String: String], value: String)], source: CalendarSource,
                      calendarID: String, tz: TimeZone, until: Date) -> [CalendarEvent] {
        func prop(_ n: String) -> (params: [String: String], value: String)? {
            props.first { $0.name == n }.map { ($0.params, $0.value) }
        }
        guard let ds = prop("DTSTART"), let (start, allDay) = parseDate(ds.value, params: ds.params, tz: tz) else { return [] }
        var end = start.addingTimeInterval(allDay ? 86400 : 3600)
        if let de = prop("DTEND"), let (e, _) = parseDate(de.value, params: de.params, tz: tz) { end = e }
        else if let dur = prop("DURATION")?.value, let secs = parseDuration(dur) { end = start.addingTimeInterval(secs) }
        let uid = prop("UID")?.value ?? UUID().uuidString
        let base = CalendarEvent(
            id: uid, title: unescape(prop("SUMMARY")?.value ?? "(no title)"), start: start, end: end,
            isAllDay: allDay, location: prop("LOCATION").map { unescape($0.value) },
            notes: prop("DESCRIPTION").map { unescape($0.value) }, calendarID: calendarID, source: source,
            isBusy: prop("TRANSP")?.value.uppercased() != "TRANSPARENT")
        guard let rule = prop("RRULE")?.value else { return [base] }
        return expand(base, rule: rule, exdates: props.filter { $0.name == "EXDATE" }.flatMap { p in
            p.value.split(separator: ",").compactMap { parseDate(String($0), params: p.params, tz: tz)?.0 }
        }, tz: tz, until: until)
    }

    static func parseDuration(_ s: String) -> TimeInterval? {
        // e.g. PT1H30M, P1D
        var total: TimeInterval = 0, num = "", inTime = false
        for c in s {
            switch c {
            case "P": continue
            case "T": inTime = true
            case "0"..."9": num.append(c)
            case "W": total += (Double(num) ?? 0) * 604800; num = ""
            case "D": total += (Double(num) ?? 0) * 86400; num = ""
            case "H": total += (Double(num) ?? 0) * 3600; num = ""
            case "M": total += (Double(num) ?? 0) * (inTime ? 60 : 2592000); num = ""
            case "S": total += Double(num) ?? 0; num = ""
            default: return nil
            }
        }
        return total
    }

    static func expand(_ e: CalendarEvent, rule: String, exdates: [Date], tz: TimeZone, until limit: Date) -> [CalendarEvent] {
        var fields: [String: String] = [:]
        for p in rule.split(separator: ";") {
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { fields[kv[0]] = kv[1] }
        }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let step: DateComponents
        let interval = Int(fields["INTERVAL"] ?? "1") ?? 1
        switch fields["FREQ"] {
        case "DAILY": step = DateComponents(day: interval)
        case "WEEKLY": step = DateComponents(day: 7 * interval)
        default: return [e]
        }
        let count = fields["COUNT"].flatMap { Int($0) } ?? 500
        var until = limit
        if let u = fields["UNTIL"], let (d, _) = parseDate(u, params: [:], tz: tz) { until = min(until, d.addingTimeInterval(86399)) }
        let duration = e.end.timeIntervalSince(e.start)
        var out: [CalendarEvent] = []
        var s = e.start, n = 0
        while n < count && s <= until {
            if !exdates.contains(where: { abs($0.timeIntervalSince(s)) < 60 }) {
                var copy = e
                copy.id = "\(e.id)#\(Int(s.timeIntervalSince1970))"
                copy.start = s; copy.end = s.addingTimeInterval(duration)
                out.append(copy)
            }
            n += 1
            guard let next = cal.date(byAdding: step, to: s) else { break }
            s = next
        }
        return out
    }
}
