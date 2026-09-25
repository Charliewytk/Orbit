import Foundation

/// Plans found in some messages, plus whether the AI stage ran.
public struct PlanExtractionResult: Sendable {
    public var plans: [ExtractedPlan]
    /// True if at least one AI call succeeded.
    public var usedAI: Bool
    /// Set when the AI stage failed and only the rule stage's plans are returned.
    public var aiError: String?

    public init(plans: [ExtractedPlan], usedAI: Bool, aiError: String? = nil) {
        self.plans = plans; self.usedAI = usedAI; self.aiError = aiError
    }
}

/// Finds plans ("Dinner w/ Sam, Sat 7pm") in chat messages, in two stages:
///
/// 1. **Rules**: a message with a plan phrase ("let's", "fancy", "dinner",
///    "pub"…) and a date/time (`PlanTimeParser`) becomes a candidate. The next
///    few messages raise confidence when someone agrees ("yes", "I'm in", 👍) and
///    sink it when someone cancels ("can't", "raincheck"). Plans only others
///    proposed that you never agreed to score lower.
/// 2. **AI**: each window of messages that mentions a plan is sent to the
///    `LLMRouter` (purpose `.privateData` by default, so personal messages stay on
///    the Mac) and the JSON answer is merged with the rule candidates.
///
/// If the AI is unavailable the rule stage's plans are returned on their own.
public struct PlanExtractor: Sendable {
    public var router: LLMRouter?
    /// `.privateData` keeps messages on the Mac (Ollama only). Override to allow cloud models.
    public var purpose: LLMPurpose
    public var timeParser: PlanTimeParser
    /// Only messages from the last N days are read.
    public var maxDays: Int
    /// Plans below this confidence are dropped.
    public var minConfidence: Double
    /// Keep plans that have already happened (relative to `now`).
    public var includePastPlans: Bool
    /// Messages per AI request.
    public var aiWindowSize: Int
    public var now: @Sendable () -> Date

    public init(router: LLMRouter? = nil, purpose: LLMPurpose = .privateData,
                timeZone: TimeZone = TimeZone(identifier: "Europe/London")!, maxDays: Int = 30,
                minConfidence: Double = 0.25, includePastPlans: Bool = false, aiWindowSize: Int = 40,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.router = router; self.purpose = purpose; self.timeParser = PlanTimeParser(timeZone: timeZone)
        self.maxDays = maxDays; self.minConfidence = minConfidence; self.includePastPlans = includePastPlans
        self.aiWindowSize = aiWindowSize; self.now = now
    }

    // MARK: - Entry points

    /// A single message or pasted snippet from the share sheet. Pasted WhatsApp
    /// lines ("[14/10/2026, 19:32] Sam: …") are split into messages first.
    public func extract(fromSharedText text: String, sentAt: Date? = nil, sender: String? = nil,
                        myNames: Set<String> = []) async -> [ExtractedPlan] {
        var messages = WhatsAppExportParser(myNames: myNames, timeZone: timeParser.timeZone).parse(text, conversation: "Shared")
        if messages.isEmpty {
            messages = [ChatMessage(sender: sender ?? "Them", date: sentAt ?? now(), text: text,
                                    isFromMe: sender.map { MessageText.isMe($0, myNames: myNames) } ?? false,
                                    source: .shared, conversation: "Shared")]
        }
        return await analyze(messages, source: .shared).plans
    }

    /// A chat export or iMessage history. Only messages after `since` (and within
    /// the last `maxDays`) are read; several conversations may be mixed.
    public func extract(from chat: [ChatMessage], since: Date? = nil) async -> [ExtractedPlan] {
        await analyze(chat, since: since).plans
    }

    /// A screenshot of a chat (e.g. Instagram DMs): OCR, rebuild the bubbles, then extract.
    public func extract(fromScreenshot image: Data, ocr: OCREngine, takenAt: Date? = nil) async throws -> [ExtractedPlan] {
        let result = try await ocr.recognize(image: image, hint: "chat screenshot")
        let messages = Self.messages(fromOCR: result, takenAt: takenAt ?? now(), parser: timeParser)
        return await analyze(messages, source: .screenshot).plans
    }

