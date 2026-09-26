import XCTest
@testable import OrbitCore

final class ConversationalPlannerTests: XCTestCase {
    typealias F = SchedFixtures

    static let input = "first of all i dont want to do any work today. second of all i have to type up a weeks worth of stuff from last week due for monday. third of all i did not go to my lecture at 835 on friday so i need to really go over what i missed"

    /// Saturday 17 October 2026, 10:00.
    var now: Date { F.date(2026, 10, 17, 10) }

    func lecture(_ code: String, _ d: Int, _ h: Int, _ m: Int = 0, status: TrackedLecture.Status, kind: TrackedLecture.SessionKind = .lecture,
                 title: String = "") -> TrackedLecture {
        let start = F.date(2026, 10, d, h, m)
        return TrackedLecture(id: "\(code)@\(d)-\(h)", eventID: code, moduleCode: code, kind: kind, title: title, start: start,
                              end: start.addingTimeInterval(3000), location: nil, term: 1, week: 4,
                              slideDocumentIDs: [], slideTitles: title.isEmpty ? [] : ["\(title) slides"], noteIDs: [], status: status)
    }

    var context: PlannerContext {
        let lectures = [
            lecture("BEM2031", 12, 10, status: .notesTaken, title: "Market structure"),
            lecture("ECM1400", 13, 14, status: .noNotes, title: "Recursion"),
            lecture("BEM2029", 14, 11, status: .notesIncomplete, title: "Hypothesis tests"),
            lecture("BEM2031", 15, 9, status: .noNotes, kind: .tutorial),
            lecture("ECM1400", 16, 8, 35, status: .noNotes, title: "Complexity"),
            lecture("BEM2031", 5, 10, status: .noNotes, title: "Old week"),      // the week before: not included
        ]
        let block = PlannerContext.FlexibleBlock(id: "b1", title: "Reading", start: F.date(2026, 10, 17, 14), end: F.date(2026, 10, 17, 15))
        return PlannerContext(now: now, lectures: lectures,
                              moduleNames: ["ECM1400": "Programming", "BEM2029": "Statistics", "BEM2031": "Microeconomics"],
                              flexibleBlocks: [block],
                              lectureLinks: ["ECM1400@16-8": [URL(string: "https://ele.exeter.ac.uk/rec/1")!]])
    }

    func assertExamplePlan(_ p: PlanProposal, file: StaticString = #filePath, line: UInt = #line) throws {
        let cal = F.cal
        // (1) today kept free, its flexible block moved.
        XCTAssertEqual(p.restDays, [cal.startOfDay(now)], file: file, line: line)
        XCTAssertEqual(p.blocksToMove.map(\.id), ["b1"], file: file, line: line)
        // (3) one catch-up for Friday 08:35 Programming, one type-up per untyped lecture last week.
        let catchUp = try XCTUnwrap(p.items.first { $0.kind == .catchUp }, file: file, line: line)
        XCTAssertEqual(catchUp.lectureID, "ECM1400@16-8", file: file, line: line)
        XCTAssertEqual(catchUp.title, "Watch recording + go through slides: Programming (ECM1400)", file: file, line: line)
        XCTAssertEqual(catchUp.links.first?.absoluteString, "https://ele.exeter.ac.uk/rec/1", file: file, line: line)
        let typeUps = p.items.filter { $0.kind == .typeUp }
        XCTAssertEqual(Set(typeUps.compactMap(\.lectureID)), ["ECM1400@13-14", "BEM2029@14-11"], file: file, line: line)
        XCTAssertTrue(typeUps.allSatisfy { $0.deadline == F.date(2026, 10, 19, 9) }, file: file, line: line)
        // Not one lump on Monday: nothing today, everything scheduled before Monday 09:00.
        for item in p.items {
            let start = try XCTUnwrap(item.start, "\(item.title) unscheduled", file: file, line: line)
            XCTAssertFalse(cal.isSameDay(start, now), "\(item.title) is on the rest day", file: file, line: line)
            if let d = item.deadline { XCTAssertLessThanOrEqual(try XCTUnwrap(item.end), d, file: file, line: line) }
        }
        XCTAssertTrue(p.summary.hasPrefix("Here's what I'll do:"), file: file, line: line)
        XCTAssertTrue(p.summary.contains("Keep today free (moving 1 block off it)"), p.summary, file: file, line: line)
    }

