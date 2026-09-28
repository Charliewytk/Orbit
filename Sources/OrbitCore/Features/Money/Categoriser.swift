import Foundation

/// Where a transaction's category came from.
public enum CategorySource: String, Codable, Sendable { case override, rule, bank, ai, fallback, flow }

/// Sorts transactions into spending categories.
///
/// Order: the student's own overrides (learned per merchant) → specific merchant
/// rules that refine the bank's category (Deliveroo is "eating out" at Monzo but
/// "takeaway" here; Spotify is "entertainment" there but "subscriptions" here) →
/// the bank's own category → general merchant rules → the local AI's guesses →
/// "general".
public struct Categoriser: Codable, Hashable, Sendable {
    /// merchant key → category the student chose.
    public var overrides: [String: SpendingCategory]
    /// merchant key → category the local AI suggested.
    public var aiGuesses: [String: SpendingCategory]

    public init(overrides: [String: SpendingCategory] = [:], aiGuesses: [String: SpendingCategory] = [:]) {
        self.overrides = overrides; self.aiGuesses = aiGuesses
    }

    /// Categories where a merchant rule beats the bank's label.
    static let refining: Set<SpendingCategory> = [.takeaway, .subscriptions, .goingOut, .rent, .education]

    /// Ordered: earlier patterns win (so "uber eats" is checked before "uber").
    public static let rules: [(String, SpendingCategory)] = [
        // Takeaway
        ("deliveroo", .takeaway), ("uber eats", .takeaway), ("ubereats", .takeaway), ("just eat", .takeaway),
        ("justeat", .takeaway), ("dominos", .takeaway), ("domino s", .takeaway), ("papa john", .takeaway), ("hungry panda", .takeaway),
        // Subscriptions
        ("spotify", .subscriptions), ("netflix", .subscriptions), ("apple.com", .subscriptions), ("itunes", .subscriptions),
        ("icloud", .subscriptions), ("apple music", .subscriptions), ("amazon prime", .subscriptions), ("prime video", .subscriptions),
        ("amznprime", .subscriptions), ("disney plus", .subscriptions), ("disneyplus", .subscriptions), ("youtube premium", .subscriptions),
        ("google youtube", .subscriptions), ("now tv", .subscriptions), ("audible", .subscriptions), ("openai", .subscriptions),
        ("chatgpt", .subscriptions), ("microsoft", .subscriptions), ("adobe", .subscriptions), ("playstation plus", .subscriptions),
        ("xbox game pass", .subscriptions), ("duolingo", .subscriptions), ("headspace", .subscriptions), ("strava", .subscriptions),
        ("puregym", .subscriptions), ("pure gym", .subscriptions), ("gym", .subscriptions), ("gym group", .subscriptions),
        ("notion", .subscriptions), ("grammarly", .subscriptions), ("patreon", .subscriptions), ("deezer", .subscriptions),
        ("tidal", .subscriptions), ("crunchyroll", .subscriptions), ("dazn", .subscriptions), ("amazon music", .subscriptions),
        ("quizlet", .subscriptions), ("chegg", .subscriptions), ("studocu", .subscriptions),
        // Going out (Exeter student life)
        ("students guild", .goingOut), ("student guild", .goingOut), ("guild", .goingOut), ("xpression", .goingOut),
        ("timepiece", .goingOut), ("unit one", .goingOut), ("lemon grove", .goingOut), ("lemmy", .goingOut),
        ("cavern", .goingOut), ("firehouse", .goingOut), ("vaults", .goingOut), ("black horse", .goingOut),
        ("fever", .goingOut), ("arena", .goingOut), ("wetherspoon", .goingOut), ("jd wetherspoon", .goingOut),
        ("fatsoma", .goingOut), ("fixr", .goingOut), ("skiddle", .goingOut), ("dice", .goingOut), ("pub", .goingOut),
        ("tavern", .goingOut), ("inn", .goingOut), ("bar", .goingOut), ("club", .goingOut), ("brewdog", .goingOut),
        // Rent / accommodation
        ("unite students", .rent), ("unite", .rent), ("iq student", .rent), ("fresh student", .rent), ("yugo", .rent),
        ("liberty living", .rent), ("student roost", .rent), ("host students", .rent), ("rent", .rent),
        // Uni & books
        ("waterstones", .education), ("blackwell", .education), ("university of", .education),
        // Groceries
        ("tesco", .groceries), ("sainsbury", .groceries), ("aldi", .groceries), ("lidl", .groceries), ("asda", .groceries),
        ("morrisons", .groceries), ("waitrose", .groceries), ("co op", .groceries), ("coop", .groceries), ("co.op", .groceries),
        ("iceland", .groceries), ("ocado", .groceries), ("spar", .groceries), ("costcutter", .groceries), ("one stop", .groceries),
        ("farmfoods", .groceries), ("budgens", .groceries), ("m and s simply food", .groceries), ("marks and spencer", .groceries),
        ("m and s", .groceries), ("londis", .groceries), ("nisa", .groceries),
        // Eating out
        ("nandos", .eatingOut), ("mcdonalds", .eatingOut), ("greggs", .eatingOut), ("pret", .eatingOut), ("costa", .eatingOut),
        ("starbucks", .eatingOut), ("caffe nero", .eatingOut), ("nero", .eatingOut), ("wagamama", .eatingOut), ("kfc", .eatingOut),
        ("burger king", .eatingOut), ("subway", .eatingOut), ("leon", .eatingOut), ("itsu", .eatingOut), ("five guys", .eatingOut),
        ("pizza express", .eatingOut), ("pizza hut", .eatingOut), ("franco manca", .eatingOut), ("gails", .eatingOut),
        ("tortilla", .eatingOut), ("wasabi", .eatingOut), ("cafe", .eatingOut), ("coffee", .eatingOut), ("restaurant", .eatingOut),
        // Transport (after "uber eats")
        ("tfl", .transport), ("transport for london", .transport), ("trainline", .transport), ("stagecoach", .transport),
        ("gwr", .transport), ("great western", .transport), ("national rail", .transport), ("uber", .transport), ("bolt", .transport),
        ("first bus", .transport), ("national express", .transport), ("megabus", .transport), ("avanti", .transport),
        ("crosscountry", .transport), ("cross country", .transport), ("lner", .transport), ("south western railway", .transport),
        ("swr", .transport), ("voi", .transport), ("lime", .transport), ("beryl", .transport), ("ringgo", .transport),
        ("justpark", .transport), ("esso", .transport), ("shell", .transport), ("bp", .transport), ("railcard", .transport),
        // Bills
        ("ee", .bills), ("o2", .bills), ("vodafone", .bills), ("three", .bills), ("giffgaff", .bills), ("lebara", .bills),
        ("id mobile", .bills), ("voxi", .bills), ("smarty", .bills), ("tv licen", .bills), ("octopus", .bills), ("edf", .bills),
        ("british gas", .bills), ("ovo", .bills), ("south west water", .bills), ("virgin media", .bills), ("bt group", .bills),
        ("sky", .bills), ("council tax", .bills),
        // Personal care
        ("boots", .personalCare), ("superdrug", .personalCare), ("barber", .personalCare), ("hair", .personalCare),
        ("pharmacy", .personalCare), ("lloyds pharmacy", .personalCare),
        // Entertainment
        ("odeon", .entertainment), ("vue", .entertainment), ("cineworld", .entertainment), ("picturehouse", .entertainment),
        ("cinema", .entertainment), ("ticketmaster", .entertainment), ("steam", .entertainment), ("playstation", .entertainment),
        ("nintendo", .entertainment), ("xbox", .entertainment),
        // Shopping
        ("amazon", .shopping), ("amzn", .shopping), ("argos", .shopping), ("primark", .shopping), ("asos", .shopping),
        ("h and m", .shopping), ("zara", .shopping), ("uniqlo", .shopping), ("jd sports", .shopping), ("ebay", .shopping),
        ("vinted", .shopping), ("depop", .shopping), ("ikea", .shopping), ("tk maxx", .shopping), ("john lewis", .shopping),
        ("currys", .shopping), ("apple store", .shopping), ("wilko", .shopping), ("b and m", .shopping),
        ("home bargains", .shopping), ("poundland", .shopping), ("shein", .shopping), ("temu", .shopping),
    ]

