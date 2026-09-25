import XCTest
@testable import OrbitCore

final class EmailSyncCoordinatorTests: XCTestCase {
    func rulesOnly(_ prefs: UserPrefs = UserPrefs()) -> TriageEngine {
        TriageEngine(router: LLMRouter(providers: []), prefs: prefs, useAI: false)
    }

    let urgent = EmailFixtures.message(id: "u1", account: .exeter, from: "sid@exeter.ac.uk", name: "SID",
                                       subject: "Action required: overdue fees", body: "Your tuition fee is overdue.")

    func testSyncDedupesSuppressesFirstSyncNotificationsAndPersistsCursors() async throws {
        let gmail = EmailStubProvider(account: .gmail, batches: [
            [EmailFixtures.message(id: "g1"), EmailFixtures.message(id: "g1")],
            [EmailFixtures.message(id: "g1"), EmailFixtures.message(id: "g2", subject: "Urgent: call me")],
        ])
        let exeter = EmailStubProvider(account: .exeter, id: "exeter-graph", batches: [[], [urgent]])
        let coordinator = MailSyncCoordinator(providers: [gmail, exeter], triage: rulesOnly())

        let first = await coordinator.sync()
        XCTAssertEqual(first.messages.map(\.id), ["g1"])
        XCTAssertTrue(first.notifications.isEmpty, "first-sync backlog shouldn't notify")
        let state = await coordinator.state
        XCTAssertEqual(state.cursors, ["gmail": "c1", "exeter-graph": "c1"])

        let second = await coordinator.sync()
        XCTAssertEqual(Set(second.messages.map(\.id)), ["g2", "u1"])
        XCTAssertEqual(second.digests.first?.id, "u1", "most important first")
        XCTAssertEqual(Set(second.notifications.map(\.id)), ["g2", "u1"])
        let note = try XCTUnwrap(second.notifications.first { $0.id == "u1" })
        XCTAssertEqual(note.title, "🔴 SID")
        XCTAssertEqual(gmail.cursorsSeen, [nil, "c1"])

        // State round-trips and keeps de-duplicating in a new coordinator.
        let saved = try JSONEncoder().encode(await coordinator.state)
        let restored = MailSyncCoordinator(providers: [EmailStubProvider(account: .gmail, batches: [[EmailFixtures.message(id: "g2")]])],
                                           triage: rulesOnly(),
                                           state: try JSONDecoder().decode(MailSyncState.self, from: saved))
        let third = await restored.sync()
        XCTAssertTrue(third.messages.isEmpty)
    }

    func testFailingProviderDoesNotBlockOthers() async {
        let broken = EmailStubProvider(account: .exeter, batches: [], failure: MailError.accessDenied("blocked"))
        let gmail = EmailStubProvider(account: .gmail, batches: [[EmailFixtures.message(id: "g1")]])
        let coordinator = MailSyncCoordinator(providers: [broken, gmail], triage: rulesOnly(), notifyOnFirstSync: true)
        let report = await coordinator.sync()
        XCTAssertEqual(report.messages.map(\.id), ["g1"])
        XCTAssertNotNil(report.errors["exeter"])
        let cursors = await coordinator.state.cursors
        XCTAssertNil(cursors["exeter"])
    }

    func testSeenListIsBounded() async {
        let gmail = EmailStubProvider(account: .gmail, batches: [(0..<5).map { EmailFixtures.message(id: "m\($0)") }])
        let coordinator = MailSyncCoordinator(providers: [gmail], triage: rulesOnly(), state: MailSyncState(maxSeen: 3))
        _ = await coordinator.sync()
        let seen = await coordinator.state.seenKeys
        XCTAssertEqual(seen, ["gmail:m2", "gmail:m3", "gmail:m4"])
    }

    func testSaveDraftRoutesToAccount() async throws {
        let gmail = EmailStubProvider(account: .gmail, batches: [])
        let coordinator = MailSyncCoordinator(providers: [gmail], triage: rulesOnly())
        let id = try await coordinator.saveDraft(replyTo: EmailFixtures.message(id: "g9"), body: "Thanks!")
        XCTAssertEqual(id, "draft-g9")
        do {
            _ = try await coordinator.saveDraft(replyTo: urgent, body: "x")
            XCTFail("no exeter provider")
        } catch {}
    }
}
