import Foundation

/// What a chat message is, as far as the calendar is concerned.
public enum MessageIntent: String, Codable, Sendable, CaseIterable {
    /// A plan the user is part of (a confirmation, "see you at…", a ticket they bought).
    case plan
    /// A ticket drop / promo / on-sale alert: worth knowing about, not a plan.
    case ticketDrop = "ticket_drop"
    /// Nothing to do with the calendar.
    case noise
}

/// A "tickets on sale" alert found in a message. Shown as an info card with a Buy
/// link, never added to the calendar unless the user says they bought a ticket.
public struct TicketDrop: Identifiable, Codable, Hashable, Sendable {
    /// Stable per event (URL, else title + day), so the same promo sent twice is one card.
    public var id: String
    public var title: String
    /// When the event itself happens, if the message says.
    public var eventStart: Date?
    public var venue: String?
    public var buyURL: URL?
    public var provider: TicketProvider?
    public var quote: String
    public var source: MessageSource
    public var receivedAt: Date

    public init(id: String? = nil, title: String, eventStart: Date? = nil, venue: String? = nil, buyURL: URL? = nil,
                provider: TicketProvider? = nil, quote: String, source: MessageSource, receivedAt: Date) {
        self.title = title; self.eventStart = eventStart; self.venue = venue; self.buyURL = buyURL
        self.provider = provider; self.quote = quote; self.source = source; self.receivedAt = receivedAt
        let key = buyURL?.absoluteString.lowercased()
            ?? "\(title.lowercased())|\(eventStart.map { Int($0.timeIntervalSince1970 / 3600) } ?? 0)"
        self.id = id ?? "drop-" + StableID.uuid(key).uuidString
    }
}

/// The verdict on one message, with the signals that led to it.
public struct MessageClassification: Hashable, Sendable {
    public var intent: MessageIntent
    public var confidence: Double
    /// Human-readable signals ("on-sale wording", "ticket link", "confirmation").
    public var signals: [String]
    /// Set for `.ticketDrop`.
    public var ticketDrop: TicketDrop?
    /// True when the verdict came from the AI (rules alone otherwise).
    public var usedAI: Bool

    public init(intent: MessageIntent, confidence: Double, signals: [String] = [], ticketDrop: TicketDrop? = nil,
                usedAI: Bool = false) {
        self.intent = intent; self.confidence = confidence; self.signals = signals
        self.ticketDrop = ticketDrop; self.usedAI = usedAI
    }
}

/// Tells real plans apart from ticket drops and noise, in two stages:
///
/// 1. **Rules** score promo signals ("on sale", "tickets are live", "early bird",
///    shouting caps, an event page link such as `fixr.co/event/…`) against
///    commitment signals ("see you at", "got our tickets", "order confirmed",
///    a FIXR order/ticket link). A message that is clearly promotional is a
///    ticket drop even if it has a day and time; the rules alone decide when
///    they are sure.
/// 2. **AI** (optional) is asked for a structured verdict
///    `{"intent":"plan|ticket_drop|noise","confidence":…,"event_title":…,"event_start":…,"buy_url":…}`
///    when the rules are unsure. A rule veto (strong promo, no commitment)
///    always wins over an AI "plan".
public struct MessageIntentClassifier: Sendable {
    public var router: LLMRouter?
    public var purpose: LLMPurpose
    public var timeParser: PlanTimeParser

    public init(router: LLMRouter? = nil, purpose: LLMPurpose = .privateData,
                timeZone: TimeZone = TimeZone(identifier: "Europe/London")!) {
        self.router = router; self.purpose = purpose; self.timeParser = PlanTimeParser(timeZone: timeZone)
    }

    // MARK: Signals

