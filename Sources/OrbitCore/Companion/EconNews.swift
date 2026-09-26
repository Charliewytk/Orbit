import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct NewsStory: Codable, Hashable, Sendable, Identifiable {
    public enum Origin: String, Codable, Sendable { case rss, newsletter }
    public var id: String
    public var title: String
    public var summary: String
    public var url: String?
    public var source: String
    public var published: Date?
    public var origin: Origin
    /// Full text when fetched with the student's own logged-in session (never stored off the Mac).
    public var fullText: String?

    public init(id: String? = nil, title: String, summary: String, url: String?, source: String, published: Date?,
                origin: Origin = .rss, fullText: String? = nil) {
        self.id = id ?? MD5.hex((url ?? "") + "|" + title)
        self.title = title; self.summary = summary; self.url = url; self.source = source
        self.published = published; self.origin = origin; self.fullText = fullText
    }
}

/// A news story tied to what the student is studying.
public struct LinkedStory: Codable, Hashable, Sendable, Identifiable {
    public var id: String { story.id }
    public var story: NewsStory
    public var moduleCode: String?
    public var concepts: [String]
    public var score: Double
    /// "Why this matters for BEE1025: …"
    public var angle: String
}

public enum NewsFeeds {
    public struct Feed: Codable, Hashable, Sendable, Identifiable {
        public var id: String { url }
        public var name: String
        public var url: String
        public init(name: String, url: String) { self.name = name; self.url = url }
    }

    /// Public RSS feeds, no accounts needed.
    public static let defaults: [Feed] = [
        Feed(name: "BBC Business", url: "https://feeds.bbci.co.uk/news/business/rss.xml"),
        Feed(name: "Financial Times", url: "https://www.ft.com/rss/home/uk"),
        Feed(name: "The Economist", url: "https://www.economist.com/finance-and-economics/rss.xml"),
        Feed(name: "Bank of England", url: "https://www.bankofengland.co.uk/rss/news"),
        Feed(name: "ONS", url: "https://www.ons.gov.uk/releasecalendar/rss"),
    ]

    /// Newsletter senders recognised in the student's own mail.
    public static let newsletterDomains = ["ft.com", "economist.com", "e.economist.com", "email.ft.com"]

    public static func isNewsletter(from: String) -> Bool {
        let f = from.lowercased()
        return newsletterDomains.contains { f.contains("@\($0)") || f.contains(".\($0)") }
    }
}

/// RSS 2.0 and Atom parsing.
public enum RSSParser {
    public static func parse(_ data: Data, source: String) -> [NewsStory] {
        let delegate = RSSDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.items.compactMap { i in
            let title = HTMLToText.convert(i["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let summary = HTMLToText.convert(i["description"] ?? i["summary"] ?? i["content"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let date = (i["pubDate"] ?? i["published"] ?? i["updated"] ?? i["dc:date"]).flatMap(parseDate)
            return NewsStory(title: title, summary: String(summary.prefix(600)), url: i["link"] ?? i["guid"], source: source, published: date)
        }
    }

    static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: t) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for p in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            f.dateFormat = p
            if let d = f.date(from: t) { return d }
        }
        return nil
    }
}

