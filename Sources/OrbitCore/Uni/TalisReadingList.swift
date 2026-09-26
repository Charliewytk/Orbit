import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads a Talis Aspire reading list (e.g. `https://rl.talis.com/3/exeter/lists/<id>.html`).
///
/// Talis serves list data as RDF/JSON when ".json" replaces ".html", which is
/// tried first. If that fails, the HTML page is parsed for list items, their
/// importance label ("Essential", "Recommended", "Further") and the section
/// heading they sit under ("Week 3").
public struct TalisReadingList: Sendable {
    public enum Importance: String, Codable, Sendable {
        case essential, recommended, further, unknown

        public init(label: String) {
            let l = label.lowercased()
            if l.contains("essential") || l.contains("core") || l.contains("required") || l.contains("key") { self = .essential }
            else if l.contains("recommend") || l.contains("suggest") { self = .recommended }
            else if l.contains("further") || l.contains("optional") || l.contains("background") || l.contains("additional") { self = .further }
            else { self = .unknown }
        }
    }

    public struct Entry: Codable, Hashable, Sendable {
        public var item: ReadingItem
        public var importance: Importance
        public var section: String?
        public var authors: String?
    }

    public var http: HTTPClient
    public init(http: HTTPClient = HTTPClient(timeout: 30)) { self.http = http }

    /// True for URLs on Talis Aspire (rl.talis.com or <uni>.rl.talis.com).
    public static func isTalisURL(_ s: String) -> Bool { s.lowercased().contains("rl.talis.com") }

