import XCTest
@testable import OrbitCore

final class MessageIntentClassifierTests: XCTestCase {
    typealias P = PlanExtractorTests

    /// The iMessage that used to become "Party, Thursday 21:00, 55% sure".
    static let tpPromo = "NEW TP EVENT ON SALE 🚨 Thursday 21:00 — tickets are live now, early bird going fast! fixr.co/event/tp-thursdays-freshers-2026-123456"

    func message(_ text: String, sender: String = "Timepiece", h: Int = 12, fromMe: Bool = false) -> ChatMessage {
        ChatMessage(sender: sender, date: P.date(2026, 10, 14, h, 0), text: text, isFromMe: fromMe,
                    source: .imessage, conversation: sender)
    }

    // MARK: Rules

    func testTicketDropPromoIsNotAPlan() throws {
        let c = MessageIntentClassifier().classifyWithRules(message(Self.tpPromo))
        XCTAssertEqual(c.intent, .ticketDrop)
        XCTAssertTrue(MessageIntentClassifier.isVeto(c))
        let drop = try XCTUnwrap(c.ticketDrop)
        XCTAssertEqual(drop.buyURL?.absoluteString, "https://fixr.co/event/tp-thursdays-freshers-2026-123456")
        XCTAssertEqual(drop.provider, .fixr)
        XCTAssertEqual(drop.eventStart, P.date(2026, 10, 15, 21, 0))
        XCTAssertEqual(drop.title, "TP Event")
    }

    func testCommittedPlansAreStillPlans() {
        let classifier = MessageIntentClassifier()
        XCTAssertEqual(classifier.classifyWithRules(message("got our tickets for TP thursday! see you there x", sender: "Sam")).intent, .plan)
        XCTAssertEqual(classifier.classifyWithRules(message("Your FIXR order is confirmed. Order number 88123 fixr.co/order/abc", sender: "FIXR")).intent, .plan)
        XCTAssertEqual(classifier.classifyWithRules(message("see you at the pub at 8", sender: "Sam")).intent, .plan)
    }

    func testNoiseIsIgnored() {
        let c = MessageIntentClassifier().classifyWithRules(message("lol did you see that", sender: "Sam"))
        XCTAssertEqual(c.intent, .noise)
    }

    // MARK: AI stage

    func testAIIsAskedWhenRulesUnsureAndReturnsStructuredDrop() async throws {
        let ai = MockLLMProvider { _ in
            #"{"intent":"ticket_drop","confidence":0.85,"event_title":"Halloween Social","event_start":"2026-10-31T22:00","buy_url":"https://www.skiddle.com/whats-on/x"}"#
        }
        let c = await MessageIntentClassifier(router: LLMRouter(providers: [ai]))
            .classify(message("Halloween social at the Lemmy 31st, who's coming?"))
        XCTAssertTrue(c.usedAI)
        XCTAssertEqual(c.intent, .ticketDrop)
        XCTAssertEqual(c.ticketDrop?.title, "Halloween Social")
        XCTAssertEqual(c.ticketDrop?.eventStart, P.date(2026, 10, 31, 22, 0))
    }

    func testAICannotOverruleRuleVeto() async {
        let ai = MockLLMProvider { _ in #"{"intent":"plan","confidence":0.9}"# }
        let c = await MessageIntentClassifier(router: LLMRouter(providers: [ai])).classify(message(Self.tpPromo))
        XCTAssertEqual(c.intent, .ticketDrop)
        XCTAssertFalse(c.usedAI)
    }

    // MARK: Plan extraction

    func testExtractorTurnsTPPromoIntoTicketDropNotPlan() async throws {
        let extractor = PlanExtractor(now: { P.now.addingTimeInterval(-8 * 3600) })
        let result = await extractor.analyze([message(Self.tpPromo)])
        XCTAssertTrue(result.plans.isEmpty, "promo must not be suggested as a plan")
        XCTAssertEqual(result.ticketDrops.count, 1)
        XCTAssertEqual(result.ticketDrops.first?.buyURL?.host, "fixr.co")
    }

    func testExtractorDropsAIPlanQuotingAPromo() async throws {
        // Simulates the old bug: the AI calls the promo a 55% party.
        let ai = MockLLMProvider { _ in
            #"{"plans":[{"title":"Party","start":"2026-10-15T21:00","people":[],"confidence":0.55,"quote":"NEW TP EVENT ON SALE 🚨 Thursday 21:00"}]}"#
        }
        let extractor = PlanExtractor(router: LLMRouter(providers: [ai]), now: { P.now.addingTimeInterval(-8 * 3600) })
        let result = await extractor.analyze([message(Self.tpPromo)])
        XCTAssertTrue(result.usedAI)
        XCTAssertTrue(result.plans.isEmpty)
        XCTAssertEqual(result.ticketDrops.count, 1)
    }

    func testRealPlanNextToPromoSurvives() async throws {
        let chat = [message(Self.tpPromo, sender: "Sam", h: 12),
                    message("fancy it? drinks at mine thursday 8pm first", sender: "Sam", h: 12),
                    ChatMessage(sender: "Charlie", date: P.date(2026, 10, 14, 12, 5), text: "yes I'm in",
                                isFromMe: true, source: .imessage, conversation: "Sam")]
        let result = await PlanExtractor(now: { P.now.addingTimeInterval(-8 * 3600) }).analyze(chat)
        XCTAssertEqual(result.plans.count, 1)
        XCTAssertEqual(result.plans.first?.start, P.date(2026, 10, 15, 20, 0))
        XCTAssertEqual(result.ticketDrops.count, 1)
    }

    func testPurchasedFixrEmailStillAutoAdds() throws {
        let email = EmailMessage(id: "fx1", account: .gmail, from: "tickets@fixr.co", fromName: "FIXR",
                                 subject: "Your tickets for TP Thursdays",
                                 snippet: "", body: "Here are your tickets!\nEvent: TP Thursdays\nDate: Thursday 15 October 2026\nTime: 21:00\nVenue: Timepiece\nOrder reference: ABC123",
                                 date: P.date(2026, 10, 14, 12, 0))
        let t = try XCTUnwrap(TicketEmailParser().parse(email))
        XCTAssertEqual(t.provider, .fixr)
        XCTAssertEqual(t.start, P.date(2026, 10, 15, 21, 0))
    }
}