    /// First matching rule. Short patterns (≤ 3 letters) must match whole words.
    public static func rule(for key: String) -> SpendingCategory? {
        guard !key.isEmpty else { return nil }
        let words = Set(key.split(separator: " ").map(String.init))
        for (pattern, category) in rules {
            if pattern.count <= 4 && !pattern.contains(" ") {
                if words.contains(pattern) { return category }
            } else if key.contains(pattern) {
                return category
            }
        }
        return nil
    }

    public func categorise(_ tx: MoneyTransaction) -> (category: SpendingCategory, source: CategorySource) {
        let key = tx.merchantKey
        if let o = overrides[key] { return (o, .override) }
        if tx.isInternal { return (.transfers, .flow) }
        let bank = SpendingCategory(monzo: tx.bankCategory)
        if tx.amountPence > 0, bank == nil || bank == .income || bank == .transfers {
            // Money in with no clear spending category is income (refunds keep their category).
            if let r = Self.rule(for: key), tx.bankCategory != nil { return (r, .rule) }
            return (bank ?? .income, bank == nil ? .flow : .bank)
        }
        let rule = Self.rule(for: key)
        if let r = rule, Self.refining.contains(r), bank != .transfers, bank != .savings { return (r, .rule) }
        if let b = bank { return (b, .bank) }
        if let r = rule { return (r, .rule) }
        if let ai = aiGuesses[key] { return (ai, .ai) }
        let t = (tx.type ?? "").lowercased()
        if t.contains("atm") || t.contains("cash") { return (.cash, .flow) }
        return (.general, .fallback)
    }