    /// The list's `.json` and `.html` addresses.
    public static func urls(for listURL: URL) -> (json: URL, html: URL) {
        var s = listURL.absoluteString
        if let q = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<q]) }
        for ext in [".html", ".json"] where s.hasSuffix(ext) { s.removeLast(ext.count) }
        return (URL(string: s + ".json") ?? listURL, URL(string: s + ".html") ?? listURL)
    }

    /// Finds a module's reading lists on Talis by module code, for when ELE only links
    /// them through a login launch (LTI). Tries the tenancy's module lookup pages.
    public func discoverLists(moduleCode: String, tenant: String = "exeter") async -> [URL] {
        let code = moduleCode.lowercased()
        let candidates = [
            "https://\(tenant).rl.talis.com/modules/\(code)/lists.json",
            "https://rl.talis.com/3/\(tenant)/modules/\(code)/lists.json",
            "https://\(tenant).rl.talis.com/modules/\(code).html",
            "https://rl.talis.com/3/\(tenant)/modules/\(code).html",
        ]
        for c in candidates {
            guard let url = URL(string: c),
                  let data = try? await http.data("GET", url, headers: ["Accept": "application/json, text/html"]) else { continue }
            let found = Self.listURLs(in: String(decoding: data, as: UTF8.self), tenant: tenant)
            if !found.isEmpty { return found }
        }
        return []
    }

    /// List addresses mentioned in a Talis page or RDF/JSON document.
    static func listURLs(in text: String, tenant: String) -> [URL] {
        let pattern = "https?:(?:\\\\?/){2}[a-z0-9.]*rl\\.talis\\.com(?:\\\\?/[a-z0-9]+)*\\\\?/lists\\\\?/[A-Za-z0-9-]+"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [URL] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: m.range).replacingOccurrences(of: "\\/", with: "/")
            if seen.insert(raw.lowercased()).inserted, let u = URL(string: raw) { out.append(u) }
        }
        return out
    }

    public func fetch(listURL: URL, moduleCode: String) async throws -> [Entry] {
        let (jsonURL, htmlURL) = Self.urls(for: listURL)
        if let data = try? await http.data("GET", jsonURL, headers: ["Accept": "application/json"]),
           let entries = try? Self.parseRDFJSON(data, moduleCode: moduleCode), !entries.isEmpty {
            return entries
        }
        let html = try await http.data("GET", htmlURL, headers: ["Accept": "text/html"])
        return Self.parseHTML(String(decoding: html, as: UTF8.self), moduleCode: moduleCode, baseURL: htmlURL)
    }

    // MARK: RDF/JSON

    private static let rl = "http://purl.org/vocab/resourcelist/schema#"
    private static let rdfType = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
    private static let rdfSeq = "http://www.w3.org/1999/02/22-rdf-syntax-ns#_"
    private static let titlePredicates = ["http://purl.org/dc/terms/title", "http://purl.org/dc/elements/1.1/title",
                                          "http://rdfs.org/sioc/spec/name", "http://www.w3.org/2000/01/rdf-schema#label"]
    private static let labelPredicates = ["http://www.w3.org/2000/01/rdf-schema#label", "http://rdfs.org/sioc/spec/name",
                                          "http://purl.org/dc/terms/title"]

    /// Parses Talis's RDF/JSON: `{subject: {predicate: [{type, value}]}}`.
    public static func parseRDFJSON(_ data: Data, moduleCode: String) throws -> [Entry] {
        guard case .object(let root) = try MoodleJSON.parse(data) else { return [] }
        func values(_ s: String, _ p: String) -> [String] { root[s]?[p].array.compactMap { $0["value"].string } ?? [] }
        func firstValue(_ s: String, _ ps: [String]) -> String? {
            for p in ps { if let v = values(s, p).first, !v.isEmpty { return v } }
            return nil
        }
        func isType(_ s: String, _ t: String) -> Bool { values(s, rdfType).contains(rl + t) }

        let itemURIs = root.keys.filter { isType($0, "Item") }
        guard !itemURIs.isEmpty else { return [] }

        // Parent containers (sections / the list) and position of each child.
        var parent: [String: String] = [:], position: [String: Int] = [:]
        for (subject, preds) in root {
            guard let preds = preds.object else { continue }
            for (p, objs) in preds where p.hasPrefix(rdfSeq) || p == rl + "contains" {
                for o in objs.array {
                    guard let v = o["value"].string, root[v] != nil else { continue }
                    // A section is a better parent than the list itself.
                    if let existing = parent[v], existing != subject,
                       !(isType(subject, "Section") && !isType(existing, "Section")) { continue }
                    parent[v] = subject
                    if p.hasPrefix(rdfSeq), let n = Int(p.dropFirst(rdfSeq.count)) { position[v] = n }
                }
            }
        }
        func section(of uri: String) -> String? {
            var cur = parent[uri], depth = 0
            while let c = cur, depth < 6 {
                if isType(c, "Section"), let name = firstValue(c, labelPredicates) { return name }
                cur = parent[c]; depth += 1
            }
            return nil
        }
        func order(_ uri: String) -> [Int] {
            var path: [Int] = [], cur: String? = uri
            while let c = cur, path.count < 8 { path.insert(position[c] ?? 0, at: 0); cur = parent[c] }
            return path
        }

        return itemURIs.sorted { order($0).lexicographicallyPrecedes(order($1)) }.compactMap { uri in
            let resource = values(uri, rl + "resource").first
            guard let title = resource.flatMap({ firstValue($0, titlePredicates) }) ?? firstValue(uri, titlePredicates) else { return nil }
            let importanceLabel = values(uri, rl + "importance").first.map { firstValue($0, labelPredicates) ?? $0 } ?? ""
            let importance = Importance(label: importanceLabel)
            let sectionName = section(of: uri)
            let doi = resource.flatMap { firstValue($0, ["http://purl.org/ontology/bibo/doi"]) }
            let link = resource.flatMap { firstValue($0, ["http://purl.org/ontology/bibo/uri"]) }
                ?? doi.map { $0.hasPrefix("http") ? $0 : "https://doi.org/" + $0 }
            let authors = resource.flatMap { firstValue($0, ["http://purl.org/ontology/bibo/authorList", "http://purl.org/dc/terms/creator"]) }
                .flatMap { root[$0] == nil ? $0 : nil }
            let id = "talis-" + (uri.split(separator: "/").last.map(String.init) ?? MD5.hex(uri))
            let item = ReadingItem(id: id.replacingOccurrences(of: ".html", with: ""), moduleCode: moduleCode,
                                   title: UniHTML.decodeEntities(title), url: link ?? uri,
                                   essential: importance == .essential, week: sectionName.flatMap(week(in:)))
            return Entry(item: item, importance: importance, section: sectionName, authors: authors)
        }
    }

    // MARK: HTML

    /// Best-effort scrape of a rendered list page: headings set the current section,
    /// and each `<li>`/`<article>` with an "item" class becomes an entry.
    public static func parseHTML(_ html: String, moduleCode: String, baseURL: URL? = nil) -> [Entry] {
        struct Hit { let pos: Int; let heading: String?; let body: String?; let attrs: String? }
        var hits: [Hit] = []
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        let headingRE = UniRegex.regex("<h([1-6])[^>]*>(.*?)</h\\1>", dotAll: true)
        for m in headingRE.matches(in: html, range: full) {
            hits.append(Hit(pos: m.range.location, heading: UniHTML.text(ns.substring(with: m.range(at: 2))), body: nil, attrs: nil))
        }
        let itemRE = UniRegex.regex("<(li|article)([^>]*class=\"[^\"]*\\bitem\\b[^\"]*\"[^>]*)>(.*?)</\\1>", dotAll: true)
        for m in itemRE.matches(in: html, range: full) {
            hits.append(Hit(pos: m.range.location, heading: nil, body: ns.substring(with: m.range(at: 3)),
                            attrs: ns.substring(with: m.range(at: 2))))
        }
        hits.sort { $0.pos < $1.pos }

        var entries: [Entry] = []
        var currentSection: String?
        for hit in hits {
            if let h = hit.heading { if !h.isEmpty { currentSection = h }; continue }
            guard let body = hit.body else { continue }
            let links = UniRegex.matches("<a[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>", in: body, dotAll: true)
            let itemLink = links.first { ($0[1] ?? "").contains("/items/") } ?? links.first
            let titleFromClass = UniRegex.first("class=\"[^\"]*title[^\"]*\"[^>]*>(.*?)</", in: body, dotAll: true)?[1]
            guard let rawTitle = itemLink?[2] ?? titleFromClass else { continue }
            let title = UniHTML.text(rawTitle)
            guard !title.isEmpty else { continue }
            let text = UniHTML.text(body)
            let importanceLabel = UniRegex.first("\\b(essential|recommended|further(?: reading)?|optional|background|suggested)\\b",
                                                 in: text)?[1] ?? ""
            let importance = Importance(label: importanceLabel)
            var link = itemLink?[1].map(UniHTML.decodeEntities)
            if let l = link, let base = baseURL, !l.hasPrefix("http") { link = URL(string: l, relativeTo: base)?.absoluteString }
            let rawID = link.flatMap { UniRegex.first("/items/([A-Za-z0-9-]+)", in: $0)?[1] }
                ?? hit.attrs.flatMap { UniRegex.first("id=\"(?:item_)?([^\"]+)\"", in: $0)?[1] }
                ?? MD5.hex(moduleCode + title)
            let item = ReadingItem(id: "talis-\(rawID)", moduleCode: moduleCode, title: title, url: link,
                                   essential: importance == .essential, week: currentSection.flatMap(week(in:)))
            entries.append(Entry(item: item, importance: importance, section: currentSection, authors: nil))
        }
        return entries
    }

    /// "Week 3", "Wk 3", "W3: Regression" → 3.
    public static func week(in heading: String) -> Int? {
        UniRegex.first("\\b(?:week|wk|w)\\s*\\.?\\s*(\\d{1,2})\\b", in: heading)?[1].flatMap { Int($0) }
    }
}
