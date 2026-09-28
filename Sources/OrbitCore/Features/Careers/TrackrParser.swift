import Foundation

// Reading Trackr. Two sources, same result:
//  1. Its public JSON API (what the web app itself loads):
//     GET https://api.the-trackr.com/programmes?region=UK&industry=Finance&season=2027&type=spring-weeks
//  2. The rendered table (cell text per row), read from a hidden web view when
//     the API changes or refuses us. Also works on rows pasted from the site.

public enum TrackrParser {
    /// Column headers as the site shows them.
    public enum Column: String, CaseIterable, Sendable {
        case myStatus = "My Status", company = "Company Name", programme = "Programme Name", eligibility = "Eligibility"
        case opening = "Opening Date", closing = "Closing Date", stage = "Latest Stage", lastYear = "Last Year Opening"
        case process = "Process", testPrep = "Info & Test Prep", rolling = "Rolling", materials = "Materials"
        case acceptance = "Acceptance Rate", conversion = "Conversion Rate", notes = "Notes"

        /// Matches a header cell loosely ("Company", "Programme", "Info & Test Prep").
        static func match(_ header: String) -> Column? {
            let h = header.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if h.isEmpty { return nil }
            if h.contains("status") { return .myStatus }
            if h.contains("company") { return .company }
            if h.contains("programme") || h.contains("program") || h == "name" || h.contains("role") { return .programme }
            if h.contains("eligib") { return .eligibility }
            if h.contains("last year") { return .lastYear }
            if h.contains("open") { return .opening }
            if h.contains("clos") || h.contains("deadline") { return .closing }
            if h.contains("stage") { return .stage }
            if h.contains("test") || h.contains("prep") || h.contains("info") { return .testPrep }
            if h.contains("process") { return .process }
            if h.contains("rolling") { return .rolling }
            if h.contains("material") { return .materials }
            if h.contains("accept") { return .acceptance }
            if h.contains("conver") { return .conversion }
            if h.contains("note") { return .notes }
            return nil
        }
    }

    /// Every column, in the order the site shows them.
    public static let fullLayout: [Column] = Column.allCases
    /// The text you get when copying rows: My Status and Process are icons, so they're missing.
    public static let copiedLayout: [Column] = [.company, .programme, .eligibility, .opening, .closing, .stage, .lastYear,
                                                .testPrep, .rolling, .materials, .acceptance, .conversion, .notes]

    // MARK: Table

