import Foundation

/// Every reading Orbit knows about (Talis lists, ELE "reading for week N", reading-around
/// suggestions), with read/unread state, and a daily plan for the evening reading slot.
public struct ReadingLibrary: Codable, Hashable, Sendable {
    public enum Importance: String, Codable, Sendable, Comparable {
        case essential, recommended, further, around
        var rank: Int { switch self { case .essential: 0; case .recommended: 1; case .further: 2; case .around: 3 } }
        public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
        public init(_ t: TalisReadingList.Importance) {
            switch t { case .essential: self = .essential; case .recommended, .unknown: self = .recommended; case .further: self = .further }
        }
    }

    public struct Entry: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var moduleCode: String
        public var title: String
        public var authors: String?
        public var url: String?
        public var importance: Importance
        public var week: Int?
        public var section: String?
        public var read: Bool
        public var readAt: Date?
        public init(id: String, moduleCode: String, title: String, authors: String? = nil, url: String? = nil,
                    importance: Importance, week: Int? = nil, section: String? = nil, read: Bool = false) {
            self.id = id; self.moduleCode = moduleCode; self.title = title; self.authors = authors; self.url = url
            self.importance = importance; self.week = week; self.section = section; self.read = read
        }
    }

    public var entries: [String: Entry] = [:]
    /// Reading-list URLs already fetched, with when.
    public var fetchedLists: [String: Date] = [:]
    public init() {}

    static func key(_ module: String, _ title: String) -> String {
        "\(module)-" + MD5.hex(title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()).prefix(10)
    }

    /// Adds/refreshes entries, keeping read state; a stronger importance wins.
    public mutating func merge(_ new: [Entry]) {
        for var e in new {
            if let old = entries[e.id] {
                e.read = old.read; e.readAt = old.readAt
                e.importance = min(old.importance, e.importance)
                e.week = e.week ?? old.week
            }
            entries[e.id] = e
        }
    }

    public mutating func merge(talis: [TalisReadingList.Entry]) {
        merge(talis.map { t in
            Entry(id: Self.key(t.item.moduleCode, t.item.title), moduleCode: t.item.moduleCode, title: t.item.title,
                  authors: t.authors, url: t.item.url, importance: Importance(t.importance),
                  week: t.item.week ?? t.section.flatMap(Self.week(in:)), section: t.section)
        })
    }

    public mutating func merge(ele: [ReadingItem]) {
        merge(ele.map { r in
            Entry(id: Self.key(r.moduleCode, r.title), moduleCode: r.moduleCode, title: r.title, url: r.url,
                  importance: r.essential ? .essential : .recommended, week: r.week, read: r.done)
        })
    }

    static func week(in s: String) -> Int? {
        UniRegex.first("\\bweek\\s*(\\d{1,2})", in: s)?[1].flatMap(Int.init)
    }

    public mutating func setRead(_ id: String, _ read: Bool, at date: Date = Date()) {
        entries[id]?.read = read
        entries[id]?.readAt = read ? date : nil
    }

    public func items(moduleCode: String? = nil, unreadOnly: Bool = false) -> [Entry] {
        entries.values.filter { (moduleCode == nil || $0.moduleCode == moduleCode) && (!unreadOnly || !$0.read) }
            .sorted { ($0.importance, $0.week ?? 99, $0.moduleCode, $0.title) < ($1.importance, $1.week ?? 99, $1.moduleCode, $1.title) }
    }
}

// MARK: - Daily plan

