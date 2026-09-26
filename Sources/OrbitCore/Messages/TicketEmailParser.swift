import Foundation

/// A ticket confirmation found in email (FIXR, Eventbrite, Skiddle, Ticketmaster, DICE).
public struct TicketEvent: Codable, Hashable, Sendable {
    public var provider: TicketProvider
    public var title: String
    public var start: Date
    public var end: Date
    /// False when the email only gave a day (start is then 19:00 local, a guess).
    public var hasTime: Bool
    public var venue: String?
    public var orderReference: String?
    public var ticketType: String?
    public var quantity: Int?
    /// The email it came from.
    public var messageID: String

    /// Stable id for the calendar entry (one per event, even if the email arrives twice).
    public var planID: String {
        let key = "\(provider.rawValue)|\(title.lowercased())|\(Int(start.timeIntervalSince1970 / 60))"
        return "ticket-" + StableID.uuid(key).uuidString
    }

    /// Notes for the calendar entry.
    public var notes: String {
        var lines = ["Tickets from \(provider.label)."]
        if let t = ticketType { lines.append("Ticket: \(t)" + (quantity.map { $0 > 1 ? " × \($0)" : "" } ?? "")) }
        if let r = orderReference { lines.append("Order: \(r)") }
        if !hasTime { lines.append("The email didn't give a time; check your ticket.") }
        return lines.joined(separator: "\n")
    }
}

public enum TicketProvider: String, Codable, Sendable, CaseIterable {
    case fixr, eventbrite, skiddle, ticketmaster, dice

    public var label: String {
        switch self {
        case .fixr: "FIXR"
        case .eventbrite: "Eventbrite"
        case .skiddle: "Skiddle"
        case .ticketmaster: "Ticketmaster"
        case .dice: "DICE"
        }
    }

    /// Sender domains (the address's domain ends with one of these).
    var domains: [String] {
        switch self {
        case .fixr: ["fixr.co", "fixr.com", "fixr-mail.co", "fixr.co.uk"]
        case .eventbrite: ["eventbrite.com", "eventbrite.co.uk", "order.eventbrite.com"]
        case .skiddle: ["skiddle.com"]
        case .ticketmaster: ["ticketmaster.co.uk", "ticketmaster.com", "ticketmaster.ie"]
        case .dice: ["dice.fm"]
        }
    }
}

/// Reads ticket confirmation emails. Deterministic, no AI: sender domain → provider,
/// then labelled lines ("Event:", "Date:", "Time:", "Venue:") or the subject
/// ("Your tickets for …"), with dates read by `DateExtractor` (UK formats).
public struct TicketEmailParser: Sendable {
    public var timeZone: TimeZone

    public init(timeZone: TimeZone = TimeZone(identifier: "Europe/London")!) {
        self.timeZone = timeZone
    }

