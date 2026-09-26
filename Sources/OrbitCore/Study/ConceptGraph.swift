import Foundation

/// The four first-year strands, recognised from ELE module names.
public enum EconStrand: String, Codable, CaseIterable, Sendable {
    case economics, maths, statistics, history

    public var label: String {
        switch self {
        case .economics: "Economics"
        case .maths: "Maths for Economists"
        case .statistics: "Statistics"
        case .history: "History of Economics"
        }
    }

    /// "Introduction to Statistics" → .statistics; nil when unclear.
    public static func classify(name: String) -> EconStrand? {
        let n = name.lowercased()
        if n.contains("histor") || n.contains("thought") { return .history }
        if n.contains("statist") || n.contains("econometric") || n.contains("data") { return .statistics }
        if n.contains("math") || n.contains("quantitative") { return .maths }
        if n.contains("econom") { return .economics }
        return nil
    }
}

public struct Concept: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var strand: EconStrand
    /// Lower-case phrases that signal the concept in text.
    public var keywords: [String]
    public init(_ id: String, _ name: String, _ strand: EconStrand, _ keywords: [String]) {
        self.id = id; self.name = name; self.strand = strand; self.keywords = keywords
    }
}

public struct ConceptLink: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case curated, content, ai }
    public var from: String
    public var to: String
    public var relation: String
    public var source: Source
    /// Evidence strength (documents seen together, or 1 for curated/AI links).
    public var weight: Int
    public init(_ from: String, _ to: String, _ relation: String, source: Source = .curated, weight: Int = 1) {
        self.from = from; self.to = to; self.relation = relation; self.source = source; self.weight = weight
    }
    func touches(_ id: String) -> Bool { from == id || to == id }
    var key: String { [from, to].sorted().joined(separator: "|") }
}

/// Links topics across the four modules. Seeded with a curated economics concept map;
/// learns more from co-occurrence in ingested material and from the AI.
public struct ConceptGraph: Codable, Hashable, Sendable {
    public private(set) var concepts: [String: Concept]
    public private(set) var links: [ConceptLink]

    /// What gets persisted: only the learned part (the seed lives in code).
    public struct Learned: Codable, Hashable, Sendable {
        public var concepts: [Concept] = []
        public var links: [ConceptLink] = []
        public init() {}
    }