    /// Full pipeline with AI status. `source` overrides the messages' own source.
    public func analyze(_ messages: [ChatMessage], since: Date? = nil, source: MessageSource? = nil) async -> PlanExtractionResult {
        let now = self.now()
        let cutoff = max(since ?? .distantPast, now.addingTimeInterval(-Double(maxDays) * 86400))
        let groups = Dictionary(grouping: messages) { $0.conversation ?? "" }

        var found: [Candidate] = []
        var usedAI = false
        var aiError: String?
        for key in groups.keys.sorted() {
            let chat = groups[key]!.sorted { $0.date < $1.date }
            guard chat.contains(where: { $0.date > cutoff }) else { continue }
            let rules = ruleCandidates(in: chat, since: cutoff, source: source)
            var ai: [ExtractedPlan] = []
            if router != nil {
                do {
                    ai = try await aiPlans(in: chat.filter { $0.date > cutoff }, source: source, now: now)
                    usedAI = true
                } catch {
                    aiError = "\(error)"
                }
            }
            found += Self.merge(rules: rules, ai: ai)
        }

        let plans = Self.dedupe(found).map(\.plan).filter {
            $0.confidence >= minConfidence && (includePastPlans || ($0.end ?? $0.start) >= now.addingTimeInterval(-3600))
        }
        return PlanExtractionResult(plans: plans.sorted { $0.start < $1.start }, usedAI: usedAI, aiError: aiError)
    }

    // MARK: - Rule stage

    /// A plan plus whether the conversation cancelled it (kept so the AI can't revive it).
    struct Candidate {
        var plan: ExtractedPlan
        var cancelled = false
    }

