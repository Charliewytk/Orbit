import XCTest
@testable import OrbitCore

/// Rows as the student pasted them from app.the-trackr.com/uk-finance/spring-weeks
/// (My Status and Process are icons, so they're missing from copied text).
enum TrackrFixtures {
    static let pastedRows: [[String]] = [
        ["J.P. Morgan", "2027 Spring Into JPMorganChase", "", "", "", "", "31 Aug 25", "J.P. Morgan Prep", "Yes", "",
         "100/10000 (~1%)", "100% fast-tracked", "HireVue consists of 3 questions"],
        ["Nomura", "2027 Spring Insight Programme", "Women, SEO London", "31 Aug 26", "10 Jan 27", "", "31 Aug 25", "Cut-e", "Yes"],
        ["Blackstone", "2027 Spring Insight Programme", "", "17 Sep 26", "16 Oct 26", "Online Test", "16 Sep 25", "Pymetrics", "No",
         "Non-Convertible", "Typically only 3 first-year students receive an offer"],
        ["Jefferies", "2027 Spring Week Programme", "", "31 Aug 26", "30 Nov 26", "", "03 Nov 25", "SHL", "Yes"],
    ]

    /// Trimmed from GET https://api.the-trackr.com/programmes?region=UK&industry=Finance&season=2027&type=spring-weeks
    static let apiJSON = """
    {"programmes":[
     {"id":"xz8xvujvhm","groupId":null,"name":"2027 Spring Into JPMorganChase","companyId":"j-p-morgan","url":null,
      "region":"UK","industry":"Finance","season":"2027","type":"spring-weeks","divisions":[],"disciplines":[],
      "categories":["Bulge Bracket"],"locations":[],"format":null,"eligibility":null,"process":["HV"],
      "openingDate":null,"closingDate":null,"lastYearOpening":"2025-08-31T00:00:00.000Z","eventDate":null,
      "currentStage":null,"rolling":true,"cv":true,"writtenAnswers":"No","acceptanceRate":"100/10000 (~1%)",
      "conversionRate":"100% fast-tracked","coverLetter":"Yes","notes":"HireVue consists of 3 questions","pinned":false,"status":null,
      "company":{"id":"j-p-morgan","name":"J.P. Morgan","description":"…","careersSite":"https://careers.jpmorgan.com/",
                 "ukJtpName":"J.P. Morgan Prep","ukJtpLink":"","usJtpName":"","usJtpLink":""}},
     {"id":"43q4iqsaw4","groupId":"skisw6oc3n","name":"2027 - Women’s Immersion Programme - Global Markets & Investment Banking",
      "companyId":"nomura","url":"https://nomuracampus.tal.net/vx/candidate/so/pm/1/pl/1/opp/1477","region":"UK","industry":"Finance",
      "season":"2027","type":"spring-weeks","categories":["Middle Market"],"eligibility":"Women","process":["OA","INT"],
      "openingDate":"2026-08-31T00:00:00.000Z","closingDate":"2027-01-10T00:00:00.000Z","lastYearOpening":"2025-08-31T00:00:00.000Z",
      "currentStage":null,"rolling":true,"acceptanceRate":null,"conversionRate":"100% fast-tracked","notes":null,
      "company":{"id":"nomura","name":"Nomura","ukJtpName":"Cut-e"}},
     {"id":"mabdgbrr7y","groupId":null,"name":"2027 Spring Insight Programme","companyId":"blackstone",
      "url":"https://blackstone.wd1.myworkdayjobs.com/en-US/Blackstone_Campus_Careers/job/45529","type":"spring-weeks",
      "categories":["Buy-Side"],"eligibility":null,"process":["OA","HV"],"openingDate":"2026-09-17T00:00:00.000Z",
      "closingDate":"2026-10-16T00:00:00.000Z","lastYearOpening":"2025-09-16T00:00:00.000Z","currentStage":"Online Test",
      "rolling":false,"acceptanceRate":null,"conversionRate":"Non-Convertible","notes":"Typically only 3 first-year students receive an offer",
      "company":{"id":"blackstone","name":"Blackstone","ukJtpName":"Pymetrics"}},
     {"id":"nocompany","name":"Orphan","type":"spring-weeks","company":null}
    ],"groups":[{"id":"skisw6oc3n","name":"2027 Spring Insight Programme","status":null}]}
    """
}

