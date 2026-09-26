import Foundation

/// Home's single "Ask or tell Orbit…" box: decides whether a line is a
/// question / request for the assistant (ask) or something to capture as a
/// to-do (tell). Conservative: anything that isn't clearly a question is a to-do,
/// and the box always offers the other choice as a button.
public enum AskOrTell: String, Sendable {
    case ask, tell

    private static let askStarts = [
        "what", "what's", "whats", "when", "where", "who", "why", "how", "which", "is ", "are ", "am i", "do i", "does ",
        "did ", "can ", "could ", "should ", "would ", "will ", "tell me", "explain", "quiz me", "summarise", "summarize",
        "help", "lighten", "reshuffle", "replan", "plan my", "show me", "give me", "find ", "ask ",
    ]

    public static func classify(_ text: String) -> AskOrTell {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return .tell }
        if t.hasSuffix("?") { return .ask }
        if t.hasPrefix("?") || t.hasPrefix("/ask") { return .ask }
        // Short words carry a trailing space ("is ") so "island trip" stays a to-do.
        return askStarts.contains { t.hasPrefix($0) } ? .ask : .tell
    }
}
