import Foundation

/// The places the Mac syncs from. Each one's last success and last error are
/// written to the synced settings row so the iPhone's Diagnostics page shows them too.
enum SyncSource: String, CaseIterable, Codable, Identifiable {
    case calendar, gmail, exeterMail, ele, notes, imessage, ai, briefs, chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .gmail: "Gmail"
        case .exeterMail: "Exeter email"
        case .ele: "ELE"
        case .notes: "OneNote notes"
        case .imessage: "iMessage"
        case .ai: "AI"
        case .briefs: "Briefs & reviews"
        case .chat: "Chat queue"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .gmail: "envelope"
        case .exeterMail: "building.columns"
        case .ele: "graduationcap"
        case .notes: "pencil.and.scribble"
        case .imessage: "message"
        case .ai: "sparkles"
        case .briefs: "sun.max"
        case .chat: "bubble.left.and.bubble.right"
        }
    }
}

struct SyncStatusEntry: Codable, Hashable {
    var lastAttempt: Date?
    var lastSuccess: Date?
    var lastError: String?
    /// Short result, e.g. "48 events".
    var detail: String?

    var isHealthy: Bool { lastError == nil && lastSuccess != nil }
}

/// App configuration from Info.plist (filled from Config/Secrets.xcconfig).
enum AppConfig {
    private static func string(_ key: String) -> String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unfilled build settings arrive as "" or a literal "$(NAME)".
        let placeholder = t.isEmpty || t.hasPrefix("$(") || t.contains("YOUR_") || t.contains("not-configured")
            || t.hasPrefix("00000000-0000")
        return placeholder ? nil : t
    }

    static var googleClientID: String? { string("OrbitGoogleClientID") }
    static var googleReversedClientID: String? {
        string("OrbitGoogleReversedClientID") ?? googleClientID.map {
            // "123-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.123-abc"
            $0.split(separator: ".").reversed().joined(separator: ".")
        }
    }
    static var googleRedirectURI: String? { googleReversedClientID.map { "\($0):/oauth2redirect" } }

    static var microsoftClientID: String? { string("OrbitMicrosoftClientID") }
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.charliewytk.orbit" }
    static var microsoftRedirectURI: String { "msauth.\(bundleID)://auth" }

    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
    }
}