final class RSSDelegate: NSObject, XMLParserDelegate {
    var items: [[String: String]] = []
    private var current: [String: String]?
    private var element = ""
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if name == "item" || name == "entry" { current = [:] }
        element = name
        buffer = ""
        if name == "link", current != nil, let href = attributes["href"], current?["link"] == nil { current?["link"] = href }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { buffer += String(decoding: CDATABlock, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "item" || name == "entry" {
            if let c = current { items.append(c) }
            current = nil
        } else if current != nil {
            let v = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = qualifiedName ?? name
            if !v.isEmpty && current?[key] == nil { current?[key] = v }
            if !v.isEmpty && current?[name] == nil { current?[name] = v }
        }
        buffer = ""
    }
}

/// Stories from the student's own FT / Economist newsletter emails (already in their mail; no passwords).
public enum NewsletterStories {
    /// Splits a newsletter body into headline-like lines with the link that follows each.
    public static func extract(subject: String, from: String, body: String, date: Date, limit: Int = 8) -> [NewsStory] {
        let source = from.lowercased().contains("economist") ? "The Economist (newsletter)" : "Financial Times (newsletter)"
        let lines = body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [NewsStory] = []
        var i = 0
        while i < lines.count && out.count < limit {
            let line = lines[i]
            let isHeadline = line.count >= 25 && line.count <= 160 && !line.hasPrefix("http") && line.first?.isUppercase == true
                && !line.lowercased().contains("unsubscribe") && !line.lowercased().contains("view in browser")
                && line.split(separator: " ").count >= 4
            if isHeadline {
                let next = lines[(i + 1)..<min(lines.count, i + 4)]
                let link = next.first { $0.hasPrefix("http") }
                let blurb = next.first { !$0.hasPrefix("http") && $0.count > 40 } ?? ""
                if link != nil || !blurb.isEmpty {
                    out.append(NewsStory(title: line, summary: blurb, url: link, source: source, published: date, origin: .newsletter))
                }
            }
            i += 1
        }
        if out.isEmpty { out.append(NewsStory(title: subject, summary: "", url: nil, source: source, published: date, origin: .newsletter)) }
        return out
    }
}

/// Links stories to modules and economics concepts, and picks the day's three.
public struct NewsLinker: Sendable {
    /// Concept → keywords. Deliberately first-year economics.
    public static let concepts: [String: [String]] = [
        "inflation": ["inflation", "cpi", "price rises", "prices rose", "cost of living"],
        "monetary policy": ["interest rate", "bank rate", "base rate", "rate cut", "rate rise", "bank of england", "federal reserve", "ecb", "quantitative"],
        "fiscal policy": ["budget", "tax", "spending review", "borrowing", "deficit", "chancellor", "public finances"],
        "labour market": ["unemployment", "jobs", "wages", "pay growth", "employment", "strike", "minimum wage"],
        "GDP and growth": ["gdp", "growth", "recession", "output", "productivity"],
        "trade": ["tariff", "trade", "exports", "imports", "sanctions", "wto"],
        "exchange rates": ["sterling", "pound", "dollar", "euro", "exchange rate", "currency"],
        "market structure": ["monopoly", "competition", "merger", "cma", "antitrust", "cartel", "oligopoly"],
        "supply and demand": ["shortage", "supply", "demand", "prices", "price cap"],
        "externalities": ["carbon", "emissions", "pollution", "climate", "green levy"],
        "financial markets": ["stocks", "shares", "bond", "gilt", "yields", "ftse", "markets"],
        "housing": ["house prices", "mortgage", "rent", "housing"],
        "game theory": ["opec", "negotiation", "bargaining", "price war"],
        "behavioural economics": ["nudge", "behaviour", "consumer confidence", "sentiment"],
    ]

    /// Module code → concepts it teaches (student-editable; these are sensible defaults by name).
    public var moduleConcepts: [String: [String]]

    public init(moduleConcepts: [String: [String]] = [:]) { self.moduleConcepts = moduleConcepts }

    /// Guesses concepts for modules from their names ("Macroeconomics" → monetary/fiscal/GDP…).
    public static func defaultModuleConcepts(_ modules: [Module]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for m in modules {
            let n = m.name.lowercased()
            var c: [String] = []
            if n.contains("macro") { c += ["inflation", "monetary policy", "fiscal policy", "GDP and growth", "labour market", "exchange rates"] }
            if n.contains("micro") || n.contains("principles") { c += ["supply and demand", "market structure", "externalities", "game theory"] }
            if n.contains("math") || n.contains("stat") || n.contains("quantitative") || n.contains("econometric") { c += ["GDP and growth", "financial markets"] }
            if n.contains("finance") || n.contains("money") { c += ["financial markets", "monetary policy", "housing"] }
            if n.contains("behaviour") { c += ["behavioural economics"] }
            if n.contains("trade") || n.contains("international") || n.contains("global") { c += ["trade", "exchange rates"] }
            if c.isEmpty { c = ["supply and demand", "GDP and growth"] }
            out[m.code] = Array(Set(c)).sorted()
        }
        return out
    }