    static let strongIntent = PlanRegex(#"\b(?:let'?s|shall we|should we|wanna|want to|fancy|are (?:you|u) free|(?:you|u|r u) free|free (?:on|this|tomorrow|tonight)|see (?:you|u|ya)|meet(?:ing)?|up for|down for|how about|what about|come (?:to|round|over)|join us|(?:are )?(?:you|u) coming|booked|book a table|table for)\b"#)
    static let activity = PlanRegex(#"\b(?:dinner|drinks|pub|gym|cinema|lunch|brunch|breakfast|coffee|party|pres|lecture|seminar|study session|library|call|birthday|bday|match|footie|night out|revision)\b"#)
    static let confirmation = PlanRegex(#"(?:^|\b)(?:yes+|yess*|yeah+|yea|yep|yup|yh|ye|ya|sure|sounds? (?:good|great|perfect|lovely|fun)|deal|i'?m in|im in|count me in|i'?m down|im down|down|perfect|great|lovely|done|defo|definitely|can do|ok(?:ay)?|kk|see (?:you|u|ya) (?:then|there)|looking forward|can'?t wait|go on then|why not|love (?:that|to)|works for me|that works|booked it)\b"#)
    static let confirmationEmoji: [String] = ["👍", "👌", "🙌", "✅", "🥳", "🤝"]
    static let cancellation = PlanRegex(#"\b(?:can'?t(?! wait)|cannot|can not|cancel(?:led|ling)?|rain ?check|another time|not any ?more|no longer|won'?t make it|not gonna make|not going to make|(?:have to|gonna|need to) bail|postpone|rearrange|reschedule|next time|not tonight|not today|(?<!not )busy|double booked|something came up|can'?t make it)\b"#)

    static let clauseBreak = PlanRegex(#"[,.;!?]|\b(?:how about|what about|instead|but|or)\b"#)

    static func hasIntent(_ normalized: String) -> Bool {
        strongIntent.contains(normalized) || activity.contains(normalized) || PlanKind.detect(in: normalized) != .other
    }

    static func isConfirmation(_ normalized: String) -> Bool {
        !cancellation.contains(normalized)
            && (confirmation.contains(normalized) || confirmationEmoji.contains { normalized.contains($0) })
    }

    /// Stage 1: plans found with rules only. `messages` should be one conversation, oldest first.
    public func ruleCandidates(in messages: [ChatMessage], since: Date? = nil) -> [ExtractedPlan] {
        Self.dedupe(ruleCandidates(in: messages, since: since, source: nil)).map(\.plan)
    }

    func ruleCandidates(in messages: [ChatMessage], since: Date?, source: MessageSource?) -> [Candidate] {
        let iAmInChat = messages.contains(where: \.isFromMe)
        var out: [Candidate] = []
        for (i, msg) in messages.enumerated() where msg.date > (since ?? .distantPast) {
            var text = PlanTimeParser.normalize(msg.text)
            guard Self.hasIntent(text) else { continue }

            // "can't do sat, sun at 7?" cancels one plan and proposes another: parse what follows.
            let cancel = Self.cancellation.matches(in: text).last
            var quote = msg.text
            var time: PlanTime?
            if let cancel {
                // Use the last clause after the cancellation that has a time ("…, how about sun at 7?").
                let rest = String(text[cancel.range.upperBound...])
                let clauses = Self.clauseBreak.regex.stringByReplacingMatches(
                    in: rest, range: NSRange(rest.startIndex..., in: rest), withTemplate: "|").split(separator: "|")
                time = clauses.reversed().lazy.compactMap { timeParser.parse(String($0), relativeTo: msg.date) }.first
                guard time != nil else { continue }
                text = rest
            } else {
                time = timeParser.parse(text, relativeTo: msg.date)
            }
            if time == nil, !Self.isConfirmation(text) {
                // The time often comes in the next message ("dinner this week?" → "sat 7?").
                for next in messages[(i + 1)..<min(messages.count, i + 3)] where next.date.timeIntervalSince(msg.date) < 2 * 3600 {
                    if let t = timeParser.parse(next.text, relativeTo: next.date) {
                        time = t; quote += "\n" + next.text; break
                    }
                }
            }
            guard let time else { continue }
            var start = time.start

            // Conversation window around the proposal.
            let before = messages[max(0, i - 3)..<i].filter { msg.date.timeIntervalSince($0.date) < 12 * 3600 }
            let after = messages[(i + 1)..<min(messages.count, i + 7)].filter { $0.date.timeIntervalSince(msg.date) < 48 * 3600 }

            var agreed: [ChatMessage] = []
            var cancelled = false
            var timeConfidence = time.confidence
            var involved = before + [msg]
            for n in after {
                let nt = PlanTimeParser.normalize(n.text)
                if Self.cancellation.contains(nt) { cancelled = true; break }
                if let other = timeParser.parse(nt, relativeTo: n.date) {
                    // A different day or time means the talk moved on to another plan.
                    if other.hasDate, other.hasTime ? abs(other.start.timeIntervalSince(start)) > 2 * 3600
                        : !timeParser.calendar.isDate(other.start, inSameDayAs: start) { break }
                    if other.hasTime, !other.hasDate, !time.hasTime,
                       let refined = refine(start, withClockOf: other.start) {
                        // "brunch sunday?" → "11ish?": same day, now with a time.
                        start = refined
                        timeConfidence = max(timeConfidence, other.confidence)
                    }
                }
                involved.append(n)
                if n.sender != msg.sender, Self.isConfirmation(nt) { agreed.append(n) }
            }
            // A reply that agrees to someone else's suggestion ("yes! dinner sat 7?") counts for both.
            if let prev = before.last, prev.sender != msg.sender, Self.hasIntent(PlanTimeParser.normalize(prev.text)),
               Self.isConfirmation(text) {
                agreed.append(prev)
            }

            var confidence = 0.3 + 0.4 * timeConfidence
            if Self.strongIntent.contains(text) { confidence += 0.1 }
            var kind = PlanKind.detect(in: quote)
            if kind == .other, let earlier = before.reversed().map({ PlanKind.detect(in: $0.text) }).first(where: { $0 != .other }) {
                kind = earlier   // "dinner sat?" … "can't do sat, sun at 7?"
            }
            if kind != .other { confidence += 0.05 }
            if msg.isFromMe { confidence += 0.05 }
            if !agreed.isEmpty { confidence += 0.2 }
            let iAgreed = msg.isFromMe || agreed.contains(where: \.isFromMe)
            if iAmInChat && !iAgreed { confidence *= 0.7 }
            if cancelled { confidence = min(confidence, 0.3) * 0.4 }

            var people: [String] = []
            for m in involved where !m.isFromMe && !people.contains(m.sender) && !Self.isPlaceholderSender(m.sender) {
                people.append(m.sender)
            }
            for name in Self.namesMentioned(in: msg.text) where !people.contains(name) { people.append(name) }

            let end = time.end.map { start.addingTimeInterval($0.timeIntervalSince(time.start)) }
            let plan = ExtractedPlan(title: Self.title(kind: kind, people: people), start: start, end: end,
                                     location: Self.location(in: msg.text), people: people,
                                     source: source ?? msg.source, quote: String(quote.prefix(300)),
                                     confidence: min(0.99, max(0.01, (confidence * 100).rounded() / 100)))
            out.append(Candidate(plan: plan, cancelled: cancelled))
        }
        return out
    }

    /// `day`'s date at the clock time of `clock`.
    func refine(_ day: Date, withClockOf clock: Date) -> Date? {
        let cal = timeParser.calendar
        let hm = cal.dateComponents([.hour, .minute], from: clock)
        return cal.date(bySettingHour: hm.hour ?? 12, minute: hm.minute ?? 0, second: 0, of: day)
    }

    static func isPlaceholderSender(_ s: String) -> Bool { ["them", "unknown", "me"].contains(s.lowercased()) }

    static func title(kind: PlanKind, people: [String]) -> String {
        guard !people.isEmpty else { return kind == .other ? "Plan" : kind.label }
        let shown = people.prefix(3).joined(separator: ", ") + (people.count > 3 ? " +\(people.count - 3)" : "")
        return "\(kind.label) with \(shown)"
    }

    static let dayAndMonthWords: Set<String> = [
        "mon", "monday", "tue", "tues", "tuesday", "wed", "weds", "wednesday", "thu", "thur", "thurs", "thursday",
        "fri", "friday", "sat", "saturday", "sun", "sunday", "jan", "january", "feb", "february", "mar", "march",
        "apr", "april", "may", "jun", "june", "jul", "july", "aug", "august", "sep", "sept", "september", "oct",
        "october", "nov", "november", "dec", "december", "i", "me", "you", "us", "the", "noon", "midday", "midnight",
        "tonight", "tomorrow", "today", "half", "quarter", "lol", "haha", "ok", "home", "uni",
    ]
    static let locationPattern = PlanRegex(#"(?:\b(?:[Aa]t|[Ii]n)\s+|@\s*)((?:[Tt]he\s+)?\p{Lu}[\p{L}\d'’&\-]*(?:\s+\p{Lu}[\p{L}\d'’&\-]*){0,3})"#, caseInsensitive: false)
    static let withPattern = PlanRegex(#"\b(?:with|w/)\s+(\p{Lu}[\p{L}'’\-]+)"#, caseInsensitive: false)

    /// A capitalised place after "at"/"in"/"@": "dinner at Côte", "drinks at The Old Firehouse".
    static func location(in text: String) -> String? {
        for m in locationPattern.matches(in: MessageText.clean(text)) {
            guard let place = m.group(1) else { continue }
            let first = place.split(separator: " ").first.map { $0.lowercased() } ?? ""
            let firstReal = first == "the" ? (place.split(separator: " ").dropFirst().first.map { $0.lowercased() } ?? "") : first
            if dayAndMonthWords.contains(firstReal) { continue }
            return place.trimmingCharacters(in: CharacterSet(charactersIn: "'’-&").union(.whitespaces))
        }
        return nil
    }

    static func namesMentioned(in text: String) -> [String] {
        withPattern.matches(in: MessageText.clean(text)).compactMap { m in
            guard let name = m.group(1), !dayAndMonthWords.contains(name.lowercased()) else { return nil }
            return name
        }
    }

    // MARK: - AI stage

    struct AIResponse: Decodable {
        let plans: [AIPlan]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            plans = (try? c.decode([AIPlan].self, forKey: .plans)) ?? []
        }
        enum Key: String, CodingKey { case plans }
    }

    struct AIPlan: Decodable {
        var title: String
        var start: String
        var end: String?
        var location: String?
        var people: [String]
        var confirmed: Bool?
        var confidence: Double?
        var quote: String?

        enum Key: String, CodingKey { case title, start, end, location, people, confirmed, confidence, quote }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            title = (try? c.decode(String.self, forKey: .title)) ?? ""
            start = try c.decode(String.self, forKey: .start)
            end = try? c.decode(String.self, forKey: .end)
            location = try? c.decode(String.self, forKey: .location)
            people = (try? c.decode([String].self, forKey: .people)) ?? []
            confirmed = (try? c.decode(Bool.self, forKey: .confirmed))
                ?? (try? c.decode(String.self, forKey: .confirmed)).map { $0.lowercased() == "true" }
            confidence = (try? c.decode(Double.self, forKey: .confidence))
                ?? (try? c.decode(String.self, forKey: .confidence)).flatMap(Double.init)
            quote = try? c.decode(String.self, forKey: .quote)
        }
    }

    static let systemPrompt = """
        You find plans in a university student's chat messages: meet-ups, meals, drinks, parties, \
        sport, calls, study sessions and lectures that have a day or time.
        Times are UK local time (Europe/London). Resolve relative dates ("tomorrow", "sat", "next fri") \
        from the timestamp of the message that says them, not from today. UK phrasing: "half 7" means 7:30.
        Skip plans that were cancelled or turned down. Set "confirmed" true only if both sides agreed.
        Reply with only JSON in this shape:
        {"plans":[{"title":"Dinner with Sam","start":"2026-10-17T19:00","end":null,"location":null,\
        "people":["Sam"],"confirmed":true,"confidence":0.9,"quote":"exact words from the message"}]}
        "start"/"end" are local times without a zone. "people" never includes the user ("Me"). \
        If there are no plans reply {"plans":[]}.
        """

    /// Stage 2: asks the AI about every window of messages that mentions a plan.
    func aiPlans(in messages: [ChatMessage], source: MessageSource?, now: Date) async throws -> [ExtractedPlan] {
        guard let router, !messages.isEmpty else { return [] }
        let size = max(5, aiWindowSize)
        let step = max(1, size - 5)
        var plans: [ExtractedPlan] = []
        var start = 0
        while start < messages.count {
            let window = Array(messages[start..<min(messages.count, start + size)])
            if window.contains(where: { Self.hasIntent(PlanTimeParser.normalize($0.text)) }) {
                let request = LLMRequest(messages: [.system(Self.systemPrompt), .user(prompt(for: window, now: now))],
                                         purpose: purpose, json: true, temperature: 0.1)
                let response = try await router.completeJSON(AIResponse.self, request)
                plans += response.plans.compactMap { toPlan($0, window: window, source: source) }
            }
            if start + size >= messages.count { break }
            start += step
        }
        return plans
    }

    func prompt(for window: [ChatMessage], now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.timeZone = timeParser.timeZone
        f.dateFormat = "EEEE d MMMM yyyy"
        var text = "Today is \(f.string(from: now)).\nMessages (oldest first):\n"
        f.dateFormat = "EEE d MMM yyyy HH:mm"
        for m in window {
            let who = m.isFromMe ? (Self.isPlaceholderSender(m.sender) ? "Me" : "Me (\(m.sender))") : m.sender
            text += "[\(f.string(from: m.date))] \(who): \(m.text.replacingOccurrences(of: "\n", with: " "))\n"
        }
        return text
    }

    func toPlan(_ p: AIPlan, window: [ChatMessage], source: MessageSource?) -> ExtractedPlan? {
        guard let start = parseModelDate(p.start),
              let first = window.first?.date, let last = window.last?.date,
              start > first.addingTimeInterval(-86400), start < last.addingTimeInterval(400 * 86400) else { return nil }
        var end = p.end.flatMap(parseModelDate)
        if let e = end, e <= start { end = nil }
        let myNames = Set(window.filter(\.isFromMe).map { MessageText.nameKey($0.sender) } + ["me"])
        let people = p.people.filter { !myNames.contains(MessageText.nameKey($0)) && !$0.isEmpty }
        let title = p.title.trimmingCharacters(in: .whitespaces).isEmpty
            ? Self.title(kind: PlanKind.detect(in: p.quote ?? ""), people: people) : p.title
        var confidence = min(1, max(0, p.confidence ?? 0.6))
        if p.confirmed == false { confidence *= 0.75 }
        return ExtractedPlan(title: title, start: start, end: end, location: p.location.flatMap { $0.isEmpty ? nil : $0 },
                             people: people, source: source ?? window.first?.source ?? .shared,
                             quote: p.quote ?? "", confidence: (confidence * 100).rounded() / 100)
    }

    /// Model dates are local ("2026-10-17T19:00"); zoned ISO strings are accepted too.
    func parseModelDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return FlexibleDate.parse(t, timeZone: timeParser.timeZone) ?? ISO8601.parse(t)
    }

    // MARK: - Merging

    static func samePlan(_ a: ExtractedPlan, _ b: ExtractedPlan) -> Bool {
        guard abs(a.start.timeIntervalSince(b.start)) <= 2 * 3600 else { return false }
        if PlanTitleMatch.similar(a.title, b.title) { return true }
        let ka = PlanKind.detect(in: a.title), kb = PlanKind.detect(in: b.title)
        return ka == kb && (ka != .other || !Set(a.people).isDisjoint(with: b.people))
    }

    /// Joins AI plans with rule candidates: agreement boosts confidence; a plan the
    /// rules saw cancelled stays low even if the AI kept it.
    static func merge(rules: [Candidate], ai: [ExtractedPlan]) -> [Candidate] {
        var pool = rules
        var out: [Candidate] = []
        for a in ai {
            if let j = pool.firstIndex(where: { samePlan($0.plan, a) }) {
                let r = pool.remove(at: j)
                var merged = a
                merged.people = a.people + r.plan.people.filter { !a.people.contains($0) }
                merged.location = a.location ?? r.plan.location
                if merged.quote.isEmpty { merged.quote = r.plan.quote }
                merged.confidence = r.cancelled ? min(a.confidence, r.plan.confidence + 0.1)
                    : min(0.99, max(a.confidence, r.plan.confidence) + 0.1)
                out.append(Candidate(plan: merged, cancelled: r.cancelled))
            } else {
                out.append(Candidate(plan: a))
            }
        }
        return out + pool
    }

    /// Collapses repeats (same plan found twice, overlapping AI windows), keeping the most confident.
    static func dedupe(_ candidates: [Candidate]) -> [Candidate] {
        var kept: [Candidate] = []
        for c in candidates.sorted(by: { $0.plan.confidence > $1.plan.confidence }) {
            if let i = kept.firstIndex(where: { samePlan($0.plan, c.plan) }) {
                kept[i].plan.people += c.plan.people.filter { !kept[i].plan.people.contains($0) }
                kept[i].plan.location = kept[i].plan.location ?? c.plan.location
                kept[i].cancelled = kept[i].cancelled || c.cancelled
            } else {
                kept.append(c)
            }
        }
        return kept
    }

    // MARK: - Screenshots

    static let trailingTime = PlanRegex(#"\s*(\d{1,2})[:.](\d{2})(?:\s*([ap])\.?m\.?)?\s*[✓✔√]*\s*$"#)
    static let noiseLine = PlanRegex(#"^(?:today|yesterday|seen|delivered|read|sent|typing…?|typing\.\.\.|active now|active \d+\s?[mh] ago|message…?|imessage|text message|online|last seen.*|\d{1,2} (?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]* \d{4})$"#)

    /// Rebuilds chat messages from OCR lines. Each line is a message; a time at the
    /// end ("sat 7pm? 19:32") is its timestamp, and lines on the right half of
    /// the screen (when boxes are known) are yours.
    public static func messages(fromOCR result: OCRResult, takenAt: Date,
                                parser: PlanTimeParser = PlanTimeParser()) -> [ChatMessage] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = parser.timeZone
        var out: [ChatMessage] = []
        var current = takenAt
        for (i, line) in result.lines.enumerated() {
            var text = MessageText.clean(line.text).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !noiseLine.contains(text) else { continue }
            var stamped = false
            if let m = trailingTime.firstMatch(in: text), let h = Int(m.group(1) ?? ""), let mi = Int(m.group(2) ?? ""),
               h <= 23, mi <= 59 {
                let hour = m.group(3).map { PlanTimeParser.apply($0.lowercased(), to: h) } ?? h
                if var d = cal.date(bySettingHour: hour, minute: mi, second: 0, of: takenAt) {
                    if d > takenAt.addingTimeInterval(300) { d = cal.date(byAdding: .day, value: -1, to: d) ?? d }
                    current = d; stamped = true
                }
                text = String(text[..<m.range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            if text.isEmpty {
                // A time on its own line belongs to the bubble above it.
                if stamped, !out.isEmpty { out[out.count - 1].date = current }
                continue
            }
            let mine = (line.box?.first).map { $0 > 0.4 } ?? false
            out.append(ChatMessage(id: "ocr-\(i)", sender: mine ? "Me" : "Them", date: current, text: text,
                                   isFromMe: mine, source: .screenshot, conversation: "Screenshot"))
        }
        return out
    }
}
