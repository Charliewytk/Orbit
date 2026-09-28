import XCTest
@testable import OrbitCore

final class LLMRouterTests: XCTestCase {
    func testFallsBackWhenFirstProviderFails() async throws {
        struct Boom: Error {}
        let cloud = MockLLMProvider(displayName: "cloud", isLocal: false) { _ in throw Boom() }
        let local = MockLLMProvider(displayName: "local", isLocal: true) { _ in "hi" }
        let router = LLMRouter(providers: [cloud, local])
        let out = try await router.complete(system: "s", user: "u", purpose: .chat)
        XCTAssertEqual(out, "hi")
    }

    func testPrivateDataNeverLeavesMac() async throws {
        let cloud = MockLLMProvider(displayName: "cloud", isLocal: false) { _ in "cloud" }
        let local = MockLLMProvider(displayName: "local", isLocal: true) { _ in "local" }
        let router = LLMRouter(providers: [cloud, local])
        let names = await router.order(for: .privateData).map(\.displayName)
        XCTAssertEqual(names, ["local"])
    }

    func testChatPrefersCloudBulkPrefersLocal() async {
        let cloud = MockLLMProvider(displayName: "cloud", isLocal: false) { _ in "" }
        let local = MockLLMProvider(displayName: "local", isLocal: true) { _ in "" }
        let router = LLMRouter(providers: [local, cloud])
        let chat = await router.order(for: .chat).map(\.displayName)
        let bulk = await router.order(for: .bulk).map(\.displayName)
        XCTAssertEqual(chat, ["cloud", "local"])
        XCTAssertEqual(bulk, ["local", "cloud"])
    }

    func testJSONRetryFixesBadOutput() async throws {
        struct Out: Decodable { let n: Int }
        final class Counter: @unchecked Sendable { var n = 0 }
        let c = Counter()
        let p = MockLLMProvider { _ in c.n += 1; return c.n == 1 ? "sure! {\"n\": \"x\"}" : "```json\n{\"n\": 3}\n```" }
        let router = LLMRouter(providers: [p])
        let out = try await router.completeJSON(Out.self, LLMRequest(messages: [.user("go")]))
        XCTAssertEqual(out.n, 3)
    }

    func testJSONExtractor() {
        XCTAssertEqual(JSONExtractor.extract("Here: {\"a\": \"}\"} thanks"), "{\"a\": \"}\"}")
        XCTAssertEqual(JSONExtractor.extract("[1,[2]] x"), "[1,[2]]")
    }

    func testChatPrefersCleanAPIsOverOpenCode() async {
        let clean = MockLLMProvider(displayName: "clean", isLocal: false, kind: .cleanapis) { _ in "" }
        let oc = MockLLMProvider(displayName: "opencode", isLocal: false, kind: .opencode) { _ in "" }
        let local = MockLLMProvider(displayName: "ollama", isLocal: true, kind: .ollama) { _ in "" }
        // Insert OpenCode before CleanAPIs to prove kind-sort, not registration order.
        let router = LLMRouter(providers: [oc, local, clean])
        let chat = await router.order(for: .chat).map(\.displayName)
        let bulk = await router.order(for: .bulk).map(\.displayName)
        XCTAssertEqual(chat, ["clean", "opencode", "ollama"])
        // Bulk stays local-first; cloud keep registration order (cleanapis sort is chat/reasoning-only).
        XCTAssertEqual(bulk, ["ollama", "opencode", "clean"])
        let priv = await router.order(for: .privateData).map(\.displayName)
        XCTAssertEqual(priv, ["ollama"])
    }
}