    static let promoPhrases: [(String, PlanRegex)] = [
        ("on-sale wording", PlanRegex(#"\b(?:on sale|now on sale|tickets? (?:are |is )?(?:live|out now|out|available|on sale|released)|general sale|pre-?sale|presale)\b"#)),
        ("sell-out pressure", PlanRegex(#"\b(?:sell(?:ing)? out|sold out|selling fast|limited (?:tickets|capacity|numbers)|last (?:few|remaining) tickets|final release|won'?t last|don'?t miss (?:out)?)\b"#)),
        ("ticket tiers", PlanRegex(#"\b(?:early ?bird|first release|second release|1st release|2nd release|tier \d|£\d+(?:\.\d\d)? (?:tickets|entry)|entry from £)\b"#)),
        ("call to buy", PlanRegex(#"\b(?:get (?:your |ur )?tickets|buy (?:now|tickets|here)|grab (?:your |ur )?tickets|book now|link in (?:bio|description)|tickets? (?:here|below|via|at)|click (?:the )?link)\b"#)),
        ("event announcement", PlanRegex(#"\b(?:new event|event announce|announcing|just announced|lineup|line-up|headlin(?:e|er|ing))\b"#)),
    ]

    static let commitPhrases: [(String, PlanRegex)] = [
        ("see you there", PlanRegex(#"\bsee (?:you|u|ya) (?:at|there|then|later|tonight|tomorrow|on)\b"#)),
        ("bought tickets", PlanRegex(#"\b(?:i'?ve |i |we'?ve |we |just )?(?:got|bought|booked|purchased|grabbed) (?:my|our|the|us|you|u|a|2|two|3|three|some)? ?(?:tickets?|tix)\b"#)),
        ("order confirmation", PlanRegex(#"\b(?:order (?:confirmed|confirmation|number|ref(?:erence)?)|booking (?:confirmed|confirmation|reference)|your tickets?|you'?re going|e-?ticket|here (?:are|is) your)\b"#)),
        ("agreed to go", PlanRegex(#"\b(?:i'?m in|count me in|i'?m down|we'?re going|i'?m going|we'?re in|let'?s go|meet (?:you|u) (?:at|outside|there))\b"#)),
    ]

    /// Event pages on ticket sites (a shop page, not your order).
    static let eventLink = PlanRegex(#"\b((?:https?://)?(?:www\.)?(?:fixr\.co(?:m|\.uk)?/(?:event|e|organiser|o)/|skiddle\.com/whats-on/|dice\.fm/event/|link\.dice\.fm/|eventbrite\.(?:com|co\.uk)/e/|ticketmaster\.(?:co\.uk|com|ie)/[^\s]*event/|ra\.co/events/)[^\s<>"')]*)"#)
    /// Links that belong to a purchase (FIXR order/ticket pages, Eventbrite "my tickets").
    static let orderLink = PlanRegex(#"\b(?:fixr\.co(?:m|\.uk)?/(?:order|orders|ticket|tickets|t)/|eventbrite\.(?:com|co\.uk)/(?:mytickets|x/orders)|dice\.fm/(?:ticket|tickets)/)"#)

    /// Share of letters in upper case (promos SHOUT).
    static func capsRatio(_ s: String) -> Double {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 12 else { return 0 }
        let upper = letters.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        return Double(upper) / Double(letters.count)
    }

    /// Rule-stage scores for one text.
    public struct Signals: Hashable, Sendable {
        public var promo: Double
        public var commit: Double
        public var names: [String]
        public var eventURL: URL?
        public var hasOrderLink: Bool
    }

    public static func signals(in text: String) -> Signals {
        let clean = MessageText.clean(text)
        let norm = PlanTimeParser.normalize(clean)
        var promo = 0.0, commit = 0.0
        var names: [String] = []
        for (name, re) in promoPhrases where re.contains(norm) { promo += 1; names.append(name) }
        for (name, re) in commitPhrases where re.contains(norm) { commit += 1; names.append(name) }
        let url = eventLink.firstMatch(in: clean).flatMap { $0.group(1) }.flatMap(Self.url)
        let hasOrder = orderLink.contains(clean)
        if url != nil { promo += 1; names.append("ticket link") }
        if hasOrder { commit += 1.5; names.append("order link") }
        if capsRatio(clean) > 0.6 { promo += 0.5; names.append("shouting caps") }
        if clean.contains("🚨") || clean.contains("🎟") || clean.contains("🔥") { promo += 0.25 }
        return Signals(promo: promo, commit: commit, names: names, eventURL: url, hasOrderLink: hasOrder)
    }

    static func url(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?)"))
        return URL(string: trimmed.lowercased().hasPrefix("http") ? trimmed : "https://" + trimmed)
    }

    // MARK: Rule stage

    /// Rules only. Sure verdicts have confidence ≥ 0.8; the AI is asked about the rest.
    public func classifyWithRules(_ message: ChatMessage) -> MessageClassification {
        let s = Self.signals(in: message.text)
        let norm = PlanTimeParser.normalize(message.text)
        if s.commit > 0, s.commit >= s.promo - 0.5 {
            return MessageClassification(intent: .plan, confidence: min(0.95, 0.6 + 0.15 * s.commit), signals: s.names)
        }
        if s.promo >= 1.5 || (s.promo >= 1 && s.commit == 0 && s.eventURL != nil) {
            let confidence = min(0.97, 0.6 + 0.12 * s.promo)
            return MessageClassification(intent: .ticketDrop, confidence: confidence, signals: s.names,
                                         ticketDrop: ticketDrop(from: message, signals: s))
        }
        if PlanExtractor.hasIntent(norm), timeParser.parse(norm, relativeTo: message.date) != nil {
            return MessageClassification(intent: .plan, confidence: 0.55, signals: s.names + ["plan wording with a time"])
        }
        return MessageClassification(intent: .noise, confidence: s.promo > 0 ? 0.5 : 0.7, signals: s.names)
    }

    /// True when the rules are sure enough that the AI can't overrule them.
    public static func isVeto(_ c: MessageClassification) -> Bool { c.intent == .ticketDrop && c.confidence >= 0.75 }

    static let titleNoise = PlanRegex(#"\b(?:new|event|events|on sale|now|tickets?|are|is|live|out|available|just announced|announced|announcing|early ?bird|limited|get|your|ur|here|buy|grab|selling fast|final release|tonight|tomorrow|(?:mon|tues?|wed(?:nes)?|thu(?:rs?)?|fri|sat(?:ur)?|sun)(?:day)?|\d{1,2}(?:[:.]\d{2})?\s*(?:am|pm)?)\b|[—–\-:!|•🚨🎟🔥✨]+"#)

    func ticketDrop(from message: ChatMessage, signals s: Signals) -> TicketDrop {
        let clean = MessageText.clean(message.text)
        let time = timeParser.parse(PlanTimeParser.normalize(clean), relativeTo: message.date)
        let venue = PlanExtractor.location(in: clean)
        return TicketDrop(title: Self.dropTitle(clean, venue: venue), eventStart: time?.start, venue: venue,
                          buyURL: s.eventURL, provider: s.eventURL.flatMap { TicketEmailParser.provider(from: $0.host ?? "") },
                          quote: String(clean.prefix(300)), source: message.source, receivedAt: message.date)
    }

    /// "NEW TP EVENT ON SALE — Thursday…" → "TP Event". Falls back to the venue or "Tickets on sale".
    static func dropTitle(_ text: String, venue: String?) -> String {
        let firstClause = text.split(whereSeparator: { "\n—–.|".contains($0) }).first.map(String.init) ?? text
        let hadEvent = firstClause.range(of: "event", options: .caseInsensitive) != nil
        let stripped = titleNoise.regex.stringByReplacingMatches(
            in: firstClause, range: NSRange(firstClause.startIndex..., in: firstClause), withTemplate: " ")
        let words = stripped.split(whereSeparator: { $0.isWhitespace }).prefix(6).map { w -> String in
            let s = String(w)
            if s.count <= 3, s == s.uppercased() { return s }   // "TP", "UV", "DJ"
            return s.prefix(1).uppercased() + s.dropFirst().lowercased()
        }
        guard !words.isEmpty, words.joined().count >= 2 else { return venue.map { "Event at \($0)" } ?? "Tickets on sale" }
        return words.joined(separator: " ") + (hadEvent && words.count <= 2 ? " Event" : "")
    }

    // MARK: AI stage

    struct AIVerdict: Decodable {
        var intent: String
        var confidence: Double?
        var event_title: String?
        var event_start: String?
        var venue: String?
        var buy_url: String?
    }

    static let systemPrompt = """
        You classify one chat message for a university student's calendar assistant.
        intent is one of:
        "plan": the student is actually going to something (they or a friend confirmed, "see you at", \
        tickets were bought, an order confirmation).
        "ticket_drop": a promotion, ticket release, on-sale alert, lineup announcement or event advert, \
        even if it gives a day and time. Nobody has committed to going.
        "noise": anything else.
        Times are UK local time (Europe/London), resolved from the message timestamp.
        Reply with only JSON: {"intent":"ticket_drop","confidence":0.9,"event_title":"TP Thursday",\
        "event_start":"2026-10-15T21:00","venue":null,"buy_url":"https://fixr.co/event/…"}
        """

    /// Rules first; the AI is asked only when the rules aren't sure, and can't overrule a veto.
    public func classify(_ message: ChatMessage) async -> MessageClassification {
        let rules = classifyWithRules(message)
        guard let router, rules.confidence < 0.8 else { return rules }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.timeZone = timeParser.timeZone
        f.dateFormat = "EEE d MMM yyyy HH:mm"
        let prompt = "[\(f.string(from: message.date))] \(message.isFromMe ? "Me" : message.sender): \(message.text)"
        let request = LLMRequest(messages: [.system(Self.systemPrompt), .user(prompt)], purpose: purpose, json: true, temperature: 0)
        guard let verdict = try? await router.completeJSON(AIVerdict.self, request),
              let intent = MessageIntent(rawValue: verdict.intent.lowercased()) else { return rules }
        return merge(rules: rules, ai: verdict, intent: intent, message: message)
    }

    func merge(rules: MessageClassification, ai: AIVerdict, intent: MessageIntent, message: ChatMessage) -> MessageClassification {
        if Self.isVeto(rules) { return rules }
        let confidence = min(1, max(0, ai.confidence ?? 0.6))
        var out = MessageClassification(intent: intent, confidence: confidence, signals: rules.signals + ["AI"], usedAI: true)
        if intent == .ticketDrop {
            var drop = rules.ticketDrop ?? ticketDrop(from: message, signals: Self.signals(in: message.text))
            if let t = ai.event_title, !t.isEmpty { drop.title = t }
            if let s = ai.event_start, let d = FlexibleDate.parse(s, timeZone: timeParser.timeZone) ?? ISO8601.parse(s) { drop.eventStart = d }
            if let v = ai.venue, !v.isEmpty { drop.venue = v }
            if drop.buyURL == nil, let u = ai.buy_url.flatMap(Self.url) { drop.buyURL = u }
            out.ticketDrop = TicketDrop(title: drop.title, eventStart: drop.eventStart, venue: drop.venue, buyURL: drop.buyURL,
                                        provider: drop.provider, quote: drop.quote, source: drop.source, receivedAt: drop.receivedAt)
        }
        return out
    }
}
