import Foundation

// Careers: finance programmes (spring weeks, internships, placements, grad
// schemes, events) as listed on Trackr (app.the-trackr.com). Pure models and
// helpers; the Mac app fetches, diffs and notifies. Nothing here is personal
// except the watchlist preferences, which stay on the Mac.

/// A Trackr tracker page.
public enum OpportunityCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case springWeeks = "spring-weeks"
    case summerInternships = "summer-internships"
    case offCycle = "off-cycle"
    case industrialPlacements = "industrial-placements"
    case graduateProgrammes = "graduate-programmes"
    case events

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .springWeeks: "Spring weeks"
        case .summerInternships: "Summer internships"
        case .offCycle: "Off-cycle"
        case .industrialPlacements: "Industrial placements"
        case .graduateProgrammes: "Graduate programmes"
        case .events: "Events"
        }
    }

    /// The public tracker page (UK finance).
    public var pageURL: URL { URL(string: "https://app.the-trackr.com/uk-finance/\(rawValue)")! }
}

/// One programme row.
public struct Opportunity: Codable, Hashable, Sendable, Identifiable {
    /// Stable across fetches: normalised company + programme + category.
    public var id: String
    public var company: String
    public var programme: String
    public var category: OpportunityCategory
    /// Trackr's own id when the row came from its API.
    public var sourceID: String?
    /// "Women", "Black Heritage", "SEO London"… nil = open to everyone.
    public var eligibility: String?
    public var openingDate: Date?
    public var closingDate: Date?
    /// "Online Test", "Interviews"…
    public var latestStage: String?
    public var lastYearOpening: Date?
    /// Process steps (e.g. "Online test", "HireVue", "Interview").
    public var process: [String]
    /// Test platform / prep ("Cut-e", "SHL", "Pymetrics", "J.P. Morgan Prep").
    public var testPrep: String?
    public var rolling: Bool
    public var acceptanceRate: String?
    public var conversionRate: String?
    public var notes: String?
    public var url: String?
    /// Trackr's sector tags ("Bulge Bracket", "Buy-Side").
    public var sectors: [String]

    public init(company: String, programme: String, category: OpportunityCategory, sourceID: String? = nil,
                eligibility: String? = nil, openingDate: Date? = nil, closingDate: Date? = nil, latestStage: String? = nil,
                lastYearOpening: Date? = nil, process: [String] = [], testPrep: String? = nil, rolling: Bool = false,
                acceptanceRate: String? = nil, conversionRate: String? = nil, notes: String? = nil, url: String? = nil,
                sectors: [String] = []) {
        self.id = Opportunity.makeID(company: company, programme: programme, category: category)
        self.company = company; self.programme = programme; self.category = category; self.sourceID = sourceID
        self.eligibility = eligibility.nonEmptyTrimmed; self.openingDate = openingDate; self.closingDate = closingDate
        self.latestStage = latestStage.nonEmptyTrimmed; self.lastYearOpening = lastYearOpening; self.process = process
        self.testPrep = testPrep.nonEmptyTrimmed; self.rolling = rolling; self.acceptanceRate = acceptanceRate.nonEmptyTrimmed
        self.conversionRate = conversionRate.nonEmptyTrimmed; self.notes = notes.nonEmptyTrimmed; self.url = url.nonEmptyTrimmed
        self.sectors = sectors
    }

    public static func makeID(company: String, programme: String, category: OpportunityCategory) -> String {
        func norm(_ s: String) -> String {
            s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        }
        return "\(category.rawValue)|\(norm(company))|\(norm(programme))"
    }

    public var title: String { "\(company) \(programme)" }

    /// Applications are open: an opening date that has passed and no closing date before today.
    public func isOpen(now: Date) -> Bool {
        guard let opening = openingDate, CareersDay.days(from: now, to: opening) <= 0 else { return false }
        if let closing = closingDate, CareersDay.endOfDay(closing) < now { return false }
        return true
    }

    public func isClosed(now: Date) -> Bool {
        guard let closing = closingDate else { return false }
        return CareersDay.endOfDay(closing) < now
    }

    /// Last year's opening moved on a year (Trackr's best guess for this cycle).
    public var predictedOpening: Date? {
        guard openingDate == nil, let last = lastYearOpening else { return nil }
        return CareersDay.calendar.date(byAdding: .year, value: 1, to: last)
    }