    /// Parses table rows (one array of cell texts per row). `header` names the columns
    /// if known; otherwise the layout is guessed from the cell count. Header rows,
    /// empty rows and group headings are skipped.
    public static func parseTable(rows: [[String]], header: [String]? = nil, category: OpportunityCategory,
                                  links: [[String?]]? = nil) -> [Opportunity] {
        var layout: [Column?]? = header.map { $0.map(Column.match) }
        var out: [Opportunity] = []
        var seen = Set<String>()
        for (index, raw) in rows.enumerated() {
            let cells = raw.map { $0.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            guard cells.contains(where: { !$0.isEmpty }) else { continue }
            // A header row sets the layout.
            let matched = cells.map(Column.match)
            if matched.contains(.company) && matched.contains(.programme) && cells.contains(where: { $0.lowercased().contains("company") }) {
                layout = matched
                continue
            }
            let columns: [Column?] = layout ?? guessLayout(count: cells.count)
            var values: [Column: String] = [:]
            for (i, col) in columns.enumerated() where i < cells.count {
                if let col, values[col] == nil { values[col] = cells[i] }
            }
            guard let company = values[.company], !company.isEmpty,
                  let programme = values[.programme], !programme.isEmpty else { continue }
            let link = links.flatMap { index < $0.count ? $0[index] : nil }?.compactMap { $0 }.first
            let o = Opportunity(
                company: company, programme: programme, category: category,
                eligibility: values[.eligibility],
                openingDate: values[.opening].flatMap(CareersDay.parse),
                closingDate: values[.closing].flatMap(CareersDay.parse),
                latestStage: values[.stage],
                lastYearOpening: values[.lastYear].flatMap(CareersDay.parse),
                process: values[.process].map(splitProcess) ?? [],
                testPrep: values[.testPrep],
                rolling: parseYesNo(values[.rolling]),
                acceptanceRate: values[.acceptance],
                conversionRate: values[.conversion],
                notes: values[.notes],
                url: link)
            if seen.insert(o.id).inserted { out.append(o) }
        }
        return out
    }

    /// Parses rows pasted as text: one row per line, cells split by tabs or " | ".
    public static func parsePasted(_ text: String, category: OpportunityCategory) -> [Opportunity] {
        let rows = text.components(separatedBy: .newlines).map { line -> [String] in
            if line.contains("\t") { return line.components(separatedBy: "\t") }
            return line.components(separatedBy: "|")
        }
        return parseTable(rows: rows, category: category)
    }

    static func guessLayout(count: Int) -> [Column?] {
        if count >= fullLayout.count { return fullLayout }
        return copiedLayout
    }

    static func parseYesNo(_ s: String?) -> Bool {
        guard let s = s?.lowercased().trimmingCharacters(in: .whitespaces) else { return false }
        return s == "yes" || s == "y" || s == "true" || s == "✓" || s == "rolling"
    }

    static func splitProcess(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet(charactersIn: ",/→>\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map(processLabel)
    }

    /// Trackr's process codes in words.
    public static func processLabel(_ code: String) -> String {
        switch code.uppercased() {
        case "OA": "Online test"
        case "HV": "HireVue"
        case "INT": "Interview"
        case "AC": "Assessment centre"
        case "CS": "Case study"
        case "VI": "Video interview"
        case "GI": "Game-based test"
        default: code
        }
    }

    // MARK: JSON API

    public struct APIResponse: Decodable, Sendable {
        public var programmes: [APIProgramme]
        public var groups: [APIGroup]?
    }

    public struct APIGroup: Decodable, Sendable {
        public var id: String
        public var name: String?
    }

    public struct APIProgramme: Decodable, Sendable {
        public var id: String
        public var groupId: String?
        public var name: String
        public var url: String?
        public var type: String?
        public var season: String?
        public var categories: [String]?
        public var eligibility: String?
        public var process: [String]?
        public var openingDate: String?
        public var closingDate: String?
        public var lastYearOpening: String?
        public var currentStage: String?
        public var rolling: Bool?
        public var acceptanceRate: String?
        public var conversionRate: String?
        public var notes: String?
        public var company: APICompany?
    }

    public struct APICompany: Decodable, Sendable {
        public var id: String?
        public var name: String?
        public var careersSite: String?
        /// Test prep name shown in "Info & Test Prep" (Cut-e, SHL…).
        public var ukJtpName: String?
        public var ukJtpLink: String?
    }

    /// Decodes the API's JSON. Unknown or missing fields are ignored.
    public static func parseAPI(_ data: Data, category: OpportunityCategory) throws -> [Opportunity] {
        let response = try JSONDecoder().decode(APIResponse.self, from: data)
        var out: [Opportunity] = []
        var seen = Set<String>()
        for p in response.programmes {
            let company = p.company?.name?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !company.isEmpty else { continue }
            let cat = p.type.flatMap(OpportunityCategory.init(rawValue:)) ?? category
            let process = (p.process ?? []).filter { $0.lowercased() != "no process" }.map(processLabel)
            var o = Opportunity(
                company: company, programme: p.name, category: cat, sourceID: p.id,
                eligibility: p.eligibility,
                openingDate: p.openingDate.flatMap(CareersDay.parse),
                closingDate: p.closingDate.flatMap(CareersDay.parse),
                latestStage: p.currentStage,
                lastYearOpening: p.lastYearOpening.flatMap(CareersDay.parse),
                process: process,
                testPrep: p.company?.ukJtpName,
                rolling: p.rolling ?? false,
                acceptanceRate: p.acceptanceRate,
                conversionRate: p.conversionRate,
                notes: p.notes,
                url: p.url ?? p.company?.careersSite,
                sectors: p.categories ?? [])
            // Two programmes with the same name at one company: keep both.
            if !seen.insert(o.id).inserted {
                o.id += "|" + p.id
                seen.insert(o.id)
            }
            out.append(o)
        }
        return out
    }

    /// The API URL for one tracker page.
    public static func apiURL(category: OpportunityCategory, season: Int, region: String = "UK",
                              industry: String = "Finance") -> URL {
        var c = URLComponents(string: "https://api.the-trackr.com/programmes")!
        c.queryItems = [URLQueryItem(name: "region", value: region), URLQueryItem(name: "industry", value: industry),
                        URLQueryItem(name: "season", value: String(season)), URLQueryItem(name: "type", value: category.rawValue)]
        return c.url!
    }

    /// The recruiting season Trackr files a category under. Spring weeks and
    /// internships applied for in autumn 2026 happen in 2027.
    public static func season(for category: OpportunityCategory, now: Date) -> Int {
        // Every category currently follows the same cycle: from June, next year's season is live.
        _ = category
        let c = CareersDay.calendar.dateComponents([.year, .month], from: now)
        let year = c.year ?? 2026
        return (c.month ?? 1) >= 6 ? year + 1 : year
    }

    /// JavaScript that reads the rendered table(s) in a Trackr page:
    /// {header: [String], rows: [[String]], links: [[String|null]]}.
    public static let tableScript = """
    const tables = Array.from(document.querySelectorAll('table'));
    let header = [];
    const rows = [], links = [];
    for (const t of tables) {
      const trs = Array.from(t.querySelectorAll('tr'));
      for (const tr of trs) {
        const cells = Array.from(tr.querySelectorAll('th,td'));
        if (!cells.length) continue;
        const texts = cells.map(c => (c.innerText || c.textContent || '').replace(/\\s+/g, ' ').trim());
        if (tr.querySelector('th') && header.length === 0) { header = texts; continue; }
        rows.push(texts);
        links.push(cells.map(c => { const a = c.querySelector('a[href^="http"]'); return a ? a.href : null; }));
      }
    }
    // Some versions render a div grid instead of a <table>.
    if (rows.length === 0) {
      for (const r of Array.from(document.querySelectorAll('[role=row]'))) {
        const cells = Array.from(r.querySelectorAll('[role=cell],[role=gridcell],[role=columnheader]'));
        const texts = cells.map(c => (c.innerText || '').replace(/\\s+/g, ' ').trim());
        if (r.querySelector('[role=columnheader]')) { if (!header.length) header = texts; continue; }
        rows.push(texts);
        links.push(cells.map(c => { const a = c.querySelector('a[href^="http"]'); return a ? a.href : null; }));
      }
    }
    return {header: header, rows: rows, links: links};
    """
}