    /// The provider when the email is from a ticketing site.
    public static func provider(from address: String) -> TicketProvider? {
        let lower = address.lowercased()
        let domain = lower.split(separator: "@").last.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) ?? lower
        return TicketProvider.allCases.first { p in p.domains.contains { domain == $0 || domain.hasSuffix("." + $0) } }
    }

    /// Words that mean "you bought a ticket" (as opposed to marketing).
    static let confirmationWords = ["your ticket", "your tickets", "you're going", "you’re going", "you are going",
                                    "order confirm", "booking confirm", "order number", "order reference", "order ref",
                                    "booking reference", "e-ticket", "eticket", "here are your", "ticket confirmation",
                                    "thanks for your order", "thank you for your order", "your order"]

    static let marketingWords = ["on sale now", "tickets selling fast", "don't miss", "last chance", "unsubscribe from marketing",
                                 "recommended for you", "events near you", "just announced"]

    public func parse(_ message: EmailMessage) -> TicketEvent? {
        guard let provider = Self.provider(from: message.from) else { return nil }
        let subject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = normalise(message.body.isEmpty ? message.snippet : message.body)
        let lowerAll = (subject + "\n" + body).lowercased()
        guard Self.confirmationWords.contains(where: { lowerAll.contains($0) }) else { return nil }
        if Self.marketingWords.contains(where: { subject.lowercased().contains($0) }) { return nil }

        let lines = body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let title = labelled(["event", "event name", "show", "what"], in: lines) ?? titleFromSubject(subject) ?? titleFromBody(lines)
        guard var title, !title.isEmpty else { return nil }
        title = cleanTitle(title)

        // Date and time: labelled lines first, then anything near the top of the email.
        let dateText = labelled(["date", "when", "date & time", "date and time", "event date", "starts"], in: lines)
        let timeText = labelled(["time", "doors", "doors open", "start time", "event time"], in: lines)
        let extractor = DateExtractor(now: message.date, timeZone: timeZone)
        let cal = DayCalendar(timeZone: timeZone)

        var candidates: [String] = []
        if let d = dateText { candidates.append(d + (timeText.map { " " + $0 } ?? "")) }
        candidates.append(subject)
        candidates.append(lines.prefix(25).joined(separator: "\n"))

        var start: Date?
        var hasTime = false
        var end: Date?
        for text in candidates {
            let matches = extractor.extract(from: text).filter { $0.periodEnd == nil }
            guard let first = matches.first(where: { $0.hasTime }) ?? matches.first else { continue }
            // Ignore dates before the email (e.g. "Ordered on 12 Sep").
            guard first.date >= cal.startOfDay(message.date) else { continue }
            start = first.date
            hasTime = first.hasTime
            // A range "22:00 - 03:00": the second time is the end (next day if earlier).
            let later = matches.dropFirst().first { $0.hasTime && $0.date != first.date }
            if hasTime, let later {
                var e = cal.date(minute: cal.minuteOfDay(later.date), of: first.date)
                if e <= first.date { e = cal.addingDays(1, to: e) }
                end = e
            }
            break
        }
        guard var startDate = start else { return nil }
        if !hasTime { startDate = cal.date(minute: 19 * 60, of: startDate) }
        let endDate = end ?? startDate.addingTimeInterval(hasTime ? 3 * 3600 : 4 * 3600)

        let venue = labelled(["venue", "location", "where", "address", "venue address"], in: lines).map(cleanVenue)
        let order = labelled(["order reference", "order ref", "order number", "order no", "order id", "booking reference",
                              "reference", "order"], in: lines)
            .flatMap { $0.split(separator: " ").first.map(String.init) }
        let ticketType = labelled(["ticket type", "ticket", "tickets"], in: lines).flatMap { t -> String? in
            t.count <= 60 && !t.lowercased().hasPrefix("http") ? t : nil
        }
        let quantity = labelled(["quantity", "qty", "number of tickets"], in: lines)
            .flatMap { Int($0.filter(\.isNumber).prefix(3)) }

        return TicketEvent(provider: provider, title: title, start: startDate, end: endDate, hasTime: hasTime,
                           venue: venue, orderReference: order, ticketType: ticketType, quantity: quantity,
                           messageID: message.id)
    }

    // MARK: Helpers

    private func normalise(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    /// The value of "Label: value" (or "Label" on one line, value on the next).
    private func labelled(_ labels: [String], in lines: [String]) -> String? {
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            for label in labels {
                if lower.hasPrefix(label + ":") || lower.hasPrefix(label + " :") {
                    let value = line[line.index(line.startIndex, offsetBy: min(line.count, label.count))...]
                        .drop { $0 == ":" || $0 == " " }
                    let v = String(value).trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty { return v }
                    if i + 1 < lines.count { return lines[i + 1] }
                }
                if lower == label, i + 1 < lines.count { return lines[i + 1] }
            }
        }
        return nil
    }

    private func titleFromSubject(_ subject: String) -> String? {
        let patterns = [
            "your fixr tickets for ", "your fixr ticket for ", "your tickets for ", "your ticket for ", "tickets for ",
            "you're going to ", "you’re going to ", "you are going to ", "order confirmation for ", "order confirmation: ",
            "booking confirmation for ", "booking confirmation: ", "your order for ", "your e-ticket for ", "e-tickets for ",
        ]
        let lower = subject.lowercased()
        for p in patterns {
            if let r = lower.range(of: p) {
                let offset = lower.distance(from: lower.startIndex, to: r.upperBound)
                let rest = String(subject.dropFirst(offset))
                if !rest.trimmingCharacters(in: .whitespaces).isEmpty { return rest }
            }
        }
        return nil
    }

    private func titleFromBody(_ lines: [String]) -> String? {
        for line in lines.prefix(15) {
            let lower = line.lowercased()
            for p in ["you're going to ", "you’re going to ", "your tickets for ", "your ticket for "] {
                if let r = lower.range(of: p) {
                    let offset = lower.distance(from: lower.startIndex, to: r.upperBound)
                    return String(line.dropFirst(offset))
                }
            }
        }
        return nil
    }

    private func cleanTitle(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, "!.".contains(last) { t.removeLast() }
        for suffix in [" - FIXR", " | FIXR", " on FIXR", " - Eventbrite", " | Skiddle", " - Skiddle", " | DICE"] {
            if t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private func cleanVenue(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ",."))
    }
}