public struct DailyReadingPlan: Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        public var entryID: String
        public var moduleCode: String
        public var title: String
        public var minutes: Int
        /// "part 2 of 3" when a long reading is split across evenings.
        public var part: Int
        public var parts: Int
        public var importance: ReadingLibrary.Importance
    }
    public struct Day: Hashable, Sendable {
        public var date: Date
        public var items: [Item]
        public var minutes: Int { items.map(\.minutes).reduce(0, +) }
    }
    public var days: [Day]

    /// Fills `minutesPerDay` (the 22:00–22:20 slot) for `dayCount` evenings: essential readings
    /// for this week, then next week's, then recommended, then one reading-around item.
    public static func make(library: ReadingLibrary, currentWeek: Int?, start: Date, dayCount: Int = 7,
                            minutesPerDay: Int = 20, calendar: Calendar = Calendar(identifier: .gregorian)) -> DailyReadingPlan {
        let cw = currentWeek ?? 0
        func priority(_ e: ReadingLibrary.Entry) -> (Int, Int, Int) {
            let w = e.week ?? cw
            let when = w == cw ? 0 : w == cw + 1 ? 1 : w < cw ? 2 : 3
            let base: Int
            switch e.importance {
            case .essential: base = when <= 1 ? 0 : 3
            case .recommended: base = when <= 1 ? 1 : 4
            case .further: base = 5
            case .around: base = 2
            }
            return (base, when, e.week ?? 99)
        }
        let queue = library.entries.values.filter { !$0.read && ($0.week == nil || $0.week! >= cw - 1) }
            .sorted { (priority($0), $0.title) < (priority($1), $1.title) }

        // Split each reading into slot-sized parts.
        var parts: [Item] = []
        for e in queue {
            let assignment = ReadingAssignment(id: e.id, moduleCode: e.moduleCode, title: e.title, week: e.week,
                                               essential: e.importance == .essential, neededBy: start)
            let total = max(10, e.importance == .around ? min(ReadingEstimator.estimate(assignment).minutes, 20)
                                                         : ReadingEstimator.estimate(assignment).minutes)
            let n = max(1, Int((Double(total) / Double(minutesPerDay)).rounded(.up)))
            for i in 0..<n {
                parts.append(Item(entryID: e.id, moduleCode: e.moduleCode, title: e.title,
                                  minutes: min(minutesPerDay, total - i * minutesPerDay), part: i + 1, parts: n, importance: e.importance))
            }
        }
        var days: [Day] = []
        var idx = 0
        for d in 0..<dayCount {
            guard let date = calendar.date(byAdding: .day, value: d, to: calendar.startOfDay(for: start)) else { continue }
            var day = Day(date: date, items: [])
            while idx < parts.count, day.minutes + parts[idx].minutes <= minutesPerDay {
                day.items.append(parts[idx]); idx += 1
            }
            if day.items.isEmpty, idx < parts.count { day.items.append(parts[idx]); idx += 1 }
            days.append(day)
        }
        return DailyReadingPlan(days: days)
    }
}

// MARK: - Reading around

public struct ReadingAroundItem: Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case paper, book, article, podcast }
    public var id: String
    public var kind: Kind
    public var title: String
    public var by: String
    public var why: String
    public var conceptIDs: [String]
    public var search: String
}