    public init(learned: Learned = Learned()) {
        concepts = Dictionary(Self.seedConcepts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        links = Self.seedLinks
        for c in learned.concepts where concepts[c.id] == nil { concepts[c.id] = c }
        for l in learned.links { add(l) }
    }

    public var learned: Learned {
        var l = Learned()
        let seedIDs = Set(Self.seedConcepts.map(\.id))
        l.concepts = concepts.values.filter { !seedIDs.contains($0.id) }.sorted { $0.id < $1.id }
        l.links = links.filter { $0.source != .curated }
        return l
    }

    public func name(_ id: String) -> String { concepts[id]?.name ?? id }

    /// Adds a link, or strengthens an existing one between the same pair.
    public mutating func add(_ link: ConceptLink) {
        guard link.from != link.to, concepts[link.from] != nil, concepts[link.to] != nil else { return }
        if let i = links.firstIndex(where: { $0.key == link.key }) {
            if links[i].source != .curated { links[i].weight = max(links[i].weight, link.weight) }
            return
        }
        links.append(link)
    }

    // MARK: Matching

    static func contains(_ hay: String, _ phrase: String) -> Bool {
        let pattern = "(^|[^a-z0-9])" + NSRegularExpression.escapedPattern(for: phrase) + "($|[^a-z0-9])"
        return hay.range(of: pattern, options: .regularExpression) != nil
    }

    /// Concepts mentioned in a piece of text, most mentions first.
    public func match(_ text: String, limit: Int = 12) -> [Concept] {
        let hay = text.lowercased()
        let scored: [(Concept, Int)] = concepts.values.compactMap { c in
            let n = c.keywords.filter { Self.contains(hay, $0) }.count + (Self.contains(hay, c.name.lowercased()) ? 1 : 0)
            return n > 0 ? (c, n) : nil
        }
        return scored.sorted { ($0.1, $1.0.id) > ($1.1, $0.0.id) }.prefix(limit).map(\.0)
    }

    public func neighbours(of id: String) -> [(concept: Concept, link: ConceptLink)] {
        links.filter { $0.touches(id) }.compactMap { l in
            let other = l.from == id ? l.to : l.from
            return concepts[other].map { ($0, l) }
        }.sorted { ($0.link.weight, $1.concept.id) > ($1.link.weight, $0.concept.id) }
    }

    /// The part of the web around some topics (this week's lecture titles, a question…).
    public struct Web: Hashable, Sendable {
        public var focus: [Concept]
        public var related: [Concept]
        public var edges: [ConceptLink]
        /// Links that cross between modules — the interesting ones.
        public var crossModule: [ConceptLink]
    }

    public func web(forTopics topics: [String], limit: Int = 10) -> Web { web(forText: topics.joined(separator: "\n"), limit: limit) }

    public func web(forText text: String, limit: Int = 10) -> Web {
        let focus = match(text, limit: limit)
        let focusIDs = Set(focus.map(\.id))
        var edges: [ConceptLink] = []
        var related: [String: Concept] = [:]
        for c in focus {
            for n in neighbours(of: c.id) {
                if !edges.contains(where: { $0.key == n.link.key }) { edges.append(n.link) }
                if !focusIDs.contains(n.concept.id) { related[n.concept.id] = n.concept }
            }
        }
        let cross = edges.filter { concepts[$0.from]?.strand != concepts[$0.to]?.strand }
        return Web(focus: focus, related: related.values.sorted { $0.id < $1.id }, edges: edges, crossModule: cross)
    }

    // MARK: Learning

    /// Links concepts from different modules that keep appearing in the same documents.
    @discardableResult
    public mutating func learnCoOccurrence(from texts: [String], minDocuments: Int = 2) -> Int {
        var counts: [String: (String, String, Int)] = [:]
        for t in texts {
            let ids = match(t, limit: 8).map(\.id).sorted()
            for i in ids.indices {
                for j in ids.indices where j > i {
                    guard concepts[ids[i]]?.strand != concepts[ids[j]]?.strand else { continue }
                    let k = ids[i] + "|" + ids[j]
                    counts[k] = (ids[i], ids[j], (counts[k]?.2 ?? 0) + 1)
                }
            }
        }
        var added = 0
        for (_, v) in counts where v.2 >= minDocuments {
            let before = links.count
            add(ConceptLink(v.0, v.1, "appear together in course material", source: .content, weight: v.2))
            if links.count > before { added += 1 }
            else if let i = links.firstIndex(where: { $0.key == [v.0, v.1].sorted().joined(separator: "|") }), links[i].source == .content {
                links[i].weight = max(links[i].weight, v.2)
            }
        }
        return added
    }

    /// A link the AI proposed, by concept names.
    public struct ProposedLink: Codable, Hashable, Sendable {
        public var from: String
        public var to: String
        public var relation: String
        public var fromModule: String?
        public var toModule: String?
    }
    struct ProposedLinks: Codable { var links: [ProposedLink] }

    public static func linkRequest(topics: [String], excerpts: [String]) -> LLMRequest {
        let known = seedConcepts.map(\.name).joined(separator: ", ")
        return LLMRequest(messages: [
            .system("""
            You map connections between first-year economics modules: Economics, Maths for Economists, Statistics, History of Economics. \
            Given topics and excerpts, propose up to 8 genuine cross-module links. Prefer these concept names when they fit: \(known). \
            Reply JSON: {"links":[{"from":"…","to":"…","relation":"short explanation","fromModule":"economics|maths|statistics|history","toModule":"…"}]}
            """),
            .user("Topics: \(topics.joined(separator: "; "))\n\nExcerpts:\n" + excerpts.map { "- " + $0.prefix(600) }.joined(separator: "\n")),
        ], purpose: .reasoning, json: true)
    }

    public static func parseProposed(_ text: String) -> [ProposedLink] {
        guard let json = JSONExtractor.extract(text), let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ProposedLinks.self, from: data) else { return [] }
        return decoded.links
    }

    static func slug(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
    }

    /// Resolves names to concepts (creating new ones when needed) and adds the links.
    @discardableResult
    public mutating func addProposed(_ proposed: [ProposedLink]) -> Int {
        var added = 0
        func resolve(_ name: String, _ module: String?) -> String? {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard n.count >= 3 else { return nil }
            if let c = concepts.values.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { return c.id }
            if let c = match(n, limit: 1).first { return c.id }
            let strand = module.flatMap { EconStrand(rawValue: $0.lowercased()) ?? EconStrand.classify(name: $0) } ?? .economics
            let id = "ai-" + Self.slug(n)
            if concepts[id] == nil { concepts[id] = Concept(id, n, strand, [n.lowercased()]) }
            return id
        }
        for p in proposed {
            guard let a = resolve(p.from, p.fromModule), let b = resolve(p.to, p.toModule) else { continue }
            let before = links.count
            add(ConceptLink(a, b, String(p.relation.prefix(160)), source: .ai))
            if links.count > before { added += 1 }
        }
        return added
    }

    // MARK: Seed

