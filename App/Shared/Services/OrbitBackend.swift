import Foundation
import OrbitCore

/// What differs between the two apps. The Mac's `OrbitBrain` does the work
/// itself; the iPhone's `RemoteBackend` queues requests for the Mac (or, with
/// a Mac address set, talks to the Mac's AI directly).
@MainActor
protocol OrbitBackend: AnyObject {
    /// True on the Mac.
    var isBrain: Bool { get }
    /// True while the AI is working on something the user is waiting for.
    var isThinking: Bool { get }
    /// AI used for plan extraction on this device. Nil means rules only.
    var planRouter: LLMRouter? { get }

    /// Something about tasks changed (added, edited, ticked off): replan soon.
    func tasksChanged()
    /// "Reshuffle": replan now.
    func requestReplan() async
    func lighten(day: Date, fraction: Double) async
    /// A plan or event was accepted: put it on the calendar.
    func planAccepted() async

    func sendChat(_ text: String) async
    /// The reply text, or nil if the request was sent to the Mac.
    func draftReply(digestID: String) async throws -> String?
    func saveDraft(digestID: String, body: String) async throws

    /// Nil when the question was handed to the Mac through chat.
    func askNotes(_ question: String, moduleCode: String?) async throws -> NotesAnswer?
    func searchNotes(_ query: String, moduleCode: String?) async -> [NoteHit]
    /// Full note text (handwriting included). Mac only.
    func fullNote(id: String) -> LectureNote?
    /// Topics to build a revision plan from (ELE sections + note titles).
    func revisionTopics(moduleCode: String) -> [String]

    func syncNow() async
}

struct NotesAnswer: Hashable {
    struct Citation: Hashable, Identifiable {
        var id: Int { index }
        var index: Int
        var noteID: String
        var title: String
        var moduleCode: String?
        var week: Int?
    }
    var text: String
    var citations: [Citation]
}

struct NoteHit: Hashable, Identifiable {
    var id: String
    var noteID: String
    var title: String
    var moduleCode: String?
    var week: Int?
    var snippet: String
    var isTyped: Bool
}

/// Requests the iPhone sends the Mac through the synced chat table
/// (as `StoredChatMessage` rows with role "command").
enum RemoteCommand: Codable, Hashable {
    case replan
    case lighten(day: Date, fraction: Double)
    case draftReply(digestID: String)
    case saveDraft(digestID: String, body: String)
    case syncNow

    var encoded: String {
        (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? "{}"
    }

    static func decode(_ text: String) -> RemoteCommand? {
        try? JSONDecoder().decode(RemoteCommand.self, from: Data(text.utf8))
    }
}
