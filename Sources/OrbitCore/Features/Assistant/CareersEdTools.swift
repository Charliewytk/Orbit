import Foundation

/// What the careers and Ed tools need from the app (plain text for the model).
public protocol CareersEdToolsProvider: Sendable {
    func careersOpenText(watchedOnly: Bool) async -> String
    func careersUpcomingText(days: Int, watchedOnly: Bool) async -> String
    func careersSearchText(query: String) async -> String
    func edActivityText(since: Date?, course: String?) async -> String
}

public enum CareersEdTools {
    public static let names = ["careers_open", "careers_upcoming", "careers_search", "ed_activity"]

    public static func make(_ p: CareersEdToolsProvider, now: @escaping @Sendable () -> Date = { Date() }) -> [AssistantTool] {
        [
            AssistantTool(
                name: "careers_open",
                description: "Finance programmes (spring weeks, internships, events) open for applications right now, from Trackr, with closing dates and tests.",
                arguments: ["watched_only": "true = only the student's watchlist (default false)"]
            ) { args in
                await p.careersOpenText(watchedOnly: args["watched_only"]?.bool ?? false)
            },
            AssistantTool(
                name: "careers_upcoming",
                description: "Programmes opening soon: announced opening dates and predictions from last year's opening date.",
                arguments: ["days": "look-ahead in days (default 30)", "watched_only": "true = only the watchlist (default true)"]
            ) { args in
                await p.careersUpcomingText(days: max(1, min(365, args["days"]?.int ?? 30)),
                                            watchedOnly: args["watched_only"]?.bool ?? true)
            },
            AssistantTool(
                name: "careers_search",
                description: "Search tracked programmes by company, programme, sector, test (e.g. 'Nomura', 'Pymetrics', 'buy-side spring').",
                arguments: ["query": "words to match"]
            ) { args in
                await p.careersSearchText(query: args["query"]?.string ?? "")
            },
            AssistantTool(
                name: "ed_activity",
                description: "What's new on Ed Discussion (edstem.org) for the student's modules: staff posts, pinned threads, announcements, replies to their threads.",
                arguments: ["since": "ISO date or number of days back (default 7)", "course": "module code, e.g. BEE1022 (optional)"]
            ) { args in
                let since = sinceDate(args["since"], now: now())
                return await p.edActivityText(since: since, course: args["course"]?.string?.uppercased())
            },
        ]
    }

    /// "2026-09-20", "3" (days back) or nothing (a week).
    static func sinceDate(_ value: JSONValue?, now: Date) -> Date {
        if let days = value?.int { return now.addingTimeInterval(-Double(max(0, days)) * 86400) }
        if let s = value?.string {
            if let d = ISO8601.parse(s) { return d }
            if let days = Int(s.trimmingCharacters(in: .whitespaces)) { return now.addingTimeInterval(-Double(days) * 86400) }
        }
        return now.addingTimeInterval(-7 * 86400)
    }
}