    public func link(_ story: NewsStory, extraTerms: [String: [String]] = [:]) -> LinkedStory {
        let text = (story.title + " " + story.summary).lowercased()
        var hits: [String: Double] = [:]
        for (concept, words) in Self.concepts {
            let n = words.filter { text.contains($0) }.count
            if n > 0 { hits[concept] = Double(n) + (story.title.lowercased().contains(words[0]) ? 1 : 0) }
        }
        for (concept, words) in extraTerms {
            let n = words.filter { text.contains($0.lowercased()) }.count
            if n > 0 { hits[concept, default: 0] += Double(n) * 1.5 }
        }
        let concepts = hits.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        var best: (String, Double)?
        for (code, list) in moduleConcepts {
            let s = list.reduce(0.0) { $0 + (hits[$1] ?? 0) }
            if s > 0, s > (best?.1 ?? 0) || (s == best?.1 && code < best!.0) { best = (code, s) }
        }
        let score = hits.values.reduce(0, +) + (story.origin == .newsletter ? 0.5 : 0)
        let angle: String
        if let c = concepts.first {
            angle = best.map { "Links to \($0.0): a real-world case of \(c)." } ?? "A real-world case of \(c)."
        } else {
            angle = "General economics news."
        }
        return LinkedStory(story: story, moduleCode: best?.0, concepts: Array(concepts.prefix(3)), score: score, angle: angle)
    }

    /// Top `count` stories, recent first among equals, spread across modules and sources, deduplicated by headline.
    public func pick(_ stories: [NewsStory], count: Int = 3, now: Date, maxAgeHours: Double = 48,
                     extraTerms: [String: [String]] = [:], exclude: Set<String> = []) -> [LinkedStory] {
        var seenTitles = Set<String>()
        let fresh = stories.filter { s in
            !exclude.contains(s.id) && (s.published.map { now.timeIntervalSince($0) < maxAgeHours * 3600 } ?? true)
                && seenTitles.insert(s.title.lowercased().prefix(60).description).inserted
        }
        let linked = fresh.map { link($0, extraTerms: extraTerms) }.filter { $0.score > 0 }
            .sorted { ($0.score, $0.story.published ?? .distantPast, $1.id) > ($1.score, $1.story.published ?? .distantPast, $0.id) }
        var out: [LinkedStory] = []
        var usedModules = Set<String>(), usedSources = [String: Int]()
        for pass in 0..<2 {
            for s in linked where out.count < count && !out.contains(s) {
                let mod = s.moduleCode ?? "-"
                if pass == 0 && (usedModules.contains(mod) || usedSources[s.story.source, default: 0] >= 2) { continue }
                out.append(s); usedModules.insert(mod); usedSources[s.story.source, default: 0] += 1
            }
        }
        return out
    }
}

/// Article body from a publisher page fetched with the student's own logged-in session.
public enum ArticleText {
    public static func extract(html: String, maxCharacters: Int = 20_000) -> String {
        var body = html
        if let start = html.range(of: "<article", options: .caseInsensitive),
           let end = html.range(of: "</article>", options: [.caseInsensitive, .backwards]), start.lowerBound < end.lowerBound {
            body = String(html[start.lowerBound..<end.upperBound])
        }
        guard let re = try? NSRegularExpression(pattern: "<p[^>]*>(.*?)</p>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return "" }
        let ns = body as NSString
        let paragraphs = re.matches(in: body, range: NSRange(location: 0, length: ns.length)).map {
            HTMLToText.convert(ns.substring(with: $0.range(at: 1))).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { $0.count > 40 }
        return String(paragraphs.joined(separator: "\n\n").prefix(maxCharacters))
    }
}