    public static let seedConcepts: [Concept] = [
        // Economics
        Concept("demand", "Demand and supply", .economics, ["demand", "supply", "demand curve", "supply curve", "equilibrium price"]),
        Concept("elasticity", "Elasticity", .economics, ["elasticity", "elastic", "inelastic", "price elasticity"]),
        Concept("consumer", "Consumer choice", .economics, ["utility", "indifference curve", "budget constraint", "consumer choice", "marginal rate of substitution", "mrs"]),
        Concept("production", "Production and costs", .economics, ["production function", "marginal cost", "average cost", "returns to scale", "isoquant", "cobb-douglas", "cost function"]),
        Concept("markets", "Market structure", .economics, ["perfect competition", "monopoly", "oligopoly", "monopolistic competition", "market power"]),
        Concept("games", "Game theory", .economics, ["game theory", "nash equilibrium", "prisoner's dilemma", "dominant strategy", "payoff matrix"]),
        Concept("welfare", "Welfare and market failure", .economics, ["consumer surplus", "producer surplus", "deadweight loss", "externality", "externalities", "public good", "pareto"]),
        Concept("macro-output", "GDP and the circular flow", .economics, ["gdp", "national income", "circular flow", "aggregate demand", "multiplier"]),
        Concept("inflation", "Inflation and money", .economics, ["inflation", "money supply", "monetary policy", "interest rate", "central bank", "quantity theory"]),
        Concept("unemployment", "Unemployment and the labour market", .economics, ["unemployment", "labour market", "phillips curve", "wage"]),
        Concept("growth", "Economic growth", .economics, ["economic growth", "solow", "capital accumulation", "productivity", "steady state"]),
        Concept("trade", "International trade", .economics, ["comparative advantage", "absolute advantage", "international trade", "tariff", "gains from trade"]),
        // Maths
        Concept("functions", "Functions and graphs", .maths, ["function", "linear function", "quadratic", "graph", "inverse function"]),
        Concept("derivatives", "Differentiation", .maths, ["derivative", "differentiation", "differentiate", "chain rule", "product rule", "marginal"]),
        Concept("partials", "Partial derivatives", .maths, ["partial derivative", "partial differentiation", "total differential", "homogeneous function", "euler's theorem"]),
        Concept("optimisation", "Unconstrained optimisation", .maths, ["optimisation", "optimization", "maximise", "minimise", "stationary point", "second order condition", "first order condition"]),
        Concept("lagrange", "Constrained optimisation (Lagrange)", .maths, ["lagrange", "lagrangian", "lagrange multiplier", "constrained optimisation", "constrained optimization"]),
        Concept("integration", "Integration", .maths, ["integration", "integral", "integrate", "area under"]),
        Concept("matrices", "Matrices and linear systems", .maths, ["matrix", "matrices", "determinant", "linear equations", "simultaneous equations", "cramer"]),
        Concept("exp-log", "Exponentials, logs and growth rates", .maths, ["exponential", "logarithm", "natural log", "compound interest", "continuous compounding", "growth rate"]),
        Concept("series", "Sequences, series and discounting", .maths, ["geometric series", "arithmetic series", "present value", "discounting", "annuity", "sequence"]),
        // Statistics
        Concept("descriptive", "Descriptive statistics", .statistics, ["mean", "median", "variance", "standard deviation", "histogram", "skewness", "descriptive statistics"]),
        Concept("probability", "Probability", .statistics, ["probability", "conditional probability", "bayes", "independence", "sample space"]),
        Concept("distributions", "Random variables and distributions", .statistics, ["random variable", "expected value", "expectation", "binomial", "poisson", "distribution"]),
        Concept("normal", "Normal distribution", .statistics, ["normal distribution", "z-score", "standard normal", "bell curve"]),
        Concept("sampling", "Sampling and the CLT", .statistics, ["sampling distribution", "central limit theorem", "sample mean", "standard error", "clt"]),
        Concept("inference", "Confidence intervals and hypothesis tests", .statistics, ["confidence interval", "hypothesis test", "p-value", "null hypothesis", "t-test", "significance level"]),
        Concept("correlation", "Correlation and covariance", .statistics, ["correlation", "covariance", "scatter plot", "scatter diagram"]),
        Concept("regression", "Regression (OLS)", .statistics, ["regression", "ols", "least squares", "coefficient", "r-squared", "line of best fit"]),
        Concept("index-numbers", "Index numbers", .statistics, ["index number", "price index", "cpi", "laspeyres", "paasche", "rpi"]),
        // History of economic thought
        Concept("smith", "Adam Smith and the invisible hand", .history, ["adam smith", "invisible hand", "wealth of nations", "division of labour", "division of labor"]),
        Concept("ricardo", "Ricardo: rent and comparative advantage", .history, ["ricardo", "ricardian", "theory of rent", "corn laws"]),
        Concept("malthus", "Malthus and population", .history, ["malthus", "malthusian", "population principle"]),
        Concept("marx", "Marx and the labour theory of value", .history, ["marx", "labour theory of value", "labor theory of value", "surplus value", "capital accumulation"]),
        Concept("marginalists", "The marginal revolution", .history, ["marginal revolution", "jevons", "menger", "walras", "marginal utility", "marginalist"]),
        Concept("marshall", "Marshall and partial equilibrium", .history, ["marshall", "marshallian", "partial equilibrium", "principles of economics"]),
        Concept("keynes", "Keynes and effective demand", .history, ["keynes", "keynesian", "general theory", "effective demand", "animal spirits"]),
        Concept("monetarism", "Friedman and monetarism", .history, ["friedman", "monetarism", "monetarist", "natural rate"]),
        Concept("mercantilism", "Mercantilists and physiocrats", .history, ["mercantilism", "mercantilist", "physiocrats", "quesnay", "tableau economique"]),
        Concept("hayek", "Hayek and the Austrian school", .history, ["hayek", "austrian school", "use of knowledge", "socialist calculation"]),
        Concept("galton", "Galton, Pearson and the birth of statistics", .history, ["galton", "karl pearson", "regression to the mean", "regression towards mediocrity"]),
    ]