    /// Learns a correction: every transaction from that merchant uses it from now on.
    public mutating func learn(_ tx: MoneyTransaction, as category: SpendingCategory) {
        let key = tx.merchantKey
        guard !key.isEmpty else { return }
        overrides[key] = category
    }

    /// Merchants that fell through to "general" and haven't been asked about yet.
    public func unknownMerchants(_ txs: [MoneyTransaction], limit: Int = 40) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tx in txs where tx.isDebit && !tx.isInternal {
            let (c, s) = categorise(tx)
            guard c == .general, s == .fallback else { continue }
            let key = tx.merchantKey
            if !key.isEmpty, aiGuesses[key] == nil, seen.insert(key).inserted { out.append(key) }
            if out.count >= limit { break }
        }
        return out
    }

    struct AIReply: Decodable { let categories: [String: String] }

    /// Asks the local AI (never a cloud model) to categorise merchant names.
    public static func aiCategorise(_ merchants: [String], router: LLMRouter) async -> [String: SpendingCategory] {
        guard !merchants.isEmpty else { return [:] }
        let options = SpendingCategory.allCases.map(\.rawValue).joined(separator: ", ")
        let system = """
        You categorise UK card-payment merchant names for a university student's budget.
        Allowed categories: \(options). Use "general" if unsure.
        Reply with JSON only: {"categories": {"<merchant>": "<category>"}}
        """
        guard let reply = try? await router.completeJSON(AIReply.self, LLMRequest(
            messages: [.system(system), .user(merchants.joined(separator: "\n"))], purpose: .privateData, temperature: 0)) else {
            return [:]
        }
        var out: [String: SpendingCategory] = [:]
        for (k, v) in reply.categories {
            if let c = SpendingCategory(rawValue: v) ?? SpendingCategory(monzo: v) { out[k.lowercased()] = c }
        }
        return out
    }
}
