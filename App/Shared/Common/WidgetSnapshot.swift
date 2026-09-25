import Foundation

/// A small JSON file the app writes into the App Group after each sync.
/// Widgets read only this, which is far simpler and more reliable than
/// opening the CloudKit-backed SwiftData store from an extension.
struct WidgetSnapshot: Codable, Hashable {
    struct Item: Codable, Hashable, Identifiable {
        enum Kind: String, Codable { case block, event, task, assessment }
        var id: String
        var kind: Kind
        var title: String
        var start: Date?
        var end: Date?
        var due: Date?
        var moduleCode: String?
        var detail: String?
    }

    var generatedAt: Date
    /// Current and upcoming blocks/events, soonest first.
    var nextUp: [Item]
    /// Tasks and assessments due in the next seven days, soonest first.
    var dueThisWeek: [Item]

    static let empty = WidgetSnapshot(generatedAt: .distantPast, nextUp: [], dueThisWeek: [])

    static let placeholder = WidgetSnapshot(
        generatedAt: Date(),
        nextUp: [
            Item(id: "p1", kind: .block, title: "Essay plan", start: Date(), end: Date().addingTimeInterval(3600),
                 moduleCode: "BEM2031", detail: "Focus block"),
            Item(id: "p2", kind: .event, title: "Seminar", start: Date().addingTimeInterval(7200),
                 end: Date().addingTimeInterval(10800), moduleCode: "BEM2027", detail: "Streatham Court"),
        ],
        dueThisWeek: [
            Item(id: "p3", kind: .assessment, title: "Marketing report", due: Date().addingTimeInterval(3 * 86400),
                 moduleCode: "BEM2031", detail: "40%"),
            Item(id: "p4", kind: .task, title: "Reading: Kotler ch. 4", due: Date().addingTimeInterval(86400)),
        ])

    static func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: AppGroup.widgetSnapshotURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: AppGroup.widgetSnapshotURL, options: .atomic)
    }

    /// Items still relevant at `date` (for widget timelines computed ahead of time).
    func nextUp(at date: Date) -> [Item] {
        nextUp.filter { ($0.end ?? $0.start ?? .distantFuture) > date }
    }
}