    public static let seedLinks: [ConceptLink] = [
        ConceptLink("regression", "demand", "estimating demand curves from price-quantity data"),
        ConceptLink("regression", "elasticity", "a log-log regression slope is an elasticity"),
        ConceptLink("regression", "production", "estimating Cobb-Douglas production functions"),
        ConceptLink("correlation", "regression", "the OLS slope is covariance over variance"),
        ConceptLink("galton", "regression", "Galton coined 'regression' studying heights"),
        ConceptLink("lagrange", "consumer", "maximise utility subject to the budget constraint"),
        ConceptLink("lagrange", "production", "cost minimisation for a given output"),
        ConceptLink("optimisation", "markets", "profit maximisation: MR = MC"),
        ConceptLink("derivatives", "production", "marginal cost and marginal product are derivatives"),
        ConceptLink("derivatives", "elasticity", "point elasticity = (dQ/dP)(P/Q)"),
        ConceptLink("partials", "consumer", "marginal utilities and the MRS"),
        ConceptLink("marginalists", "derivatives", "the marginalists put calculus at the centre of economics"),
        ConceptLink("marginalists", "consumer", "diminishing marginal utility"),
        ConceptLink("marshall", "demand", "Marshall's supply-and-demand 'scissors'"),
        ConceptLink("marshall", "elasticity", "Marshall formalised price elasticity"),
        ConceptLink("smith", "markets", "the invisible hand and competitive markets"),
        ConceptLink("smith", "production", "division of labour and productivity"),
        ConceptLink("ricardo", "trade", "comparative advantage"),
        ConceptLink("malthus", "growth", "population growth vs diminishing returns"),
        ConceptLink("malthus", "exp-log", "exponential population vs linear food growth"),
        ConceptLink("keynes", "macro-output", "effective demand and the multiplier"),
        ConceptLink("keynes", "unemployment", "involuntary unemployment"),
        ConceptLink("monetarism", "inflation", "the quantity theory of money"),
        ConceptLink("monetarism", "unemployment", "the natural rate and the expectations-augmented Phillips curve"),
        ConceptLink("series", "macro-output", "the multiplier is a geometric series"),
        ConceptLink("series", "inflation", "discounting with interest rates"),
        ConceptLink("exp-log", "growth", "growth rates and the rule of 70"),
        ConceptLink("index-numbers", "inflation", "CPI measures inflation"),
        ConceptLink("index-numbers", "macro-output", "real vs nominal GDP deflators"),
        ConceptLink("matrices", "demand", "solving simultaneous market equilibria"),
        ConceptLink("integration", "welfare", "consumer surplus is an integral under demand"),
        ConceptLink("distributions", "games", "mixed strategies and expected payoffs"),
        ConceptLink("probability", "games", "expected payoffs under uncertainty"),
        ConceptLink("inference", "regression", "t-tests on regression coefficients"),
        ConceptLink("sampling", "inference", "the CLT justifies confidence intervals"),
        ConceptLink("normal", "sampling", "sample means are approximately normal"),
        ConceptLink("descriptive", "unemployment", "summarising labour market data"),
        ConceptLink("hayek", "markets", "prices as information"),
        ConceptLink("marx", "production", "labour, capital and surplus"),
        ConceptLink("mercantilism", "trade", "trade surpluses vs Smith's critique"),
        ConceptLink("functions", "demand", "linear demand and supply functions"),
        ConceptLink("welfare", "games", "the prisoner's dilemma and market failure"),
    ]
}
