import XCTest
@testable import OrbitCore

final class AssistantTests: XCTestCase {
    actor MemoryData: OrbitDataSource {
        var stored: [OrbitTask] = []
        var events: [CalendarEvent] = []
        func tasks() async -> [OrbitTask] { stored }
        func events(from: Date, to: Date) async -> [CalendarEvent] { events.filter { $0.start >= from && $0.start < to } }
        func blocks(from: Date, to: Date) async -> [ScheduledBlock] { [] }
        func assessments() async -> [Assessment] { [] }
        func emails(limit: Int, category: EmailCategory?) async -> [EmailDigest] { [] }
        func searchNotes(_ query: String, moduleCode: String?, limit: Int) async -> [String] { ["Lecture 3: \(query) is covered here"] }
        func addTask(_ task: OrbitTask) async throws { stored.append(task) }
        func completeTask(id: UUID) async throws {
            if let i = stored.firstIndex(where: { $0.id == id }) { stored[i].completedAt = Date() }
        }
        func addEvent(_ event: CalendarEvent) async throws { events.append(event) }
        func replan() async throws -> SchedulePlan { SchedulePlan(blocks: [], unscheduled: [], warnings: []) }
        func lighten(day: Date, fraction: Double) async throws -> SchedulePlan { try await replan() }
    }

    final class Script: @unchecked Sendable {
        var replies: [String]
        var seen: [LLMRequest] = []
        init(_ r: [String]) { replies = r }
    }

    func testUsesToolThenReplies() async throws {
        let data = MemoryData()
        let script = Script([
            #"{"tool": "add_task", "args": {"text": "essay plan BEM2031 2h"}}"#,
            #"{"reply": "Done, added your essay plan."}"#,
        ])
        let llm = MockLLMProvider { req in script.seen.append(req); return script.replies.removeFirst() }
        let assistant = Assistant(router: LLMRouter(providers: [llm]), tools: StandardTools.make(data), userName: "Charlie")
        let turn = try await assistant.send("add an essay plan for BEM2031, 2 hours")
        XCTAssertEqual(turn.text, "Done, added your essay plan.")
        XCTAssertEqual(turn.toolsUsed, ["add_task"])
        let tasks = await data.tasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.moduleCode, "BEM2031")
        XCTAssertEqual(tasks.first?.estimateMinutes, 120)
        XCTAssertTrue(script.seen[1].messages.last!.text.contains("Added"))
    }

    func testProseReplyAccepted() async throws {
        let llm = MockLLMProvider { _ in "Hi there!" }
        let assistant = Assistant(router: LLMRouter(providers: [llm]), tools: [])
        let turn = try await assistant.send("hello")
        XCTAssertEqual(turn.text, "Hi there!")
    }

    func testUnknownToolRecovers() async throws {
        let script = Script([#"{"tool": "nope", "args": {}}"#, #"{"reply": "ok"}"#])
        let llm = MockLLMProvider { _ in script.replies.removeFirst() }
        let assistant = Assistant(router: LLMRouter(providers: [llm]), tools: StandardTools.make(MemoryData()))
        let turn = try await assistant.send("x")
        XCTAssertEqual(turn.text, "ok")
    }
}
