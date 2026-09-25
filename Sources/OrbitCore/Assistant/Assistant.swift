import Foundation

/// A tool the assistant can use (e.g. "add_task", "search_notes").
public struct AssistantTool: Sendable {
    public var name: String
    public var description: String
    /// Short description of each argument, e.g. ["title": "string, required"].
    public var arguments: [String: String]
    /// True for tools that change things (the assistant confirms first when asked to).
    public var mutates: Bool
    public var run: @Sendable ([String: JSONValue]) async throws -> String

    public init(name: String, description: String, arguments: [String: String] = [:], mutates: Bool = false,
                run: @escaping @Sendable ([String: JSONValue]) async throws -> String) {
        self.name = name; self.description = description; self.arguments = arguments
        self.mutates = mutates; self.run = run
    }
}

public struct AssistantTurn: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var role: Role
    public var text: String
    /// Tools used while producing this reply (shown as small chips in the chat).
    public var toolsUsed: [String]
    public var date: Date

    public init(role: Role, text: String, toolsUsed: [String] = [], date: Date = Date()) {
        self.role = role; self.text = text; self.toolsUsed = toolsUsed; self.date = date
    }
}

/// Orbit's chat assistant. Works with any model (OpenCode or a small local
/// one) using a plain JSON tool protocol rather than provider-specific
/// function calling: each step the model replies with either
/// `{"tool": "...", "args": {...}}` or `{"reply": "..."}`.
public actor Assistant {
    public let router: LLMRouter
    public private(set) var tools: [String: AssistantTool]
    public private(set) var history: [AssistantTurn] = []
    public var maxSteps: Int
    public var timeZone: TimeZone
    public var userName: String
    /// Extra context added to the system prompt (e.g. today's plan summary).
    public var contextProvider: (@Sendable () async -> String)?

    public init(router: LLMRouter, tools: [AssistantTool], userName: String = "",
                timeZone: TimeZone = TimeZone(identifier: "Europe/London")!, maxSteps: Int = 6,
                contextProvider: (@Sendable () async -> String)? = nil) {
        self.router = router
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.userName = userName; self.timeZone = timeZone; self.maxSteps = maxSteps
        self.contextProvider = contextProvider
    }

    public func setTools(_ t: [AssistantTool]) { tools = Dictionary(uniqueKeysWithValues: t.map { ($0.name, $0) }) }
    public func setHistory(_ h: [AssistantTurn]) { history = h }
    public func clear() { history = [] }

    struct Step: Decodable {
        let tool: String?
        let args: [String: JSONValue]?
        let reply: String?
    }

    /// Sends a message and returns the assistant's reply (after using any tools).
    @discardableResult
    public func send(_ text: String, now: Date = Date()) async throws -> AssistantTurn {
        history.append(AssistantTurn(role: .user, text: text, date: now))
        var messages: [LLMMessage] = [.system(await systemPrompt(now: now))]
        for turn in history.suffix(12) {
            messages.append(turn.role == .user ? .user(turn.text) : .assistant(turn.text))
        }

        var used: [String] = []
        for step in 0..<maxSteps {
            let final = step == maxSteps - 1
            if final { messages.append(.user("Now give your final reply as {\"reply\": \"...\"}.")) }
            let out: Step
            do {
                out = try await router.completeJSON(Step.self, LLMRequest(messages: messages, purpose: .chat, json: true, temperature: 0.3))
            } catch LLMError.invalidJSON(let raw) {
                // Small models sometimes just answer in prose; accept it.
                return finish(raw, used: used, now: now)
            }
            if let name = out.tool, !final {
                messages.append(.assistant(#"{"tool": "\#(name)", "args": \#(encode(out.args ?? [:]))}"#))
                guard let tool = tools[name] else {
                    messages.append(.user("Tool result for \(name): error, no such tool. Available: \(tools.keys.sorted().joined(separator: ", "))."))
                    continue
                }
                used.append(name)
                let result: String
                do { result = try await tool.run(out.args ?? [:]) } catch { result = "error: \(error)" }
                messages.append(.user("Tool result for \(name):\n\(result.prefix(6000))"))
                continue
            }
            return finish(out.reply ?? "", used: used, now: now)
        }
        return finish("Sorry, I got stuck on that one. Could you rephrase?", used: used, now: now)
    }

    private func finish(_ text: String, used: [String], now: Date) -> AssistantTurn {
        let turn = AssistantTurn(role: .assistant, text: text.trimmingCharacters(in: .whitespacesAndNewlines), toolsUsed: used, date: now)
        history.append(turn)
        return turn
    }

    private func encode(_ args: [String: JSONValue]) -> String {
        (try? String(decoding: JSONEncoder().encode(args), as: UTF8.self)) ?? "{}"
    }

    func systemPrompt(now: Date) async -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = timeZone
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        let toolList = tools.values.sorted { $0.name < $1.name }.map { t in
            let args = t.arguments.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            return "- \(t.name)(\(args)): \(t.description)"
        }.joined(separator: "\n")
        let extra = await contextProvider?() ?? ""
        return """
        You are Orbit, a personal assistant for \(userName.isEmpty ? "a" : userName + ", a") University of Exeter student \
        who wants to stay on top of everything and get a First. Be warm, direct and brief. UK English.
        Now: \(f.string(from: now)) (\(timeZone.identifier)).

        You can use these tools:
        \(toolList)

        Reply with ONLY a JSON object, one of:
        {"tool": "<name>", "args": {...}}   to use a tool (you'll get its result, then continue)
        {"reply": "<message to the user>"}  when you're done
        Rules: use tools to look things up rather than guessing. Dates in args are ISO 8601 local time \
        (e.g. 2026-10-14T15:00). Never claim you did something unless a tool result confirms it. \
        You can't send emails; you can only save drafts.
        \(extra.isEmpty ? "" : "\nContext:\n" + extra)
        """
    }
}
