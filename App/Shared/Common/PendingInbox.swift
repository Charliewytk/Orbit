import Foundation

/// Something captured by the share extension (or an App Intent) that the main
/// app ingests next time it runs. Stored as one JSON file per item in the App
/// Group so the extension never needs the database or the network.
struct PendingInboxItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        /// A to-do parsed from shared text.
        case task
        /// A plan the extension's rule stage found.
        case plan
        /// Raw text to run full plan extraction on later.
        case text
        /// A screenshot to OCR later.
        case image
    }

    var id: UUID = UUID()
    var kind: Kind
    var createdAt: Date = Date()
    var text: String?
    // Task fields
    var title: String?
    var estimateMinutes: Int?
    var deadline: Date?
    var moduleCode: String?
    // Plan fields
    var start: Date?
    var end: Date?
    var location: String?
    var people: [String] = []
    var quote: String?
    var confidence: Double?
    // Image
    var imageFileName: String?
}

enum PendingInbox {
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func save(_ item: PendingInboxItem, imageData: Data? = nil) throws {
        var item = item
        let dir = AppGroup.pendingInboxDirectory
        if let imageData {
            let name = "\(item.id.uuidString).img"
            try imageData.write(to: dir.appendingPathComponent(name), options: .atomic)
            item.imageFileName = name
        }
        try encoder.encode(item).write(to: dir.appendingPathComponent("\(item.id.uuidString).json"), options: .atomic)
    }

    static func loadAll() -> [PendingInboxItem] {
        let dir = AppGroup.pendingInboxDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(PendingInboxItem.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func imageData(for item: PendingInboxItem) -> Data? {
        guard let name = item.imageFileName else { return nil }
        return try? Data(contentsOf: AppGroup.pendingInboxDirectory.appendingPathComponent(name))
    }

    static func remove(_ item: PendingInboxItem) {
        let dir = AppGroup.pendingInboxDirectory
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(item.id.uuidString).json"))
        if let name = item.imageFileName {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
