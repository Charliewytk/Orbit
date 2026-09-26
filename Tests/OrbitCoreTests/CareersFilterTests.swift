import XCTest
@testable import OrbitCore

final class CareersFilterTests: XCTestCase {
    /// 26 September 2026, 10:00 London.
    let now = ISO8601.parse("2026-09-26T09:00:00Z")!

    func day(_ y: Int, _ m: Int, _ d: Int) -> Date { CareersDay.day(y, m, d)! }

    private var sample: [Opportunity] {
        [
            Opportunity(company: "Nomura", programme: "2027 Spring Insight", category: .springWeeks,
                        openingDate: day(2026, 8, 31), closingDate: day(2027, 1, 10)),
            Opportunity(company: "Blackstone", programme: "2027 Spring Insight Programme", category: .springWeeks,
                        openingDate: day(2026, 9, 17), closingDate: day(2026, 10, 16)),
            Opportunity(company: "Goldman Sachs", programme: "2027 Women's Spring Week", category: .springWeeks,
                        eligibility: "Women", openingDate: day(2026, 9, 1), closingDate: day(2026, 11, 1)),
            Opportunity(company: "J.P. Morgan", programme: "Spring Into JPMorganChase", category: .springWeeks,
                        lastYearOpening: day(2025, 10, 10)),
            Opportunity(company: "Barclays", programme: "2027 Summer Analyst", category: .summerInternships,
                        openingDate: day(2026, 8, 20), closingDate: day(2026, 12, 1)),
            Opportunity(company: "HSBC", programme: "Industrial Placement", category: .industrialPlacements,
                        openingDate: day(2026, 9, 1), closingDate: day(2026, 12, 1)),
            Opportunity(company: "Citi", programme: "2026 Spring Week", category: .springWeeks,
                        openingDate: day(2025, 9, 1), closingDate: day(2025, 11, 1)),
            Opportunity(company: "Optiver", programme: "Insight Day", category: .events,
                        openingDate: day(2026, 9, 1), closingDate: day(2026, 10, 30)),
        ]
    }

    /// The reported bug: with only spring weeks tracked, internships and placements
    /// fetched earlier still showed. The old screen logic was `tracker.openNow(all)`
    /// plus an optional category, which ignores what's tracked.
    func testOnlySpringWeeksTrackedHidesOtherCategories() {
        var prefs = CareersPreferences()
        prefs.categories = [.springWeeks]
        let oldScreenLogic = CareersTracker(preferences: prefs, now: now).openNow(sample)
        XCTAssertTrue(oldScreenLogic.contains { $0.category != .springWeeks }, "reproduces the bug")

        let shown = CareersFilter(status: .open).apply(sample, preferences: prefs, now: now)
        XCTAssertFalse(shown.isEmpty)
        XCTAssertTrue(shown.allSatisfy { $0.category == .springWeeks })
        XCTAssertEqual(Set(shown.map(\.company)), ["Nomura", "Blackstone", "Goldman Sachs"])
    }

    func testCategorySegmentFiltersEveryStatus() {
        var prefs = CareersPreferences()
        prefs.categories = Set(OpportunityCategory.allCases)
        for status in CareersFilter.Status.allCases {
            let shown = CareersFilter(category: .springWeeks, status: status).apply(sample, preferences: prefs, now: now)
            XCTAssertTrue(shown.allSatisfy { $0.category == .springWeeks }, "status \(status)")
        }
        let open = CareersFilter(category: .summerInternships, status: .open).apply(sample, preferences: prefs, now: now)
        XCTAssertEqual(open.map(\.company), ["Barclays"])
    }

    func testStatuses() {
        var prefs = CareersPreferences()
        prefs.categories = [.springWeeks]
        let soon = CareersFilter(status: .openingSoon).apply(sample, preferences: prefs, now: now)
        XCTAssertEqual(soon.map(\.company), ["J.P. Morgan"])
        let closed = CareersFilter(status: .closed).apply(sample, preferences: prefs, now: now)
        XCTAssertEqual(closed.map(\.company), ["Citi"])
        let open = CareersFilter(status: .open).apply(sample, preferences: prefs, now: now)
        // Closing soonest first.
        XCTAssertEqual(open.first?.company, "Blackstone")
    }