    /// Whole days until the closing date (0 = closes today).
    public func daysToClose(now: Date) -> Int? {
        guard let closing = closingDate else { return nil }
        return CareersDay.days(from: now, to: closing)
    }
}

/// Programme dates are calendar days. They're stored as noon UTC so they never
/// slip a day in any UK time zone.
public enum CareersDay {
    public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    public static let london = TimeZone(identifier: "Europe/London")!

    public static func day(_ year: Int, _ month: Int, _ day: Int) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    /// The same calendar day as `date` (in UTC), at noon.
    public static func normalise(_ date: Date) -> Date {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return day(c.year ?? 2000, c.month ?? 1, c.day ?? 1) ?? date
    }

    /// 23:59 London time on that day.
    public static func endOfDay(_ day: Date) -> Date {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = Self.london
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return london.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: 23, minute: 59)) ?? day
    }

    /// Calendar days between now (London) and `day`.
    public static func days(from now: Date, to day: Date) -> Int {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = Self.london
        let n = london.dateComponents([.year, .month, .day], from: now)
        let today = Self.day(n.year ?? 2000, n.month ?? 1, n.day ?? 1) ?? now
        return calendar.dateComponents([.day], from: today, to: normalise(day)).day ?? 0
    }

    /// "10 Sep 26" → 10 September 2026. Also takes "10 Sep 2026", "10/09/2026" and ISO dates.
    public static func parse(_ text: String) -> Date? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s != "-", s != "—" else { return nil }
        if s.count >= 10, s.dropFirst(4).first == "-", let iso = ISO8601.parse(s) ?? ISO8601.parse(String(s.prefix(10))) {
            return normalise(iso)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone(identifier: "UTC")
        for format in ["d MMM yy", "d MMM yyyy", "d MMMM yyyy", "d MMMM yy", "dd/MM/yyyy", "dd/MM/yy"] {
            f.dateFormat = format
            if let d = f.date(from: s) {
                let c = calendar.dateComponents([.year, .month, .day], from: d)
                var year = c.year ?? 2000
                if year < 100 { year += 2000 }
                return day(year, c.month ?? 1, c.day ?? 1)
            }
        }
        return nil
    }

    /// "10 Sep 26".
    public static func short(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMM yy"
        return f.string(from: date)
    }
}

// MARK: - Eligibility and the watchlist

/// Diversity and access groups some programmes are limited to.
public enum DiversityGroup: String, Codable, CaseIterable, Sendable, Identifiable {
    case women, blackHeritage, ethnicMinority, socialMobility, lgbt, disability, organisations

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .women: "Women"
        case .blackHeritage: "Black heritage"
        case .ethnicMinority: "Ethnic minority (BAME)"
        case .socialMobility: "Social mobility"
        case .lgbt: "LGBTQ+"
        case .disability: "Disability"
        case .organisations: "Partner organisations (SEO London, upReach…)"
        }
    }

    /// Groups an eligibility string mentions ("Black/Women/SocMob" → three).
    public static func groups(in eligibility: String) -> Set<DiversityGroup> {
        let e = eligibility.lowercased()
        var out = Set<DiversityGroup>()
        if e.contains("women") || e.contains("female") || e.contains("woman") { out.insert(.women) }
        if e.contains("black") || e.contains("african") || e.contains("caribbean") { out.insert(.blackHeritage) }
        if e.contains("bame") || e.contains("ethnic") || e.contains("minorit") { out.insert(.ethnicMinority) }
        if e.contains("socmob") || e.contains("social mobility") || e.contains("first gen") || e.contains("state school")
            || e.contains("low income") { out.insert(.socialMobility) }
        if e.contains("lgbt") { out.insert(.lgbt) }
        if e.contains("disab") || e.contains("neurodiv") { out.insert(.disability) }
        if e.contains("seo") || e.contains("upreach") || e.contains("sponsors for educational") || e.contains("diversity org")
            || e.contains("10,000") || e.contains("10000") || e.contains("rare") || e.contains("mdp") { out.insert(.organisations) }
        return out
    }
}

