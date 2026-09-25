import Foundation
import OrbitCore

/// Mac-only files in ~/Library/Application Support/Orbit. Full email bodies,
/// full note text, the search index, the handwriting profile and sync cursors
/// live here and never go to iCloud.
struct LocalStore {
    let root: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Orbit", isDirectory: true)
        for dir in [root, notesDirectory, openCodeWorkspace, logsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    var notesDirectory: URL { root.appendingPathComponent("Notes", isDirectory: true) }
    var openCodeWorkspace: URL { root.appendingPathComponent("opencode-workspace", isDirectory: true) }
    var logsDirectory: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    var noteIndexURL: URL { root.appendingPathComponent("note-index.json") }
    var handwritingDatasetDirectory: URL { root.appendingPathComponent("HandwritingDataset", isDirectory: true) }

    // MARK: JSON files

    func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, _ name: String) {
        do {
            try JSONEncoder().encode(value).write(to: root.appendingPathComponent(name), options: .atomic)
        } catch {
            print("Orbit: couldn't save \(name): \(error)")
        }
    }

    // MARK: Notes (full text)

    private func noteURL(_ id: String) -> URL {
        let name = SHA256Digest.hexString(Data(id.utf8)).prefix(40)
        return notesDirectory.appendingPathComponent("\(name).json")
    }

    func saveNote(_ note: LectureNote) {
        try? JSONEncoder().encode(note).write(to: noteURL(note.id), options: .atomic)
    }

    func note(id: String) -> LectureNote? {
        guard let data = try? Data(contentsOf: noteURL(id)) else { return nil }
        return try? JSONDecoder().decode(LectureNote.self, from: data)
    }

    func allNotes() -> [LectureNote] {
        let files = (try? FileManager.default.contentsOfDirectory(at: notesDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(LectureNote.self, from: Data(contentsOf: $0)) }
    }
}

/// Small sync state kept between launches.
struct BrainState: Codable {
    var orbitCalendarID: String?
    var oneNoteCursor: OneNoteSyncCursor?
    /// OneNote page id → last modified time already processed (so a long first
    /// sync can resume where it stopped).
    var oneNotePageStamps: [String: Date] = [:]
    var notesFolderCursor: Date?
    var iMessageCursor: Date?
    var streak: StreakState?
    var lastMorningBrief: String?
    var lastEveningReview: String?
    var lastWeeklyReview: String?
}

struct BrainError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Mac-only settings kept in UserDefaults (not synced).
enum MacPrefs {
    /// "graph", "appleMail" or "none".
    static let exeterMailSource = "exeterMailSource"
    /// "graph", "folder" or "none".
    static let noteSource = "noteSource"
    static let notesFolderPath = "notesFolderPath"
    static let iMessageEnabled = "iMessageEnabled"
    static let eleCalendarURL = "eleCalendarURL"
    static let timetableURL = "timetableURL"
    static let useExeterCalendar = "useExeterCalendar"
    /// "provider/model" for OpenCode; empty = OpenCode's default.
    static let openCodeModel = "openCodeModel"
    static let ollamaModel = "ollamaModel"
    static let ollamaVisionModel = "ollamaVisionModel"
    static let shareAIWithPhone = "shareAIWithPhone"
    static let loginItemConfigured = "loginItemConfigured"

    static var defaults: UserDefaults { .standard }

    static func string(_ key: String) -> String? {
        let s = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }
}