    func testEligibilityAndDiversity() {
        var prefs = CareersPreferences()
        prefs.categories = [.springWeeks]
        var filter = CareersFilter(status: .open, eligibleOnly: true)
        XCTAssertFalse(filter.apply(sample, preferences: prefs, now: now).contains { $0.company == "Goldman Sachs" })
        prefs.diversityGroups = [.women]
        XCTAssertTrue(filter.apply(sample, preferences: prefs, now: now).contains { $0.company == "Goldman Sachs" })
        filter.diversityOnly = true
        XCTAssertEqual(filter.apply(sample, preferences: prefs, now: now).map(\.company), ["Goldman Sachs"])
    }

    func testFirstYearAndSearch() {
        var prefs = CareersPreferences()
        prefs.categories = Set(OpportunityCategory.allCases)
        let firstYear = CareersFilter(status: .open, firstYearOnly: true).apply(sample, preferences: prefs, now: now)
        XCTAssertFalse(firstYear.contains { $0.company == "Barclays" || $0.company == "HSBC" })
        XCTAssertTrue(firstYear.contains { $0.company == "Optiver" })
        let search = CareersFilter(status: .all, search: "nomura").apply(sample, preferences: prefs, now: now)
        XCTAssertEqual(search.map(\.company), ["Nomura"])
    }

    func testCounts() {
        var prefs = CareersPreferences()
        prefs.categories = [.springWeeks, .summerInternships]
        let counts = CareersFilter(category: .summerInternships, status: .open).counts(sample, preferences: prefs, now: now)
        XCTAssertEqual(counts[.springWeeks], 3)
        XCTAssertEqual(counts[.summerInternships], 1)
        XCTAssertNil(counts[.industrialPlacements])
    }

    func testParsedAPIRowsKeepTheirCategory() throws {
        let rows = try TrackrParser.parseAPI(Data(TrackrFixtures.apiJSON.utf8), category: .summerInternships)
        // The row's own "type" wins over the category that was asked for.
        XCTAssertTrue(rows.allSatisfy { $0.category == .springWeeks })
    }
}

final class FirmDomainsTests: XCTestCase {
    func testKnownFirms() {
        XCTAssertEqual(FirmDomains.domain(for: "J.P. Morgan"), "jpmorgan.com")
        XCTAssertEqual(FirmDomains.domain(for: "JPMorgan Chase & Co."), "jpmorgan.com")
        XCTAssertEqual(FirmDomains.domain(for: "Goldman Sachs"), "goldmansachs.com")
        XCTAssertEqual(FirmDomains.domain(for: "Goldman Sachs Asset Management"), "goldmansachs.com")
        XCTAssertEqual(FirmDomains.domain(for: "Deutsche Bank AG"), "db.com")
        XCTAssertEqual(FirmDomains.domain(for: "Bank of America"), "bankofamerica.com")
        XCTAssertEqual(FirmDomains.domain(for: "BofA Securities"), "bankofamerica.com")
        XCTAssertEqual(FirmDomains.domain(for: "Rothschild & Co"), "rothschildandco.com")
        XCTAssertEqual(FirmDomains.domain(for: "Barclays Bank PLC"), "barclays.com")
        XCTAssertEqual(FirmDomains.domain(for: "Millennium"), "mlp.com")
        XCTAssertEqual(FirmDomains.domain(for: "Ares Management"), "aresmgmt.com")
        XCTAssertEqual(FirmDomains.domain(for: "G-Research"), "gresearch.com")
        XCTAssertEqual(FirmDomains.domain(for: "Susquehanna International Group"), "sig.com")
        XCTAssertEqual(FirmDomains.domain(for: "McKinsey & Company"), "mckinsey.com")
        XCTAssertEqual(FirmDomains.domain(for: "Ernst & Young"), "ey.com")
        XCTAssertEqual(FirmDomains.domain(for: "Moody's"), "moodys.com")
        XCTAssertEqual(FirmDomains.domain(for: "S&P Global"), "spglobal.com")
        XCTAssertEqual(FirmDomains.domain(for: "Société Générale"), "societegenerale.com")
        XCTAssertEqual(FirmDomains.domain(for: "RBC Capital Markets"), "rbccm.com")
        XCTAssertEqual(FirmDomains.domain(for: "D. E. Shaw"), "deshaw.com")
        XCTAssertTrue(FirmDomains.isKnown("Nomura"))
    }

    func testFallbackGuess() {
        XCTAssertEqual(FirmDomains.domain(for: "Acme Widgets Ltd"), "acmewidgets.com")
        XCTAssertEqual(FirmDomains.domain(for: "Inizio Ignite"), "inizioignite.com")
        XCTAssertFalse(FirmDomains.isKnown("Acme Widgets Ltd"))
    }

