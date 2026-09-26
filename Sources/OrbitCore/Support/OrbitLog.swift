import Foundation

/// A tiny app-wide diagnostics log. Appends timestamped lines to
/// `~/Library/Logs/Orbit/orbit.log` so a user can send it to us.
/// Never log tokens, codes or passwords.
public enum OrbitLog {
    private static let queue = DispatchQueue(label: "orbit.log")
    private static let maxBytes = 2_000_000

    /// The log file.
    public static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Orbit", isDirectory: true)
            .appendingPathComponent("orbit.log")
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Appends "timestamp [category] message".
    public static func log(_ category: String, _ message: String) {
        let now = Date()
        queue.async {
            let line = "\(formatter.string(from: now)) [\(category)] \(message)\n"
            let url = fileURL
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
               size.intValue > maxBytes {
                // Keep one old copy.
                let old = url.deletingPathExtension().appendingPathExtension("old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            let data = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// The last `maxBytes` of the log (waits for pending writes).
    public static func contents(maxBytes: Int = 400_000) -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return "" }
            return String(decoding: data.suffix(maxBytes), as: UTF8.self)
        }
    }
}