    func testRuleFallbackUnderstandsTheExample() async throws {
        let p = await ConversationalPlanner().propose(Self.input, context: context)
        XCTAssertFalse(p.usedAI)
        XCTAssertEqual(p.intents.map(\.kind), [.restDay, .typeUp, .catchUp])
        XCTAssertEqual(p.intents[2].date, F.date(2026, 10, 16, 8, 35))
        try assertExamplePlan(p)
    }

    func testAIAgentUsesToolsThenReturnsStructuredIntents() async throws {
        final class Log: @unchecked Sendable { var prompts: [String] = [] }
        let log = Log()
        let fake = MockLLMProvider { request in
            log.prompts.append(request.messages.last?.text ?? "")
            if log.prompts.count == 1 { return #"{"tool":"lectures","args":{"from":"2026-10-12T00:00","to":"2026-10-17T00:00"}}"# }
            return """
            {"intents":[
              {"kind":"rest_day","date":"2026-10-17","quote":"i dont want to do any work today"},
              {"kind":"type_up","date":"2026-10-12T00:00","until":"2026-10-17T00:00","deadline":"2026-10-19T09:00"},
              {"kind":"catch_up","date":"2026-10-16T08:35","module":"ECM1400"}
            ]}
            """
        }
        let p = await ConversationalPlanner(router: LLMRouter(providers: [fake])).propose(Self.input, context: context)
        XCTAssertTrue(p.usedAI)
        XCTAssertTrue(log.prompts[1].contains("ECM1400 Programming lecture \"Complexity\" notes=noNotes"), log.prompts[1])
        try assertExamplePlan(p)
    }

    func testBrokenAIFallsBackToRules() async throws {
        struct Down: Error {}
        let p = await ConversationalPlanner(router: LLMRouter(providers: [MockLLMProvider { _ in throw Down() }]))
            .propose(Self.input, context: context)
        XCTAssertFalse(p.usedAI)
        try assertExamplePlan(p)
    }

    func testConversationalReviseMovesAndRemoves() async throws {
        let planner = ConversationalPlanner()
        let p = await planner.propose(Self.input, context: context)
        let (moved, edits) = await planner.revise(p, reply: "move the stats one to monday", context: context)
        XCTAssertEqual(edits.count, 1)
        let stats = try XCTUnwrap(moved.items.first { $0.lectureID == "BEM2029@14-11" })
        XCTAssertTrue(F.cal.isSameDay(try XCTUnwrap(stats.start), F.date(2026, 10, 19)))
        XCTAssertLessThanOrEqual(try XCTUnwrap(stats.end), F.date(2026, 10, 19, 9), "still fits before the 09:00 deadline")

        let (removed, _) = await planner.revise(moved, reply: "drop the programming type up", context: context)
        XCTAssertFalse(try XCTUnwrap(removed.items.first { $0.lectureID == "ECM1400@13-14" }).included)
        XCTAssertFalse(removed.summary.contains("Type up lecture: Programming"))
    }

    func testCommittedItemsBecomeTasks() async throws {
        let p = await ConversationalPlanner().propose(Self.input, context: context)
        let tasks = p.items.filter(\.included).map { $0.task(createdAt: now) }
        XCTAssertEqual(tasks.count, 3)
        XCTAssertTrue(tasks.allSatisfy { $0.origin == .recommended && $0.earliestStart != nil })
    }

    func testQuickAddRoutesConversationalTextToPlanner() {
        XCTAssertTrue(ConversationalPlanner.looksConversational(Self.input))
        XCTAssertTrue(ConversationalPlanner.looksConversational("I missed my lecture on friday at 9"))
        XCTAssertFalse(ConversationalPlanner.looksConversational("essay plan BEM2031 2h by Fri"))
        XCTAssertFalse(ConversationalPlanner.looksConversational("call mum tomorrow 6pm"))
    }
}