/// Curated classics tied to concepts in the web. Magazine topics are phrased as searches
/// (Orbit doesn't link to paywalled articles).
public enum ReadingAroundCatalog {
    public static let items: [ReadingAroundItem] = [
        .init(id: "smith-won", kind: .book, title: "The Wealth of Nations, Book I ch. 1-3", by: "Adam Smith (1776)", why: "The pin factory and the division of labour.", conceptIDs: ["smith", "production", "markets"], search: "Wealth of Nations division of labour"),
        .init(id: "heilbroner", kind: .book, title: "The Worldly Philosophers", by: "Robert Heilbroner", why: "The most readable tour of Smith to Keynes.", conceptIDs: ["smith", "ricardo", "malthus", "marx", "keynes", "marshall"], search: "Heilbroner Worldly Philosophers"),
        .init(id: "ricardo-ch7", kind: .book, title: "Principles of Political Economy, ch. 7 (On Foreign Trade)", by: "David Ricardo (1817)", why: "Wine, cloth and comparative advantage in the original.", conceptIDs: ["ricardo", "trade"], search: "Ricardo On Foreign Trade chapter 7"),
        .init(id: "malthus-essay", kind: .book, title: "An Essay on the Principle of Population, ch. 1-2", by: "Thomas Malthus (1798)", why: "Geometric vs arithmetic growth.", conceptIDs: ["malthus", "growth", "exp-log"], search: "Malthus Essay Principle of Population"),
        .init(id: "hayek-1945", kind: .paper, title: "The Use of Knowledge in Society", by: "F. A. Hayek (AER 1945)", why: "Prices as a way of sharing information.", conceptIDs: ["hayek", "markets"], search: "Hayek Use of Knowledge in Society 1945"),
        .init(id: "friedman-1968", kind: .paper, title: "The Role of Monetary Policy", by: "Milton Friedman (AER 1968)", why: "The natural rate of unemployment.", conceptIDs: ["monetarism", "inflation", "unemployment"], search: "Friedman Role of Monetary Policy 1968"),
        .init(id: "keynes-gt", kind: .book, title: "The General Theory, ch. 3 and 12", by: "J. M. Keynes (1936)", why: "Effective demand and animal spirits.", conceptIDs: ["keynes", "macro-output", "unemployment"], search: "Keynes General Theory chapter 12"),
        .init(id: "akerlof-1970", kind: .paper, title: "The Market for 'Lemons'", by: "George Akerlof (QJE 1970)", why: "Asymmetric information breaks markets.", conceptIDs: ["welfare", "markets", "probability"], search: "Akerlof Market for Lemons"),
        .init(id: "coase-1960", kind: .paper, title: "The Problem of Social Cost", by: "Ronald Coase (1960)", why: "Externalities and bargaining.", conceptIDs: ["welfare"], search: "Coase Problem of Social Cost"),
        .init(id: "solow-1956", kind: .paper, title: "A Contribution to the Theory of Economic Growth", by: "Robert Solow (QJE 1956)", why: "Where the Solow model comes from — calculus in action.", conceptIDs: ["growth", "production", "derivatives"], search: "Solow 1956 contribution theory of economic growth"),
        .init(id: "galton-1886", kind: .paper, title: "Regression towards Mediocrity in Hereditary Stature", by: "Francis Galton (1886)", why: "The origin of the word 'regression'.", conceptIDs: ["galton", "regression", "correlation"], search: "Galton 1886 regression towards mediocrity"),
        .init(id: "naked-stats", kind: .book, title: "Naked Statistics", by: "Charles Wheelan", why: "Intuition for CLT, inference and regression.", conceptIDs: ["sampling", "inference", "regression", "normal"], search: "Wheelan Naked Statistics"),
        .init(id: "how-not-wrong", kind: .book, title: "How Not to Be Wrong", by: "Jordan Ellenberg", why: "Maths thinking: linearity, regression to the mean.", conceptIDs: ["functions", "regression", "probability"], search: "Ellenberg How Not to Be Wrong"),
        .init(id: "undercover", kind: .book, title: "The Undercover Economist", by: "Tim Harford", why: "Price discrimination, scarcity and market power, everyday examples.", conceptIDs: ["markets", "demand", "elasticity"], search: "Harford Undercover Economist"),
        .init(id: "chang-guide", kind: .book, title: "Economics: The User's Guide", by: "Ha-Joon Chang", why: "The schools of thought side by side.", conceptIDs: ["marx", "keynes", "hayek", "marginalists"], search: "Chang Economics The User's Guide"),
        .init(id: "more-or-less", kind: .podcast, title: "More or Less", by: "BBC Radio 4", why: "Statistics in the news, checked.", conceptIDs: ["descriptive", "index-numbers", "inference"], search: "BBC More or Less podcast"),
        .init(id: "econtalk", kind: .podcast, title: "EconTalk", by: "Russ Roberts", why: "Long conversations with economists on classic ideas.", conceptIDs: ["hayek", "smith", "markets"], search: "EconTalk podcast"),
        .init(id: "money-talks", kind: .podcast, title: "Money Talks", by: "The Economist", why: "Current macro: inflation, rates, growth.", conceptIDs: ["inflation", "macro-output", "growth"], search: "The Economist Money Talks podcast"),
        .init(id: "unhedged", kind: .podcast, title: "Unhedged", by: "Financial Times", why: "Markets and monetary policy explained.", conceptIDs: ["inflation", "series"], search: "FT Unhedged podcast"),
        .init(id: "planet-money", kind: .podcast, title: "Planet Money", by: "NPR", why: "Short stories about supply, demand and trade.", conceptIDs: ["demand", "trade", "markets"], search: "Planet Money podcast"),
        .init(id: "art-uk-inflation", kind: .article, title: "Economist/FT explainer on UK inflation and the Bank of England", by: "The Economist / FT", why: "Connect CPI and index numbers to policy.", conceptIDs: ["inflation", "index-numbers"], search: "Bank of England inflation explainer"),
        .init(id: "art-tariffs", kind: .article, title: "Economist/FT pieces on tariffs and trade wars", by: "The Economist / FT", why: "Comparative advantage meets politics.", conceptIDs: ["trade", "ricardo"], search: "tariffs comparative advantage explainer"),
        .init(id: "art-minimum-wage", kind: .article, title: "Minimum wage evidence (Card & Krueger and UK Low Pay Commission)", by: "Various", why: "Regression and natural experiments on the labour market.", conceptIDs: ["unemployment", "regression", "inference"], search: "Card Krueger minimum wage"),
    ]

    /// Suggestions for the current topics, skipping ones already read.
    public static func suggestions(for graph: ConceptGraph, topics: [String], read: Set<String> = [], limit: Int = 5) -> [ReadingAroundItem] {
        let web = graph.web(forTopics: topics)
        let focus = Set(web.focus.map(\.id)), related = Set(web.related.map(\.id))
        let scored = items.filter { !read.contains($0.id) }.map { item -> (ReadingAroundItem, Int) in
            (item, item.conceptIDs.reduce(0) { $0 + (focus.contains($1) ? 3 : related.contains($1) ? 1 : 0) })
        }
        return scored.filter { $0.1 > 0 }.sorted { ($0.1, $1.0.id) > ($1.1, $0.0.id) }.prefix(limit).map(\.0)
    }

    public static func entry(_ item: ReadingAroundItem, moduleCode: String = "AROUND") -> ReadingLibrary.Entry {
        ReadingLibrary.Entry(id: "around-\(item.id)", moduleCode: moduleCode, title: "\(item.title) — \(item.by)",
                             importance: .around, section: item.kind.rawValue)
    }
}