    func testLogoURLAndMonogram() {
        XCTAssertEqual(FirmDomains.logoURL(for: "Citadel")?.absoluteString,
                       "https://www.google.com/s2/favicons?domain=citadel.com&sz=128")
        XCTAssertEqual(FirmDomains.monogram("Goldman Sachs"), "GS")
        XCTAssertEqual(FirmDomains.monogram("Nomura"), "N")
        XCTAssertEqual(FirmDomains.hue(for: "Nomura"), FirmDomains.hue(for: "NOMURA"))
    }
}

final class DailyStatsTests: XCTestCase {
    let tz = TimeZone(identifier: "Europe/London")!
    /// Saturday 26 September 2026, 18:00 London.
    let now = ISO8601.parse("2026-09-26T17:00:00Z")!

    private func at(_ daysAgo: Int, hour: Int = 12) -> Date {
        now.addingTimeInterval(Double(-daysAgo) * 86400 + Double(hour - 18) * 3600)
    }

    func testBuildGroupsByLondonDay() {
        let late = ISO8601.parse("2026-09-25T23:30:00Z")! // 00:30 on the 26th in London
        let days = DailyStatsBuilder.build(focus: [(late, 25), (at(0), 30)], completedBlocks: [(at(1), 60)],
                                           completedTasks: [at(0), at(0), at(2)], reviews: ["2026-09-26": 12],
                                           timeZone: tz)
        let map = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0) })
        XCTAssertEqual(map["2026-09-26"]?.studyMinutes, 55)
        XCTAssertEqual(map["2026-09-26"]?.tasksDone, 2)
        XCTAssertEqual(map["2026-09-26"]?.reviews, 12)
        XCTAssertEqual(map["2026-09-25"]?.studyMinutes, 60)
        XCTAssertEqual(map["2026-09-24"]?.tasksDone, 1)
    }

    func testStreakCountsUntilAGapAndTodayIsGrace() {
        let days = [
            DayStats(day: "2026-09-25", tasksDone: 1),
            DayStats(day: "2026-09-24", studyMinutes: 40),
            DayStats(day: "2026-09-23", reviews: 10),
            DayStats(day: "2026-09-21", tasksDone: 3),
        ]
        let m = Momentum(days: days, goals: DailyGoals(), timeZone: tz)
        // Today (26th) not active yet: streak runs to yesterday.
        XCTAssertEqual(m.streak(now: now), 3)
        XCTAssertFalse(m.todayCounts(now: now))
        let withToday = Momentum(days: days + [DayStats(day: "2026-09-26", tasksDone: 1)], goals: DailyGoals(), timeZone: tz)
        XCTAssertEqual(withToday.streak(now: now), 4)
        XCTAssertEqual(withToday.bestStreak(), 4)
    }

    func testRingsAndScore() {
        let goals = DailyGoals(studyMinutes: 120, tasks: 4, reviews: 20)
        let s = DayStats(day: "x", studyMinutes: 60, tasksDone: 4, reviews: 40)
        XCTAssertEqual(s.studyProgress(goals), 0.5, accuracy: 0.001)
        XCTAssertEqual(s.taskProgress(goals), 1, accuracy: 0.001)
        XCTAssertEqual(s.reviewProgress(goals), 2, accuracy: 0.001)
        XCTAssertEqual(s.score(goals), (0.5 + 1 + 1) / 3, accuracy: 0.001)
        XCTAssertFalse(s.allGoalsMet(goals))
        XCTAssertEqual(Momentum.level(s, goals), 3)
        XCTAssertEqual(Momentum.level(DayStats(day: "y"), goals), 0)
    }

    func testHeatmapShape() {
        let m = Momentum(days: [DayStats(day: "2026-09-26", studyMinutes: 120, tasksDone: 5, reviews: 20)],
                         goals: DailyGoals(), timeZone: tz)
        let grid = m.heatmap(weeks: 12, now: now)
        XCTAssertEqual(grid.count, 12)
        XCTAssertTrue(grid.allSatisfy { $0.count == 7 })
        // Saturday is the 6th cell (Monday first); Sunday is still in the future.
        XCTAssertEqual(grid.last?[5]?.day, "2026-09-26")
        XCTAssertEqual(grid.last?[5]?.level, 4)
        XCTAssertNil(grid.last?[6] ?? nil)
    }

    func testGoalsDecodeLeniently() throws {
        let goals = try JSONDecoder().decode(DailyGoals.self, from: Data(#"{"tasks": 0}"#.utf8))
        XCTAssertEqual(goals.tasks, 1)
        XCTAssertEqual(goals.studyMinutes, 120)
    }
}
