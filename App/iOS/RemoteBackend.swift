import Foundation
import Observation
import SwiftData
import OrbitCore

/// The iPhone's backend. It asks the Mac to do things by writing requests into
/// the synced chat table; with a Mac address set (e.g. over Tailscale), chat and
/// "ask your notes" talk to the Mac's OpenCode/Ollama directly for instant replies.
@MainActor
@Observable
final class RemoteBackend: OrbitBackend {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var isThinking = false

    @ObservationIgnored private var directRouter: LLMRouter?
    @ObservationIgnored private var directKey: String?
    @ObservationIgnored private var assistant: Assistant?
    @ObservationIgnored private let dataSource: StoreDataSource

    init(container: ModelContainer) {
        self.container = container
        dataSource = StoreDataSource(context: container.mainContext)
        dataSource.replanHandler = { [weak self] in
            self?.enqueue(.replan)
            return SchedulePlan(warnings: ["Asked your Mac to replan; the new plan syncs in shortly."])
        }
        dataSource.lightenHandler = { [weak self] day, fraction in
            self?.enqueue(.lighten(day: day, fraction: fraction))
            return SchedulePlan(warnings: ["Asked your Mac to lighten that day; it syncs in shortly."])
        }
    }

    var isBrain: Bool { false }
    var planRouter: LLMRouter? { directRouterIfConfigured() }

    /// A router pointing at the Mac's AI, if a Mac address is set.
    private func directRouterIfConfigured() -> LLMRouter? {
        guard let settings = context.existingSettings,
              let host = settings.macAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { return nil }
        let key = host + "|" + (settings.macServerPassword ?? "")
        if key == directKey, let directRouter { return directRouter }
        let bareHost = host.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
            .split(separator: "/").first.map(String.init) ?? host
        guard let openCodeURL = URL(string: "http://\(bareHost):4096"),
              let ollamaURL = URL(string: "http://\(bareHost):11434") else { return nil }
        let router = LLMRouter(providers: [
            OpenCodeProvider(baseURL: openCodeURL, password: settings.macServerPassword, http: HTTPClient(timeout: 120)),
            OllamaProvider(baseURL: ollamaURL, http: HTTPClient(timeout: 180)),
        ], coolDown: 60)
        directRouter = router
        directKey = key
        assistant = nil
        return router
    }

    func enqueue(_ command: RemoteCommand) {
        let m = StoredChatMessage(id: UUID().uuidString)
        m.roleRaw = ChatRole.command.rawValue
        m.text = command.encoded
        m.status = .queued
        m.device = "ios"
        m.createdAt = Date()
        context.insert(m)
        context.saveQuietly()
    }

    // MARK: OrbitBackend

    func tasksChanged() {
        // The Mac notices task changes when they sync and replans by itself.
    }

    func requestReplan() async { enqueue(.replan) }

    func lighten(day: Date, fraction: Double) async { enqueue(.lighten(day: day, fraction: fraction)) }

    func planAccepted() async {
        // The Mac writes accepted plans to the calendar when they sync.
    }

    func sendChat(_ text: String) async {
        let user = StoredChatMessage(id: UUID().uuidString)
        user.roleRaw = ChatRole.user.rawValue
        user.text = text
        user.device = "ios"
        user.status = .queued
        user.createdAt = Date()
        context.insert(user)
        context.saveQuietly()

        guard let router = directRouterIfConfigured() else { return }
        user.status = .processing
        isThinking = true
        defer { isThinking = false }
        do {
            let assistant = makeAssistant(router)
            await assistant.setHistory(history(excluding: user.id))
            let turn = try await assistant.send(text)
            let reply = StoredChatMessage(id: UUID().uuidString)
            reply.roleRaw = ChatRole.assistant.rawValue
            reply.text = turn.text
            reply.device = "ios"
            reply.toolsUsed = turn.toolsUsed
            reply.provider = Self.providerName(await router.lastProvider()).map { "\($0) on your Mac" }
            reply.replyToID = user.id
            reply.createdAt = Date()
            context.insert(reply)
            user.status = .answered
        } catch {
            // Couldn't reach the Mac directly: leave it queued for the Mac to answer when it syncs.
            user.status = .queued
        }
        context.saveQuietly()
    }