/// Who the student is and what they want to hear about. Stored on the Mac.
public struct CareersPreferences: Codable, Hashable, Sendable {
    public var yearOfStudy: Int
    public var region: String
    /// Diversity programmes the student qualifies for (others are hidden from the watchlist).
    public var diversityGroups: Set<DiversityGroup>
    /// Programmes starred by id.
    public var starred: Set<String>
    /// Companies starred by name (lowercased): every programme of theirs is watched.
    public var starredCompanies: Set<String>
    /// Programmes the student never wants to hear about.
    public var muted: Set<String>
    /// Watch every eligible spring week without starring.
    public var watchAllSpringWeeks: Bool
    /// Categories to fetch.
    public var categories: Set<OpportunityCategory>
    public var notificationsEnabled: Bool
    public var createApplyTasks: Bool

    public init(yearOfStudy: Int = 1, region: String = "UK", diversityGroups: Set<DiversityGroup> = [],
                starred: Set<String> = [], starredCompanies: Set<String> = [], muted: Set<String> = [],
                watchAllSpringWeeks: Bool = true,
                categories: Set<OpportunityCategory> = [.springWeeks, .summerInternships, .events],
                notificationsEnabled: Bool = true, createApplyTasks: Bool = true) {
        self.yearOfStudy = yearOfStudy; self.region = region; self.diversityGroups = diversityGroups
        self.starred = starred; self.starredCompanies = starredCompanies; self.muted = muted
        self.watchAllSpringWeeks = watchAllSpringWeeks; self.categories = categories
        self.notificationsEnabled = notificationsEnabled; self.createApplyTasks = createApplyTasks
    }

    enum CodingKeys: String, CodingKey {
        case yearOfStudy, region, diversityGroups, starred, starredCompanies, muted, watchAllSpringWeeks, categories,
             notificationsEnabled, createApplyTasks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CareersPreferences()
        yearOfStudy = (try? c.decode(Int.self, forKey: .yearOfStudy)) ?? d.yearOfStudy
        region = (try? c.decode(String.self, forKey: .region)) ?? d.region
        diversityGroups = (try? c.decode(Set<DiversityGroup>.self, forKey: .diversityGroups)) ?? d.diversityGroups
        starred = (try? c.decode(Set<String>.self, forKey: .starred)) ?? d.starred
        starredCompanies = (try? c.decode(Set<String>.self, forKey: .starredCompanies)) ?? d.starredCompanies
        muted = (try? c.decode(Set<String>.self, forKey: .muted)) ?? d.muted
        watchAllSpringWeeks = (try? c.decode(Bool.self, forKey: .watchAllSpringWeeks)) ?? d.watchAllSpringWeeks
        categories = (try? c.decode(Set<OpportunityCategory>.self, forKey: .categories)) ?? d.categories
        notificationsEnabled = (try? c.decode(Bool.self, forKey: .notificationsEnabled)) ?? d.notificationsEnabled
        createApplyTasks = (try? c.decode(Bool.self, forKey: .createApplyTasks)) ?? d.createApplyTasks
    }

    /// Open to this student: no restriction, or only groups they've said they belong to.
    public func isEligible(_ o: Opportunity) -> Bool {
        if let notes = o.notes?.lowercased() {
            if yearOfStudy == 1 && (notes.contains("penultimate year only") || notes.contains("final year only")) { return false }
        }
        guard let e = o.eligibility, !e.isEmpty else { return true }
        let groups = DiversityGroup.groups(in: e)
        // An eligibility we can't read (e.g. "STEM only") counts as restricted.
        guard !groups.isEmpty else { return false }
        // "Black/Women" programmes accept either group.
        return !groups.isDisjoint(with: diversityGroups)
    }

    public func isStarred(_ o: Opportunity) -> Bool {
        starred.contains(o.id) || starredCompanies.contains(o.company.lowercased())
    }

    /// On the watchlist: starred, or an eligible spring week (first years), and not muted.
    public func isWatched(_ o: Opportunity) -> Bool {
        if muted.contains(o.id) { return false }
        if isStarred(o) { return true }
        return watchAllSpringWeeks && o.category == .springWeeks && isEligible(o)
    }
}

private extension Optional where Wrapped == String {
    var nonEmptyTrimmed: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s != "-", s != "—" else { return nil }
        return s
    }
}
