import XCTest
@testable import OrbitCore

final class FeatureUpdateTests: XCTestCase {
    let fullSHA = "0123456789abcdef0123456789abcdef01234567"

    func release(body: String?, updated: String = "2026-09-26T10:00:00Z", zip: Bool = true) throws -> GitHubRelease {
        let assets = zip ? """
        [{"name":"Orbit-mac.dmg","browser_download_url":"https://github.com/Charliewytk/Orbit/releases/download/mac-latest/Orbit-mac.dmg","updated_at":"\(updated)","size":1},
         {"name":"Orbit-mac.zip","browser_download_url":"https://github.com/Charliewytk/Orbit/releases/download/mac-latest/Orbit-mac.zip","updated_at":"\(updated)","size":2}]
        """ : "[]"
        let bodyJSON = body.map { "\"\($0.replacingOccurrences(of: "\n", with: "\\n"))\"" } ?? "null"
        let json = #"{"tag_name":"mac-latest","name":"Orbit for Mac (latest)","published_at":"2026-09-26T10:00:00Z","body":\#(bodyJSON),"assets":\#(assets)}"#
        return try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    func testParsesSHAFromReleaseBody() throws {
        XCTAssertEqual(try release(body: "Latest Mac build from commit 0123456.\n\nsha: \(fullSHA)\n").commitSHA, fullSHA)
        XCTAssertEqual(try release(body: "**sha:** `\(fullSHA.uppercased())`").commitSHA, fullSHA)
        XCTAssertNil(try release(body: "no commit here").commitSHA)
        XCTAssertNil(try release(body: nil).commitSHA)
    }

    func testCompareWithRunningBuild() throws {
        let r = try release(body: "sha: \(fullSHA)")
        XCTAssertEqual(UpdateDecision.evaluate(r, currentSHA: fullSHA, buildDate: nil), .upToDate)
        XCTAssertEqual(UpdateDecision.evaluate(r, currentSHA: "0123456", buildDate: nil), .upToDate) // short SHA
        let newer = UpdateDecision.evaluate(r, currentSHA: "fedcba9876543210fedcba9876543210fedcba98", buildDate: nil)
        guard case .available(let sha, let url, _) = newer else { return XCTFail("\(newer)") }
        XCTAssertEqual(sha, fullSHA)
        XCTAssertEqual(url.lastPathComponent, "Orbit-mac.zip")
        // Local builds (no SHA) never offer an update.
        if case .unknown = UpdateDecision.evaluate(r, currentSHA: "", buildDate: Date()) {} else { XCTFail() }
        if case .unknown = UpdateDecision.evaluate(r, currentSHA: "$(ORBIT_BUILD_SHA)", buildDate: Date()) {} else { XCTFail() }
        // No zip asset.
        if case .unknown = UpdateDecision.evaluate(try release(body: "sha: \(fullSHA)", zip: false), currentSHA: fullSHA, buildDate: nil) {} else { XCTFail() }
    }

    func testFallsBackToAssetDateWithoutSHA() throws {
        let r = try release(body: "Latest build", updated: "2026-09-26T10:00:00Z")
        let published = ISO8601.parse("2026-09-26T10:00:00Z")!
        XCTAssertTrue(UpdateDecision.evaluate(r, currentSHA: fullSHA, buildDate: published.addingTimeInterval(-3600)).isAvailable)
        XCTAssertEqual(UpdateDecision.evaluate(r, currentSHA: fullSHA, buildDate: published.addingTimeInterval(-300)), .upToDate)
    }

    func testSameCommit() {
        XCTAssertTrue(UpdateDecision.sameCommit("ABCDEF1234", "abcdef1"))
        XCTAssertFalse(UpdateDecision.sameCommit("abcdef1", "abcdef2"))
        XCTAssertFalse(UpdateDecision.sameCommit("abc", "abc")) // too short to trust
    }

    func testInstallerScript() {
        let s = UpdateInstallerScript.make(pid: 4242, newApp: "/tmp/x/Orbit.app", destination: "/Applications/Orbit's.app", logFile: "/tmp/log")
        XCTAssertTrue(s.hasPrefix("#!/bin/bash"))
        XCTAssertTrue(s.contains("kill -0 4242"))
        XCTAssertTrue(s.contains("ditto '/tmp/x/Orbit.app' '/Applications/Orbit'\\''s.app'"))
        XCTAssertTrue(s.contains("xattr -dr com.apple.quarantine"))
        XCTAssertTrue(s.contains("open '/Applications/Orbit'\\''s.app'"))
    }

    // MARK: Tools

    struct StubProvider: FeatureToolsProvider {
        var local: Bool
        func flashcardsDueText(module: String?, limit: Int) async -> String { "cards \(module ?? "-") \(limit)" }
        func startFocus(taskQuery: String, minutes: Int?) async -> String { "focus \(taskQuery) \(minutes ?? 0)" }
        func weeklyReportText() async -> String { "report" }
        func feedbackThemesText(module: String?) async -> String { "themes" }
        func readingPlanText(week: Int?) async -> String { "reading \(week ?? 0)" }
        func moneySummaryText() async -> String { "£££" }
        func upcomingDeadlinesText(days: Int) async -> String { "deadlines \(days)" }
        func aiIsLocal() async -> Bool { local }
    }

    func testFeatureToolsAndMerge() async throws {
        let tools = FeatureTools.make(StubProvider(local: false))
        XCTAssertEqual(tools.map(\.name), FeatureTools.names)
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        let cards = try await byName["flashcards_due"]!.run(["module": .string("bee1022"), "limit": .number(50)])
        XCTAssertEqual(cards, "cards BEE1022 20")
        let money = try await byName["money_summary"]!.run([:])
        XCTAssertFalse(money.contains("£££")) // never to a cloud model
        let localMoney = try await FeatureTools.make(StubProvider(local: true)).first { $0.name == "money_summary" }!.run([:])
        XCTAssertEqual(localMoney, "£££")

        let old = AssistantTool(name: "flashcards_due", description: "old") { _ in "old" }
        let other = AssistantTool(name: "inbox", description: "x") { _ in "x" }
        let merged = FeatureTools.merge([old, other], tools)
        XCTAssertEqual(merged.filter { $0.name == "flashcards_due" }.count, 1)
        XCTAssertEqual(merged.count, tools.count + 1)
    }

    func testMorningBriefMentionsShortReview() {
        let tz = TimeZone(identifier: "Europe/London")!
        let now = DayCalendar(timeZone: tz).date(year: 2026, month: 10, day: 5, hour: 7)!
        let brief = MorningBriefBuilder().build(now: now, events: [], blocks: [], tasks: [], flashcardsDue: 35)
        let s = brief.plainSummary()
        XCTAssertTrue(s.contains("Flashcards due: 35. Suggest a 10-minute review of 20 cards (the rest can wait)."), s)
    }
}

extension UpdateStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .upToDate: "upToDate"
        case .available(let sha, let url, _): "available(\(sha ?? "-"), \(url))"
        case .unknown(let s): "unknown(\(s))"
        }
    }
}