final class CareersTrackerTests: XCTestCase {
    /// 26 September 2026, 10:00 London.
    let now = ISO8601.parse("2026-09-26T09:00:00Z")!

    func day(_ y: Int, _ m: Int, _ d: Int) -> Date { CareersDay.day(y, m, d)! }

    func testParsesPastedRows() {
        let rows = TrackrParser.parseTable(rows: TrackrFixtures.pastedRows, category: .springWeeks)
        XCTAssertEqual(rows.count, 4)
        let jpm = rows[0]
        XCTAssertEqual(jpm.company, "J.P. Morgan")
        XCTAssertEqual(jpm.programme, "2027 Spring Into JPMorganChase")
        XCTAssertNil(jpm.openingDate)
        XCTAssertEqual(jpm.lastYearOpening, day(2025, 8, 31))
        XCTAssertEqual(jpm.testPrep, "J.P. Morgan Prep")
        XCTAssertTrue(jpm.rolling)
        XCTAssertEqual(jpm.acceptanceRate, "100/10000 (~1%)")
        XCTAssertEqual(jpm.conversionRate, "100% fast-tracked")
        XCTAssertEqual(jpm.notes, "HireVue consists of 3 questions")
        XCTAssertEqual(jpm.id, "spring-weeks|jpmorgan|2027springintojpmorganchase")

        let nomura = rows[1]
        XCTAssertEqual(nomura.eligibility, "Women, SEO London")
        XCTAssertEqual(nomura.openingDate, day(2026, 8, 31))
        XCTAssertEqual(nomura.closingDate, day(2027, 1, 10))
        XCTAssertEqual(nomura.testPrep, "Cut-e")

        let blackstone = rows[2]
        XCTAssertEqual(blackstone.latestStage, "Online Test")
        XCTAssertFalse(blackstone.rolling)
        XCTAssertEqual(blackstone.closingDate, day(2026, 10, 16))
        XCTAssertEqual(rows[3].lastYearOpening, day(2025, 11, 3))
    }

