import Foundation
import OrbitCore

/// Secrets for the money features (Trading 212 key, Monzo client and tokens).
/// Kept in the Keychain; if the Keychain refuses (ad-hoc signed builds sometimes
/// do), in an owner-only file under Application Support. Never synced, never
/// logged, never written to the repo.
enum SecretVault {
    enum Key: String {
        case trading212 = "money.trading212"
        case monzoClient = "money.monzo.client"
        case monzoToken = "money.monzo.token"
    }

    private static var fileDir: URL {
        FeatureFiles(subdirectory: "Secrets").root
    }

    private static func fileURL(_ key: Key) -> URL { fileDir.appendingPathComponent(key.rawValue + ".json") }

    static func load<T: Codable>(_ type: T.Type, _ key: Key) -> T? {
        if let v = KeychainBlob.load(T.self, key: key.rawValue) { return v }
        guard let data = try? Data(contentsOf: fileURL(key)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Codable>(_ value: T, _ key: Key) {
        do {
            try KeychainBlob.save(value, key: key.rawValue)
            try? FileManager.default.removeItem(at: fileURL(key))
        } catch {
            OrbitLog.log("money", "Keychain unavailable for \(key.rawValue); using a private file instead")
            do {
                let url = fileURL(key)
                try JSONEncoder().encode(value).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                OrbitLog.log("money", "Couldn't store \(key.rawValue): \(error.localizedDescription)")
            }
        }
    }

    static func delete(_ key: Key) {
        KeychainBlob.delete(key: key.rawValue)
        try? FileManager.default.removeItem(at: fileURL(key))
    }
}
