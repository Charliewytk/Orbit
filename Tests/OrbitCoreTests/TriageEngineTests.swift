import XCTest
@testable import OrbitCore

/// Counts calls and in-flight requests; replies after a short delay.
final class EmailLLMTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maxInFlight = 0
    private(set) var requests: [LLMRequest] = []

    func enter(_ r: LLMRequest) {
        lock.lock(); defer { lock.unlock() }
        requests.append(r); current += 1; maxInFlight = max(maxInFlight, current)
    }
    func leave() { lock.lock(); current -= 1; lock.unlock() }
}

struct EmailSlowLLMProvider: LLMProvider {
    let kind: LLMProviderKind = .mock
    let displayName = "slow"
    let isLocal = true
    let supportsVision = false
    let tracker: EmailLLMTracker
    let reply: @Sendable (LLMRequest) -> String

    func isAvailable() async -> Bool { true }
    func complete(_ request: LLMRequest) async throws -> String {
        tracker.enter(request)
        defer { tracker.leave() }
        try await Task.sleep(nanoseconds: 30_000_000)
        return reply(request)
    }
}

final class TriageEngineTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_790_337_600)  // Fri 25 Sep 2026 12:00 UTC

    func engine(_ providers: [LLMProvider], prefs: UserPrefs = UserPrefs(),
                dateFinder: (@Sendable (String) -> [Date])? = nil) -> TriageEngine {
        TriageEngine(router: LLMRouter(providers: providers, coolDown: 0), prefs: prefs,
                     dateFinder: dateFinder, now: { Self.now })
    }

    let lecturerMail = EmailFixtures.message(
        id: "lec", account: .exeter, from: "a.lovelace@exeter.ac.uk", name: "Dr Ada Lovelace",
        subject: "BEM2031 essay deadline",
        body: "Dear all,\n\nThis is urgent: please submit your essay by Friday 5pm.\n\nAda Lovelace\nSenior Lecturer")

    // MARK: Rules

    func testNewsletterIsIgnoredWithoutAI() async {
        let tracker = EmailLLMTracker()
        let e = engine([EmailSlowLLMProvider(tracker: tracker) { _ in "{}" }])
        let mail = EmailFixtures.message(id: "n1", from: "news@shop.example.com", name: "Shop News",
                                         subject: "Urgent: 50% off ends tonight!",
                                         body: "Huge savings.\n\nUnsubscribe | View in browser")
        let digest = await e.triage(mail)
        XCTAssertEqual(digest.category, .ignore)
        XCTAssertFalse(digest.notify)
        XCTAssertLessThan(digest.importance, 0.1)
        XCTAssertTrue(tracker.requests.isEmpty)
    }

    func testLecturerDeadlineRules() {
        let s = engine([]).ruleSignals(for: lecturerMail)
        XCTAssertTrue(s.isUni)
        XCTAssertTrue(s.isLecturer)
        XCTAssertTrue(s.isUrgent)
        XCTAssertTrue(s.hasDate)
        XCTAssertEqual(s.moduleCodes, ["BEM2031"])
        XCTAssertEqual(s.category, .urgent)
        XCTAssertGreaterThanOrEqual(s.importance, 0.9)
        XCTAssertTrue(s.needsAI)
    }

    func testQuestionFromFriendNeedsReplyButQuotedTextIgnored() {
        let e = engine([])
        let ask = EmailFixtures.message(id: "q", body: "Hey! Are you free for dinner on Saturday?")
        XCTAssertEqual(e.ruleSignals(for: ask).category, .needsReply)
        let quoted = EmailFixtures.message(id: "q2", body: "Thanks, sounds great.\n\nOn Tue, Sam wrote:\n> Can you come?")
        XCTAssertFalse(e.ruleSignals(for: quoted).needsReply)
        XCTAssertEqual(e.ruleSignals(for: EmailFixtures.message(id: "o")).category, .other)
    }

    func testELENotificationIsUniNotNeedsReply() {
        let mail = EmailFixtures.message(id: "ele", account: .exeter, from: "noreply@ele.exeter.ac.uk",
                                         name: "ELE (Exeter Learning Environment)",
                                         subject: "ECM1400: new announcement",
                                         body: "Lecture slides uploaded. Any questions? Unsubscribe from this forum.")
        let s = engine([]).ruleSignals(for: mail)
        XCTAssertTrue(s.isELE)
        XCTAssertFalse(s.isNewsletter)
        XCTAssertFalse(s.needsReply)
        XCTAssertEqual(s.category, .uni)
    }

    func testImportantSenderMatching() {
        let prefs = UserPrefs(importantSenders: ["lettings.co.uk", "boss@work.com", "@exeter.ac.uk", "Jane Doe"])
        let e = engine([], prefs: prefs)
        XCTAssertTrue(e.isImportantSender(EmailFixtures.message(id: "1", from: "office@lettings.co.uk", name: nil)))
        XCTAssertTrue(e.isImportantSender(EmailFixtures.message(id: "2", from: "Boss@Work.com", name: nil)))
        XCTAssertTrue(e.isImportantSender(EmailFixtures.message(id: "3", from: "x@exeter.ac.uk", name: nil)))
        XCTAssertTrue(e.isImportantSender(EmailFixtures.message(id: "4", from: "jd@mail.com", name: "Jane Doe")))
        XCTAssertFalse(e.isImportantSender(EmailFixtures.message(id: "5", from: "jane@mail.com", name: "Jane Smith")))
    }

    // MARK: AI

    func testAIResultIsCombined() async throws {
        let tracker = EmailLLMTracker()
        let json = """
        Here you go: {"category": "hasDate", "importance": 0.7, "summary": "Seminar moves to Amory 128 on 1 October.",
         "tasks": [{"title": "Read chapter 3", "deadline": "2026-09-30T17:00", "estimateMinutes": 45, "moduleCode": "bem2031"},
                   {"title": ""}],
         "events": [{"title": "BEM2031 seminar", "start": "2026-10-01T14:00", "end": "2026-10-01T15:00", "location": "Amory 128"},
                    {"title": "No date", "start": "sometime"}],
         "needsReply": false}
        """
        let e = engine([EmailSlowLLMProvider(tracker: tracker) { _ in json }])
        let mail = EmailFixtures.message(id: "sem", account: .exeter, from: "admin@exeter.ac.uk", name: "Business School",
                                         subject: "BEM2031 seminar room change", body: "The seminar on 1 October is now in Amory 128.")
        let d = await e.triage(mail)
        XCTAssertEqual(d.category, .hasDate)
        XCTAssertEqual(d.summary, "Seminar moves to Amory 128 on 1 October.")
        XCTAssertEqual(d.suggestedTasks.count, 1)
        XCTAssertEqual(d.suggestedTasks[0].deadline, Date(timeIntervalSince1970: 1_790_784_000))  // 17:00 BST
        XCTAssertEqual(d.suggestedTasks[0].estimateMinutes, 45)
        XCTAssertEqual(d.suggestedTasks[0].moduleCode, "BEM2031")
        XCTAssertEqual(d.suggestedEvents, [SuggestedEvent(title: "BEM2031 seminar",
                                                          start: Date(timeIntervalSince1970: 1_790_859_600),
                                                          end: Date(timeIntervalSince1970: 1_790_863_200),
                                                          location: "Amory 128")])
        XCTAssertNil(d.draftReply)
        XCTAssertGreaterThan(d.importance, 0.5)
        XCTAssertLessThan(d.importance, 0.8)
        XCTAssertFalse(d.notify)

        let request = try XCTUnwrap(tracker.requests.first)
        XCTAssertEqual(request.purpose, .bulk)
        XCTAssertTrue(request.json)
        XCTAssertTrue(request.messages.last!.text.contains("Today is Friday 25 September 2026, 13:00"))
        XCTAssertTrue(request.messages.last!.text.contains("Exeter sender"))
    }

    func testUrgentAINotifiesAndBodyIsTruncated() async throws {
        let tracker = EmailLLMTracker()
        let e = engine([EmailSlowLLMProvider(tracker: tracker) { _ in
            #"{"category": "urgent", "importance": 0.95, "summary": "Essay due Friday 5pm.", "needsReply": false}"#
        }])
        var mail = lecturerMail
        mail.body += String(repeating: "x", count: 10_000)
        let d = await e.triage(mail)
        XCTAssertEqual(d.category, .urgent)
        XCTAssertTrue(d.notify)
        XCTAssertLessThan(try XCTUnwrap(tracker.requests.first).messages.last!.text.count, 5000)
    }

    func testFailingAIFallsBackToRules() async {
        struct Down: Error {}
        let failing = MockLLMProvider(displayName: "down") { _ in throw Down() }
        let deadline = Date(timeIntervalSince1970: 1_790_956_800)
        let prefs = UserPrefs(importantSenders: ["lettings.co.uk"])
        let e = engine([failing], prefs: prefs, dateFinder: { _ in [deadline] })
        let mail = EmailFixtures.message(id: "rent", from: "office@lettings.co.uk", name: "Lettings Office",
                                         subject: "Tenancy renewal deadline",
                                         body: "Please return the signed tenancy by Friday 2 October.")
        let d = await e.triage(mail)
        XCTAssertEqual(d.category, .hasDate)
        XCTAssertTrue(d.notify, "important sender")
        XCTAssertEqual(d.summary, "Please return the signed tenancy by Friday 2 October.")
        XCTAssertEqual(d.suggestedTasks, [SuggestedTask(title: "Tenancy renewal deadline", deadline: deadline)])
    }

    func testImportantSenderNeverIgnoredByAI() async {
        let prefs = UserPrefs(importantSenders: ["boss@work.com"])
        let e = engine([MockLLMProvider { _ in #"{"category": "ignore", "importance": 0.1, "summary": "Rota."}"# }], prefs: prefs)
        let d = await e.triage(EmailFixtures.message(id: "rota", from: "boss@work.com", subject: "Rota", body: "New rota attached."))
        XCTAssertEqual(d.category, .other)
        XCTAssertTrue(d.notify)
    }

    func testBatchRunsAtMostThreeAtOnceAndKeepsOrder() async {
        let tracker = EmailLLMTracker()
        let e = engine([EmailSlowLLMProvider(tracker: tracker) { _ in #"{"category": "other", "importance": 0.4, "summary": "ok"}"# }])
        let mails = (0..<8).map { EmailFixtures.message(id: "m\($0)") }
        let digests = await e.triage(mails)
        XCTAssertEqual(digests.map(\.id), mails.map(\.id))
        XCTAssertEqual(tracker.requests.count, 8)
        XCTAssertLessThanOrEqual(tracker.maxInFlight, 3)
        XCTAssertGreaterThan(tracker.maxInFlight, 1)
    }

    // MARK: Replies

    func testDraftReplyUsesReasoningAndSignsOff() async throws {
        let tracker = EmailLLMTracker()
        let e = engine([EmailSlowLLMProvider(tracker: tracker) { _ in
            "Subject: Re: essay\n\nDear Dr Lovelace,\n\nThank you, I'll submit by Friday.\n"
        }])
        let draft = try await e.draftReply(for: lecturerMail, tone: .formal, signOff: "Charlie")
        XCTAssertEqual(draft, "Dear Dr Lovelace,\n\nThank you, I'll submit by Friday.\n\nKind regards,\nCharlie")
        let request = try XCTUnwrap(tracker.requests.first)
        XCTAssertEqual(request.purpose, .reasoning)
        XCTAssertTrue(request.messages[0].text.contains("UK English"))

        let signed = TriageEngine.cleanDraft("Hi Sam,\n\nSure!\n\nCheers,\nCharlie", firstName: "Charlie", closing: "Thanks,")
        XCTAssertEqual(signed, "Hi Sam,\n\nSure!\n\nCheers,\nCharlie")
    }
}