    func testHeaderRowSetsLayout() {
        let header = TrackrParser.Column.allCases.map(\.rawValue)
        let row = ["", "Jefferies", "2027 Spring Week Programme", "", "31 Aug 26", "30 Nov 26", "", "03 Nov 25", "OA, INT", "SHL",
                   "Yes", "", "25/7500 (~0.33%)", "", ""]
        let parsed = TrackrParser.parseTable(rows: [header, row], category: .springWeeks)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].process, ["Online test", "Interview"])
        XCTAssertEqual(parsed[0].testPrep, "SHL")
        XCTAssertEqual(parsed[0].acceptanceRate, "25/7500 (~0.33%)")
    }

    func testPastedText() {
        let text = "Jefferies | 2027 Spring Week Programme | | 31 Aug 26 | 30 Nov 26 | | 03 Nov 25 | SHL | Yes\n\n"
        let parsed = TrackrParser.parsePasted(text, category: .springWeeks)
        XCTAssertEqual(parsed.first?.closingDate, day(2026, 11, 30))
    }

    func testParsesAPI() throws {
        let list = try TrackrParser.parseAPI(Data(TrackrFixtures.apiJSON.utf8), category: .springWeeks)
        XCTAssertEqual(list.count, 3, "rows without a company are dropped")
        XCTAssertEqual(list[0].process, ["HireVue"])
        XCTAssertEqual(list[0].url, "https://careers.jpmorgan.com/", "falls back to the careers site")
        XCTAssertEqual(list[1].closingDate, day(2027, 1, 10))
        XCTAssertEqual(list[1].eligibility, "Women")
        XCTAssertEqual(list[2].testPrep, "Pymetrics")
        XCTAssertEqual(list[2].sectors, ["Buy-Side"])
        XCTAssertEqual(list[2].sourceID, "mabdgbrr7y")
    }

    func testDates() {
        XCTAssertEqual(CareersDay.parse("10 Sep 26"), day(2026, 9, 10))
        XCTAssertEqual(CareersDay.parse("03 Nov 25"), day(2025, 11, 3))
        XCTAssertEqual(CareersDay.parse("2026-08-31T00:00:00.000Z"), day(2026, 8, 31))
        XCTAssertNil(CareersDay.parse(""))
        XCTAssertNil(CareersDay.parse("TBC"))
        XCTAssertEqual(CareersDay.short(day(2026, 9, 10)), "10 Sep 26")
    }

    func testOpenAndPrediction() {
        let rows = TrackrParser.parseTable(rows: TrackrFixtures.pastedRows, category: .springWeeks)
        let tracker = CareersTracker(preferences: CareersPreferences(), now: now)
        XCTAssertEqual(Set(tracker.openNow(rows).map(\.company)), ["Nomura", "Blackstone", "Jefferies"])
        XCTAssertEqual(rows[0].predictedOpening, day(2026, 8, 31))
        // J.P. Morgan's predicted date has passed: it's "any day now".
        XCTAssertEqual(tracker.openingSoon(rows).map(\.company), ["J.P. Morgan"])
    }

    func testEligibilityAndWatchlist() {
        let rows = TrackrParser.parseTable(rows: TrackrFixtures.pastedRows, category: .springWeeks)
        var prefs = CareersPreferences()
        XCTAssertFalse(prefs.isWatched(rows[1]), "diversity-only programmes are hidden by default")
        XCTAssertTrue(prefs.isWatched(rows[0]))
        prefs.diversityGroups = [.women]
        XCTAssertTrue(prefs.isWatched(rows[1]))
        prefs.muted = [rows[0].id]
        XCTAssertFalse(prefs.isWatched(rows[0]))
        XCTAssertEqual(DiversityGroup.groups(in: "Black/Women/SocMob"), [.blackHeritage, .women, .socialMobility])

        let internship = Opportunity(company: "Nomura", programme: "Summer", category: .summerInternships)
        XCTAssertFalse(prefs.isWatched(internship))
        prefs.starredCompanies = ["nomura"]
        XCTAssertTrue(prefs.isWatched(internship))
    }

    func testDiffEvents() {
        let old = TrackrParser.parseTable(rows: TrackrFixtures.pastedRows, category: .springWeeks)
        var new = old
        // J.P. Morgan opens today, closing in 6 days.
        new[0].openingDate = day(2026, 9, 26)
        new[0].closingDate = day(2026, 10, 2)
        new[0].url = "https://jpmc.fa.oraclecloud.com/"
        // Blackstone moves stage.
        new[2].latestStage = "Interviews"
        // A new listing appears.
        new.append(Opportunity(company: "Evercore", programme: "2027 Spring Week", category: .springWeeks,
                               lastYearOpening: day(2025, 10, 1)))
        let tracker = CareersTracker(preferences: CareersPreferences(starred: [old[2].id]), now: now)
        let events = tracker.events(old: old, new: new)
        let ids = Set(events.map(\.id))
        XCTAssertTrue(ids.contains("opened|\(old[0].id)"))
        XCTAssertTrue(ids.contains("closing7|\(old[0].id)"))
        XCTAssertTrue(ids.contains("stage|\(old[2].id)|Interviews"))
        XCTAssertTrue(ids.contains("new|spring-weeks|evercore|2027springweek"))
        // Evercore opened on 1 Oct last year: a reminder a week before.
        XCTAssertTrue(ids.contains("expected|spring-weeks|evercore|2027springweek|1 Oct 26"))
        XCTAssertTrue(events.first { $0.kind == .opened }!.notify)
        XCTAssertFalse(events.contains { $0.kind == .opened && $0.opportunityID == old[1].id }, "already open before")

        // Sent events aren't repeated.
        let again = tracker.events(old: new, new: new, sent: ids)
        XCTAssertTrue(again.isEmpty, "\(again.map(\.id))")
    }

    func testFirstRunIsQuiet() {
        let rows = TrackrParser.parseTable(rows: TrackrFixtures.pastedRows, category: .springWeeks)
        let events = CareersTracker(preferences: CareersPreferences(), now: now).events(old: nil, new: rows)
        XCTAssertFalse(events.contains { $0.kind == .opened || $0.kind == .newListing })
    }

    func testClosingSoonTwoDays() {
        let o = Opportunity(company: "Blackstone", programme: "Spring", category: .springWeeks,
                            openingDate: day(2026, 9, 17), closingDate: day(2026, 9, 27))
        let events = CareersTracker(preferences: CareersPreferences(), now: now).events(old: [o], new: [o])
        XCTAssertEqual(events.map(\.id), ["closing2|\(o.id)"])
        XCTAssertEqual(events.first?.title, "Blackstone closes in 1 day")
    }

    func testApplyTask() {
        let rows = TrackrParser.parseTable(rows: TrackrFixtures.pastedRows, category: .springWeeks)
        let tracker = CareersTracker(preferences: CareersPreferences(), now: now)
        let blackstone = tracker.applyTask(for: rows[2])
        XCTAssertEqual(blackstone.title, "Apply: Blackstone 2027 Spring Insight Programme")
        XCTAssertEqual(blackstone.deadline, CareersDay.endOfDay(day(2026, 10, 16)))
        XCTAssertTrue(blackstone.notes.contains("Pymetrics"))
        XCTAssertTrue(blackstone.notes.contains("games"))
        XCTAssertEqual(blackstone.sourceRef, "careers:\(rows[2].id)")

        // Rolling with a far-off close: two weeks.
        let nomura = tracker.applyTask(for: rows[1])
        XCTAssertEqual(nomura.deadline, now.addingTimeInterval(14 * 86400))
        XCTAssertTrue(nomura.notes.contains("Cut-e"))
    }

    func testSearchAndText() {
        let rows = TrackrParser.parseTable(rows: TrackrFixtures.pastedRows, category: .springWeeks)
        let tracker = CareersTracker(preferences: CareersPreferences(), now: now)
        XCTAssertEqual(tracker.search(rows, query: "pymetrics").map(\.company), ["Blackstone"])
        XCTAssertEqual(tracker.search(rows, query: "spring nomura").count, 1)
        let line = tracker.line(rows[2])
        XCTAssertTrue(line.contains("OPEN"))
        XCTAssertTrue(line.contains("closes 16 Oct 26"))
        XCTAssertTrue(tracker.line(rows[0]).contains("expected ~31 Aug 26"))
    }

    func testSeasonAndURL() {
        XCTAssertEqual(TrackrParser.season(for: .springWeeks, now: now), 2027)
        XCTAssertEqual(TrackrParser.season(for: .springWeeks, now: ISO8601.parse("2027-02-01T00:00:00Z")!), 2027)
        XCTAssertEqual(TrackrParser.apiURL(category: .springWeeks, season: 2027).absoluteString,
                       "https://api.the-trackr.com/programmes?region=UK&industry=Finance&season=2027&type=spring-weeks")
    }

    func testClient() async throws {
        let stub = FeatureStubTransport { _ in (200, TrackrFixtures.apiJSON) }
        let list = try await TrackrClient(http: HTTPClient(transport: stub)).fetch(category: .springWeeks, season: 2027)
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(stub.requests.first?.url?.query, "region=UK&industry=Finance&season=2027&type=spring-weeks")
    }

    func testPreferencesDecodeLeniently() throws {
        let prefs = try JSONDecoder().decode(CareersPreferences.self, from: Data(#"{"starred":["a"]}"#.utf8))
        XCTAssertEqual(prefs.starred, ["a"])
        XCTAssertTrue(prefs.watchAllSpringWeeks)
        XCTAssertEqual(prefs.yearOfStudy, 1)
    }

    func testTools() async throws {
        struct P: CareersEdToolsProvider {
            func careersOpenText(watchedOnly: Bool) async -> String { "open \(watchedOnly)" }
            func careersUpcomingText(days: Int, watchedOnly: Bool) async -> String { "up \(days) \(watchedOnly)" }
            func careersSearchText(query: String) async -> String { "q \(query)" }
            func edActivityText(since: Date?, course: String?) async -> String { "ed \(course ?? "-")" }
        }
        let tools = CareersEdTools.make(P())
        XCTAssertEqual(tools.map(\.name), CareersEdTools.names)
        let up = try await tools[1].run(["days": .number(10)])
        XCTAssertEqual(up, "up 10 true")
        let ed = try await tools[3].run(["course": .string("bee1022")])
        XCTAssertEqual(ed, "ed BEE1022")
    }
}
