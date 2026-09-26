import Foundation
import SwiftData
import OrbitCore

extension OrbitBrain {
    func makeAssistant() -> Assistant {
        if let assistant { return assistant }
        let prefs = self.prefs
        let tools = withFeatureTools(StandardTools.make(dataSource, timeZone: prefs.timeZone) + dataSource.extraTools() + academicTools())
        let made = Assistant(router: router, tools: tools, userName: firstName, timeZone: prefs.timeZone,
                             contextProvider: { [weak self] in await self?.assistantContext() ?? "" })
        assistant = made
        return made
    }

    /// A few lines of "what's going on" for the assistant's system prompt.
    func assistantContext() -> String {
        let now = Date()
        let cal = DayCalendar(timeZone: prefs.timeZone)
        var lines: [String] = []
        if let next = Agenda.nextUp(events: context.all(StoredEvent.self), blocks: context.all(StoredBlock.self),
                                    now: now, calendar: cal) {
            lines.append("Next up: \(next.title) at \(Fmt.dayTime(next.start, cal)).")
        }
        let due = Agenda.dueSoon(tasks: context.all(StoredTask.self), assessments: context.all(StoredAssessment.self),
                                 now: now, days: 7).prefix(4)
        if !due.isEmpty {
            lines.append("Due soon: " + due.map { "\($0.title) (\(Fmt.dayTime($0.due, cal)))" }.joined(separator: "; ") + ".")
        }
        let modules = context.all(StoredModule.self).map(\.id).sorted()
        if !modules.isEmpty { lines.append("Modules: \(modules.joined(separator: ", ")). Target grade \(Int(prefs.targetGrade))%.") }
        let academic = academicContext()
        if !academic.isEmpty { lines.append(academic) }
        return lines.joined(separator: "\n")
    }

    private func history(excluding id: String) -> [AssistantTurn] {
        context.all(StoredChatMessage.self)
            .filter { $0.id != id && $0.role != .command && ($0.role == .assistant || $0.status == .answered) }
            .sorted { $0.createdAt < $1.createdAt }
            .suffix(12)
            .map { AssistantTurn(role: $0.role == .user ? .user : .assistant, text: $0.text, toolsUsed: $0.toolsUsed, date: $0.createdAt) }
    }

    /// Runs one question through the assistant with the synced conversation as history.
    private func answer(_ text: String, excluding id: String) async -> (text: String, tools: [String], provider: String?, ok: Bool) {
        let assistant = makeAssistant()
        await assistant.setHistory(history(excluding: id))
        do {
            let turn = try await assistant.send(text)
            let provider = providerName(await router.lastProvider())
            lastProviderName = provider
            return (turn.text.isEmpty ? "Done." : turn.text, turn.toolsUsed, provider, true)
        } catch {
            return ("I couldn't reach the AI just now (\(error)). Is OpenCode or Ollama running?", [], nil, false)
        }
    }

    private func insertReply(_ reply: (text: String, tools: [String], provider: String?, ok: Bool), to id: String, device: String) {
        let m = StoredChatMessage(id: UUID().uuidString)
        m.roleRaw = ChatRole.assistant.rawValue
        m.text = reply.text
        m.statusRaw = ChatStatus.answered.rawValue
        m.device = device
        m.toolsUsed = reply.tools
        m.provider = reply.provider
        m.replyToID = id
        m.createdAt = Date()
        context.insert(m)
    }

    // MARK: OrbitBackend

    func sendChat(_ text: String) async {
        let user = StoredChatMessage(id: UUID().uuidString)
        user.roleRaw = ChatRole.user.rawValue
        user.text = text
        user.device = "mac"
        user.status = .processing
        user.createdAt = Date()
        context.insert(user)
        context.saveQuietly()
        isThinking = true
        let reply = await answer(text, excluding: user.id)
        isThinking = false
        insertReply(reply, to: user.id, device: "mac")
        user.status = reply.ok ? .answered : .failed
        context.saveQuietly()
    }

    // MARK: Queue from the iPhone

    /// Answers chat and runs commands the iPhone queued through iCloud.
    func processChatQueue() async {
        guard !processingQueue else { return }
        processingQueue = true
        defer { processingQueue = false }
        let queued = context.all(StoredChatMessage.self)
            .filter { $0.status == .queued }
            .sorted { $0.createdAt < $1.createdAt }
        guard !queued.isEmpty else { return }
        var failures = 0
        for m in queued {
            // Very old requests (the Mac was off for days) aren't worth acting on.
            if m.createdAt < Date().addingTimeInterval(-3 * 86400) {
                m.status = .failed
                continue
            }
            m.status = .processing
            context.saveQuietly()
            if m.role == .command {
                if let command = RemoteCommand.decode(m.text) { await run(command) }
                m.status = .answered
                context.saveQuietly()
                continue
            }
            // Already answered directly by the iPhone (instant chat)?
            if context.all(StoredChatMessage.self).contains(where: { $0.replyToID == m.id }) {
                m.status = .answered
                continue
            }
            isThinking = true
            let reply = await answer(m.text, excluding: m.id)
            isThinking = false
            insertReply(reply, to: m.id, device: "ios")
            m.status = reply.ok ? .answered : .failed
            if !reply.ok { failures += 1 }
            context.saveQuietly()
            notify(id: "chat-\(m.id)", title: "Orbit replied", body: String(reply.text.prefix(180)), category: "chat", onMac: false)
        }
        context.saveQuietly()
        record(.chat, error: failures > 0 ? "\(failures) message(s) couldn't be answered" : nil,
               detail: "Answered \(queued.count) request(s) from iPhone")
    }

    private func run(_ command: RemoteCommand) async {
        switch command {
        case .replan:
            await replanNow()
        case .lighten(let day, let fraction):
            await lightenNow(day: day, fraction: fraction)
        case .draftReply(let digestID):
            do { _ = try await draftReply(digestID: digestID) } catch {
                if let d = context.record(StoredEmailDigest.self, id: digestID) {
                    d.draftRequested = false
                    d.draftReply = "(Orbit couldn't draft this: \(error.localizedDescription))"
                }
            }
        case .saveDraft(let digestID, let body):
            do { try await saveDraft(digestID: digestID, body: body) } catch {
                record(.gmail, error: "Couldn't save a draft: \(error.localizedDescription)")
            }
        case .syncNow:
            await syncNow()
        }
    }
}