    private func makeAssistant(_ router: LLMRouter) -> Assistant {
        if let assistant { return assistant }
        let prefs = context.prefs
        let made = Assistant(router: router, tools: StandardTools.make(dataSource, timeZone: prefs.timeZone) + dataSource.extraTools(),
                             userName: context.existingSettings?.firstName ?? "", timeZone: prefs.timeZone)
        assistant = made
        return made
    }

    private func history(excluding id: String) -> [AssistantTurn] {
        context.all(StoredChatMessage.self)
            .filter { $0.id != id && $0.role != .command && ($0.role == .assistant || $0.status == .answered) }
            .sorted { $0.createdAt < $1.createdAt }
            .suffix(12)
            .map { AssistantTurn(role: $0.role == .user ? .user : .assistant, text: $0.text, toolsUsed: $0.toolsUsed, date: $0.createdAt) }
    }

    private static func providerName(_ kind: LLMProviderKind?) -> String? {
        switch kind {
        case .opencode: "OpenCode"
        case .ollama: "Ollama"
        case .mock: "Test AI"
        case nil: nil
        }
    }

    func draftReply(digestID: String) async throws -> String? {
        if let digest = context.record(StoredEmailDigest.self, id: digestID) {
            digest.draftRequested = true
            context.saveQuietly()
        }
        enqueue(.draftReply(digestID: digestID))
        return nil
    }

    func saveDraft(digestID: String, body: String) async throws {
        if let digest = context.record(StoredEmailDigest.self, id: digestID) {
            digest.draftReply = body
            context.saveQuietly()
        }
        enqueue(.saveDraft(digestID: digestID, body: body))
    }

    func askNotes(_ question: String, moduleCode: String?) async throws -> NotesAnswer? {
        guard let router = directRouterIfConfigured() else {
            await sendChat("From my lecture notes\(moduleCode.map { " for \($0)" } ?? ""): \(question)")
            return nil
        }
        let notes = StoreDataSource.keywordSearch(context.all(StoredNote.self), query: question, moduleCode: moduleCode, limit: 6)
        guard !notes.isEmpty else {
            return NotesAnswer(text: "I couldn't find anything about that in your synced notes.", citations: [])
        }
        isThinking = true
        defer { isThinking = false }
        var sources = ""
        for (i, n) in notes.enumerated() {
            sources += "[\(i + 1)] \(n.title)\(n.moduleCode.map { " (\($0))" } ?? "")\n\(n.summary ?? "")\n\(n.keyPoints.prefix(1500))\n\n"
        }
        let system = """
        You answer a university student's questions using only their own lecture notes, given as numbered sources \
        (typed key points and summaries). Cite sources inline like [1]. If the notes don't answer it, say so. UK English, concise.
        """
        let text = try await router.complete(LLMRequest(messages: [.system(system), .user("Notes:\n\n\(sources)Question: \(question)")],
                                                        purpose: .privateData, temperature: 0.2))
        return NotesAnswer(text: text, citations: notes.enumerated().map { i, n in
            NotesAnswer.Citation(index: i + 1, noteID: n.id, title: n.title, moduleCode: n.moduleCode, week: n.week)
        })
    }

    func searchNotes(_ query: String, moduleCode: String?) async -> [NoteHit] {
        StoreDataSource.keywordSearch(context.all(StoredNote.self), query: query, moduleCode: moduleCode, limit: 20).map { n in
            NoteHit(id: n.id, noteID: n.id, title: n.title, moduleCode: n.moduleCode, week: n.week,
                    snippet: String((n.summary ?? n.keyPoints).prefix(220)), isTyped: n.hasTyped)
        }
    }

    func fullNote(id: String) -> LectureNote? { nil }

    func revisionTopics(moduleCode: String) -> [String] { [] }

    func syncNow() async {
        enqueue(.syncNow)
        await NotificationRelay.deliverNew(in: context)
    }
}
