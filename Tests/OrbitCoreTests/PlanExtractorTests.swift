import XCTest
@testable import OrbitCore

final class PlanExtractorTests: XCTestCase {
    static let london = TimeZone(identifier: "Europe/London")!

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = london
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// "Now" for every test: Wednesday 14 October 2026, 20:00.
    static let now = date(2026, 10, 14, 20, 0)

    func extractor(_ router: LLMRouter? = nil) -> PlanExtractor {
        PlanExtractor(router: router, now: { PlanExtractorTests.now })
    }

    func msg(_ sender: String, _ h: Int, _ m: Int, _ text: String, day: Int = 14) -> ChatMessage {
        ChatMessage(sender: sender, date: Self.date(2026, 10, day, h, m), text: text,
                    isFromMe: sender == "Charlie", source: .whatsapp, conversation: "Sam")
    }

    var confirmedDinner: [ChatMessage] {
        [msg("Sam", 19, 32, "fancy dinner at Côte sat 7pm?"),
         msg("Charlie", 19, 33, "yes!! I'm in"),
         msg("Sam", 19, 35, "see you then 👍")]
    }

    // MARK: Rule stage

    func testProposedAndConfirmedPlan() async throws {
        let plans = await extractor().extract(from: confirmedDinner)
        XCTAssertEqual(plans.count, 1)
        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plan.title, "Dinner with Sam")
        XCTAssertEqual(plan.start, Self.date(2026, 10, 17, 19, 0))
        XCTAssertEqual(plan.location, "Côte")
        XCTAssertEqual(plan.people, ["Sam"])
        XCTAssertEqual(plan.source, .whatsapp)
        XCTAssertEqual(plan.quote, "fancy dinner at Côte sat 7pm?")
        XCTAssertGreaterThanOrEqual(plan.confidence, 0.9)
    }

    func testCancelledPlanIsDropped() async {
        let chat = [msg("Sam", 18, 0, "drinks tomorrow at 8?"),
                    msg("Charlie", 18, 5, "yes defo"),
                    msg("Sam", 19, 40, "ah sorry can't make it anymore, raincheck?")]
        let plans = await extractor().extract(from: chat)
        XCTAssertTrue(plans.isEmpty)
        let raw = extractor().ruleCandidates(in: chat)
        XCTAssertEqual(raw.count, 1)
        XCTAssertLessThan(raw[0].confidence, 0.25)
    }

    func testPlanNobodyAgreedToScoresLower() async throws {
        let unanswered = [msg("Sam", 18, 0, "pub tomorrow at 8?"),
                          msg("Charlie", 18, 30, "just got back from the library lol")]
        let agreed = [msg("Sam", 18, 0, "pub tomorrow at 8?"),
                      msg("Charlie", 18, 30, "go on then")]
        let lowPlans = await extractor().extract(from: unanswered)
        let highPlans = await extractor().extract(from: agreed)
        let low = try XCTUnwrap(lowPlans.first)
        let high = try XCTUnwrap(highPlans.first)
        XCTAssertEqual(low.title, "Drinks with Sam")
        XCTAssertEqual(low.start, Self.date(2026, 10, 15, 20, 0))
        XCTAssertEqual(high.start, low.start)
        XCTAssertLessThan(low.confidence, 0.5)
        XCTAssertGreaterThan(high.confidence, low.confidence + 0.3)
    }

    func testCounterProposalReplacesCancelledDay() async throws {
        let chat = [msg("Sam", 12, 0, "dinner sat at 7?"),
                    msg("Charlie", 12, 10, "can't do sat sorry, how about sun at 7?"),
                    msg("Sam", 12, 12, "sun works 👍")]
        let plans = await extractor().extract(from: chat)
        XCTAssertEqual(plans.count, 1)
        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plan.start, Self.date(2026, 10, 18, 19, 0))
        XCTAssertEqual(plan.title, "Dinner with Sam")
        XCTAssertGreaterThan(plan.confidence, 0.8)
    }

    func testOnlyReadsMessagesSinceCursor() async {
        let chat = [msg("Sam", 9, 0, "gym tomorrow at 7am?", day: 1)] + confirmedDinner
        let all = await extractor().extract(from: chat)
        XCTAssertEqual(all.count, 1, "the 2 Oct gym session is in the past")
        let since = await extractor().extract(from: confirmedDinner, since: Self.date(2026, 10, 14, 19, 34))
        XCTAssertTrue(since.isEmpty)
    }

    func testSharedText() async throws {
        let plans = await extractor().extract(fromSharedText: "Dinner w/ Sam, Sat 7pm", sentAt: Self.date(2026, 10, 14, 19, 0))
        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plan.title, "Dinner with Sam")
        XCTAssertEqual(plan.start, Self.date(2026, 10, 17, 19, 0))
        XCTAssertEqual(plan.source, .shared)
    }

    func testSharedWhatsAppLines() async throws {
        let text = "[14/10/2026, 19:32:05] Sam: pub tomorrow at 8?\n[14/10/2026, 19:33:00] Charlie: go on then"
        let plans = await extractor().extract(fromSharedText: text, myNames: ["Charlie"])
        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plan.title, "Drinks with Sam")
        XCTAssertEqual(plan.start, Self.date(2026, 10, 15, 20, 0))
        XCTAssertGreaterThan(plan.confidence, 0.8)
    }

    // MARK: AI stage

    final class Recorder: @unchecked Sendable {
        var requests: [LLMRequest] = []
    }

    func testAIPlansAreMergedWithRules() async throws {
        let recorder = Recorder()
        let reply = #"""
        {"plans":[
          {"title":"Dinner with Sam","start":"2026-10-17T19:00","end":null,"location":"Côte","people":["Sam","Charlie"],"confirmed":true,"confidence":0.9,"quote":"fancy dinner at Côte sat 7pm?"},
          {"title":"Group project meeting with Priya","start":"2026-10-15T14:00:00","people":["Priya"],"confirmed":true,"confidence":"0.7","quote":"are we still doing the thing Thursday?"}
        ]}
        """#
        let mock = MockLLMProvider { request in recorder.requests.append(request); return reply }
        let chat = confirmedDinner + [msg("Priya", 19, 50, "are we still doing the thing Thursday? after my 1pm"),
                                      msg("Charlie", 19, 51, "yep")]
        let result = await extractor(LLMRouter(providers: [mock])).analyze(chat)

        XCTAssertTrue(result.usedAI)
        XCTAssertNil(result.aiError)
        XCTAssertEqual(result.plans.map(\.title), ["Group project meeting with Priya", "Dinner with Sam"])
        XCTAssertEqual(result.plans[0].start, Self.date(2026, 10, 15, 14, 0))
        XCTAssertEqual(result.plans[0].confidence, 0.7, accuracy: 0.001)
        XCTAssertEqual(result.plans[1].people, ["Sam"], "the user is never listed as a guest")
        XCTAssertEqual(result.plans[1].confidence, 0.99, accuracy: 0.001)

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.purpose, .privateData)
        XCTAssertTrue(request.json)
        let prompt = request.messages.last?.text ?? ""
        XCTAssertTrue(prompt.contains("Today is Wednesday 14 October 2026"))
        XCTAssertTrue(prompt.contains("[Wed 14 Oct 2026 19:32] Sam: fancy dinner at Côte sat 7pm?"))
        XCTAssertTrue(prompt.contains("Me (Charlie): yes!! I'm in"))
    }

    func testAIFailureFallsBackToRules() async {
        struct Down: Error {}
        let broken = MockLLMProvider { _ in throw Down() }
        let result = await extractor(LLMRouter(providers: [broken])).analyze(confirmedDinner)
        XCTAssertFalse(result.usedAI)
        XCTAssertNotNil(result.aiError)
        XCTAssertEqual(result.plans.map(\.title), ["Dinner with Sam"])
    }

    func testPrivateMessagesNeverGoToCloudModels() async {
        let recorder = Recorder()
        let cloud = MockLLMProvider(displayName: "cloud", isLocal: false) { r in recorder.requests.append(r); return #"{"plans":[]}"# }
        let result = await extractor(LLMRouter(providers: [cloud])).analyze(confirmedDinner)
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertNotNil(result.aiError)
        XCTAssertEqual(result.plans.count, 1)
    }

    func testAICannotReviveCancelledPlan() async {
        let reply = #"{"plans":[{"title":"Drinks with Sam","start":"2026-10-15T20:00","people":["Sam"],"confirmed":true,"confidence":0.8,"quote":"drinks tomorrow at 8?"}]}"#
        let mock = MockLLMProvider { _ in reply }
        let chat = [msg("Sam", 18, 0, "drinks tomorrow at 8?"),
                    msg("Charlie", 18, 5, "yes defo"),
                    msg("Sam", 19, 40, "ah sorry can't make it anymore, raincheck?")]
        let plans = await extractor(LLMRouter(providers: [mock])).extract(from: chat)
        XCTAssertTrue(plans.isEmpty)
    }

    // MARK: Screenshots

    struct FakeOCR: OCREngine {
        let name = "fake"
        let lines: [OCRLine]
        func recognize(image: Data, hint: String?) async throws -> OCRResult { OCRResult(lines: lines, engine: name) }
    }

    func testScreenshotBubbles() async throws {
        let ocr = FakeOCR(lines: [
            OCRLine(text: "Zoë", confidence: 0.99, box: [0.05, 0.02, 0.1, 0.03]),
            OCRLine(text: "Today", confidence: 0.99, box: [0.45, 0.06, 0.1, 0.03]),
            OCRLine(text: "fancy brunch sunday? 10:14", confidence: 0.95, box: [0.05, 0.1, 0.5, 0.04]),
            OCRLine(text: "yes! 11ish?", confidence: 0.95, box: [0.6, 0.16, 0.3, 0.04]),
            OCRLine(text: "10:15 ✓✓", confidence: 0.9, box: [0.8, 0.2, 0.1, 0.03]),
            OCRLine(text: "perfect 👍 10:16", confidence: 0.95, box: [0.05, 0.25, 0.3, 0.04]),
        ])
        let takenAt = Self.date(2026, 10, 14, 10, 20)
        let messages = PlanExtractor.messages(fromOCR: try await ocr.recognize(image: Data(), hint: nil), takenAt: takenAt)
        XCTAssertEqual(messages.map(\.text), ["Zoë", "fancy brunch sunday?", "yes! 11ish?", "perfect 👍"])
        XCTAssertEqual(messages.map(\.isFromMe), [false, false, true, false])
        XCTAssertEqual(messages[2].date, Self.date(2026, 10, 14, 10, 15))

        let plans = try await extractor().extract(fromScreenshot: Data(), ocr: ocr, takenAt: takenAt)
        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plan.title, "Brunch")
        XCTAssertEqual(plan.start, Self.date(2026, 10, 18, 11, 0))
        XCTAssertEqual(plan.source, .screenshot)
        XCTAssertGreaterThan(plan.confidence, 0.7)
    }
}
