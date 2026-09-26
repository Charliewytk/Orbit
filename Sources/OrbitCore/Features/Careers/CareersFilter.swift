import Foundation

/// What the Careers screen shows: one place that combines the category, status,
/// eligibility, watchlist and search filters (so the screen, the dashboard and
/// tests all agree).
///
/// Bug this replaces: the screen combined a status tab with an optional "type"
/// picker in the view itself, and never looked at which categories the student
/// tracks. With only "Spring weeks" ticked in Careers settings, every summer
/// internship, placement and graduate scheme fetched earlier (or by the default
/// settings) stayed on screen, so "only spring weeks" looked broken. The filter
/// now always starts from the tracked categories.
public struct CareersFilter: Hashable, Sendable {
    public enum Status: String, CaseIterable, Sendable, Identifiable {
        case open, openingSoon, closed, all

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .open: "Open"
            case .openingSoon: "Opening soon"
            case .closed: "Closed"
            case .all: "All"
            }
        }
    }

    /// nil = every tracked category.
    public var category: OpportunityCategory?
    public var status: Status
    /// Starred or watched programmes only.
    public var watchlistOnly: Bool
    /// Hide programmes limited to groups the student hasn't selected (and year-restricted ones).
    public var eligibleOnly: Bool
    /// Only programmes meant for first years (spring weeks, insights, events, "first year" in the name or notes).
    public var firstYearOnly: Bool
    /// Only programmes limited to one of the student's diversity groups.
    public var diversityOnly: Bool
    public var search: String
    /// "Opening soon" looks this far ahead.
    public var soonWindowDays: Int

    public init(category: OpportunityCategory? = nil, status: Status = .open, watchlistOnly: Bool = false,
                eligibleOnly: Bool = false, firstYearOnly: Bool = false, diversityOnly: Bool = false,
                search: String = "", soonWindowDays: Int = 60) {
        self.category = category; self.status = status; self.watchlistOnly = watchlistOnly
        self.eligibleOnly = eligibleOnly; self.firstYearOnly = firstYearOnly; self.diversityOnly = diversityOnly
        self.search = search; self.soonWindowDays = soonWindowDays
    }

    /// Filters and sorts. Open: closing soonest first. Opening soon: expected opening first.
    /// Closed: most recently closed first. All: company, then programme.
    public func apply(_ all: [Opportunity], preferences: CareersPreferences, now: Date) -> [Opportunity] {
        let tracker = CareersTracker(preferences: preferences, now: now)
        var list = all.filter { preferences.categories.contains($0.category) }
        if let category { list = list.filter { $0.category == category } }
        if watchlistOnly { list = list.filter { preferences.isWatched($0) } }
        if eligibleOnly { list = list.filter { preferences.isEligible($0) } }
        if firstYearOnly { list = list.filter(Self.isForFirstYears) }
        if diversityOnly {
            list = list.filter { o in
                guard let e = o.eligibility else { return false }
                return !DiversityGroup.groups(in: e).isDisjoint(with: preferences.diversityGroups)
            }
        }
        switch status {
        case .open:
            list = tracker.openNow(list)
        case .openingSoon:
            list = tracker.openingSoon(list, withinDays: soonWindowDays)
        case .closed:
            list = list.filter { $0.isClosed(now: now) }
                .sorted { ($0.closingDate ?? .distantPast) > ($1.closingDate ?? .distantPast) }
        case .all:
            list = list.sorted { ($0.company.lowercased(), $0.programme) < ($1.company.lowercased(), $1.programme) }
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { list = tracker.search(list, query: query) }
        return list
    }

    /// Counts per category for the segmented control (same filters, any category).
    public func counts(_ all: [Opportunity], preferences: CareersPreferences, now: Date) -> [OpportunityCategory: Int] {
        var copy = self
        copy.category = nil
        var out: [OpportunityCategory: Int] = [:]
        for o in copy.apply(all, preferences: preferences, now: now) { out[o.category, default: 0] += 1 }
        return out
    }

    /// Spring weeks, insight days and events, or anything that says it's for first years.
    public static func isForFirstYears(_ o: Opportunity) -> Bool {
        let text = [o.programme, o.notes ?? "", o.eligibility ?? ""].joined(separator: " ").lowercased()
        if text.contains("penultimate") || text.contains("final year")
            || (text.contains("graduat") && o.category != .springWeeks) {
            return false
        }
        if o.category == .springWeeks || o.category == .events { return true }
        return ["first year", "first-year", "1st year", "insight", "spring", "discovery", "taster", "early careers programme"]
            .contains { text.contains($0) }
    }
}
