import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Notability backup via the Google Drive API
//
// For when Google Drive for Desktop isn't installed: Orbit lists the "Notability" folder
// (drive.readonly, asked for incrementally only when this is turned on), and mirrors its
// PDFs into a local cache with the same folder structure. Only new or changed files are
// downloaded (by md5Checksum / modifiedTime); files deleted in Drive are deleted locally.
// The cache is then read exactly like a local Notability backup folder.

public extension OAuthConfig {
    /// Read-only Drive, requested on its own (incremental auth) when Drive notes sync is turned on.
    static let googleDriveReadonlyScope = "https://www.googleapis.com/auth/drive.readonly"
}

public struct DriveNoteFile: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// "History of Economics/Hoe week 1.pdf", relative to the Notability folder.
    public var path: String
    public var modified: Date?
    public var md5: String?
    public var size: Int?

    public init(id: String, name: String, path: String, modified: Date? = nil, md5: String? = nil, size: Int? = nil) {
        self.id = id; self.name = name; self.path = path; self.modified = modified; self.md5 = md5; self.size = size
    }

    /// Same file content as last time?
    func sameVersion(as other: DriveNoteFile) -> Bool {
        if let a = md5, let b = other.md5 { return a == b }
        return modified == other.modified && size == other.size
    }
}

/// What's in the local cache (Drive file id → file as downloaded).
public struct DriveMirrorManifest: Codable, Hashable, Sendable {
    public var files: [String: DriveNoteFile] = [:]
    public var rootFolderID: String?
    public var syncedAt: Date?
    public init() {}
}

public struct DriveMirrorPlan: Hashable, Sendable {
    public var download: [DriveNoteFile]
    /// Local relative paths to delete (removed or renamed in Drive).
    public var delete: [String]

    /// Compares the Drive listing with the manifest.
    public static func make(remote: [DriveNoteFile], manifest: DriveMirrorManifest) -> DriveMirrorPlan {
        var download: [DriveNoteFile] = []
        var delete: [String] = []
        let remoteIDs = Set(remote.map(\.id))
        for f in remote {
            if let old = manifest.files[f.id] {
                if old.path != f.path { delete.append(old.path); download.append(f) }
                else if !old.sameVersion(as: f) { download.append(f) }
            } else {
                download.append(f)
            }
        }
        for (id, old) in manifest.files where !remoteIDs.contains(id) { delete.append(old.path) }
        return DriveMirrorPlan(download: download.sorted { $0.path < $1.path }, delete: delete.sorted())
    }
}

public struct DriveNotesMirror: Sendable {
    public var http: HTTPClient
    public var tokens: AccessTokenProvider
    public var apiBase: URL
    /// Local cache, e.g. ~/Library/Application Support/Orbit/Drive/Notability.
    public var cache: URL

    public static let folderMime = "application/vnd.google-apps.folder"

    public init(http: HTTPClient = HTTPClient(timeout: 120), tokens: AccessTokenProvider, cache: URL,
                apiBase: URL = URL(string: "https://www.googleapis.com/drive/v3")!) {
        self.http = http; self.tokens = tokens; self.cache = cache; self.apiBase = apiBase
    }

    struct Listing: Decodable {
        struct F: Decodable {
            let id: String
            let name: String
            let mimeType: String
            let modifiedTime: Date?
            let md5Checksum: String?
            let size: String?
        }
        let files: [F]
        let nextPageToken: String?
    }

    public var manifestURL: URL { cache.appendingPathComponent(".orbit-drive-manifest.json") }

    public func loadManifest() -> DriveMirrorManifest {
        guard let data = try? Data(contentsOf: manifestURL) else { return DriveMirrorManifest() }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? d.decode(DriveMirrorManifest.self, from: data)) ?? DriveMirrorManifest()
    }

    func saveManifest(_ m: DriveMirrorManifest) throws {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try e.encode(m).write(to: manifestURL, options: .atomic)
    }

    func auth() async throws -> [String: String] { ["Authorization": "Bearer " + (try await tokens.accessToken())] }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    func list(query: String) async throws -> [Listing.F] {
        var out: [Listing.F] = []
        var page: String?
        repeat {
            var c = URLComponents(url: apiBase.appendingPathComponent("files"), resolvingAgainstBaseURL: false)!
            var items = [URLQueryItem(name: "q", value: query),
                         URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,modifiedTime,md5Checksum,size)"),
                         URLQueryItem(name: "pageSize", value: "1000"), URLQueryItem(name: "spaces", value: "drive")]
            if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
            c.queryItems = items
            let listing = try await http.get(Listing.self, c.url!, headers: try await auth())
            out += listing.files
            page = listing.nextPageToken
        } while page != nil
        return out
    }

    /// The Notability backup folder's id ("Notability" anywhere in My Drive; the one at the root first).
    public func findRootFolder(name: String = "Notability") async throws -> String? {
        let found = try await list(query: "mimeType='\(Self.folderMime)' and name='\(Self.escape(name))' and trashed=false")
        return found.first?.id
    }

    /// Every PDF below the folder, with paths relative to it.
    public func listPDFs(under rootID: String) async throws -> [DriveNoteFile] {
        var out: [DriveNoteFile] = []
        var queue: [(id: String, path: String)] = [(rootID, "")]
        var seen = Set<String>()
        while let (folder, prefix) = queue.popLast() {
            guard seen.insert(folder).inserted else { continue }
            for f in try await list(query: "'\(folder)' in parents and trashed=false") {
                let path = prefix.isEmpty ? f.name : prefix + "/" + f.name
                if f.mimeType == Self.folderMime {
                    queue.append((f.id, path))
                } else if f.mimeType == "application/pdf" || f.name.lowercased().hasSuffix(".pdf") {
                    out.append(DriveNoteFile(id: f.id, name: f.name, path: Self.safePath(path), modified: f.modifiedTime,
                                             md5: f.md5Checksum, size: f.size.flatMap(Int.init)))
                }
            }
        }
        return out
    }

    /// Drive names may contain "/" or ":"; keep each component a safe file name.
    public static func safePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).map { part in
            String(part).replacingOccurrences(of: #"[:\\]"#, with: "-", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && $0 != "." && $0 != ".." }.joined(separator: "/")
    }

    public struct Result: Sendable {
        public var downloaded: Int
        public var deleted: Int
        public var failed: Int
    }

    /// Lists Drive, downloads what changed and deletes what's gone. Safe to call often.
    public func sync(folderName: String = "Notability", maxDownloads: Int = 200) async throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        var manifest = loadManifest()
        let rootID: String
        if let id = manifest.rootFolderID { rootID = id } else {
            guard let id = try await findRootFolder(name: folderName) else { throw DriveMirrorError.folderNotFound(folderName) }
            rootID = id
        }
        manifest.rootFolderID = rootID
        let remote = try await listPDFs(under: rootID)
        let plan = DriveMirrorPlan.make(remote: remote, manifest: manifest)
        var deleted = 0, downloaded = 0, failed = 0
        let byPath = Dictionary(manifest.files.map { ($0.value.path, $0.key) }, uniquingKeysWith: { a, _ in a })
        for path in plan.delete {
            try? fm.removeItem(at: cache.appendingPathComponent(path))
            if let id = byPath[path], !remote.contains(where: { $0.id == id && $0.path == path }) { manifest.files[id] = nil }
            deleted += 1
        }
        for f in plan.download.prefix(maxDownloads) {
            do {
                var c = URLComponents(url: apiBase.appendingPathComponent("files/\(f.id)"), resolvingAgainstBaseURL: false)!
                c.queryItems = [URLQueryItem(name: "alt", value: "media")]
                let data = try await http.data("GET", c.url!, headers: try await auth())
                let target = cache.appendingPathComponent(f.path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                if let m = f.modified { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: target.path) }
                manifest.files[f.id] = f
                downloaded += 1
            } catch {
                failed += 1
            }
        }
        manifest.syncedAt = Date()
        try saveManifest(manifest)
        return Result(downloaded: downloaded, deleted: deleted, failed: failed)
    }
}

public enum DriveMirrorError: Error, CustomStringConvertible, Equatable {
    case folderNotFound(String)
    public var description: String {
        switch self {
        case .folderNotFound(let n): "No “\(n)” folder in Google Drive yet. In Notability: Settings → Auto-backup → Google Drive."
        }
    }
}

// MARK: - Finding the local Google Drive for Desktop copy

public enum NotabilityLocator {
    /// ~/Library/CloudStorage/GoogleDrive-<account>/My Drive/Notability (the account asked for first),
    /// then any other Notability backup the Mac has. OneDrive/OneNote folders are never picked by default.
    public static func preferredFolder(account: String? = nil,
                                       home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                       fileManager: FileManager = .default) -> URL? {
        let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let roots = ((try? fileManager.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("GoogleDrive") }
            .sorted { a, b in
                let am = account.map { a.lastPathComponent.localizedCaseInsensitiveContains($0) } ?? false
                let bm = account.map { b.lastPathComponent.localizedCaseInsensitiveContains($0) } ?? false
                return am != bm ? am : a.lastPathComponent < b.lastPathComponent
            }
        for root in roots {
            for drive in ["My Drive", "Mijn Drive", "Meine Ablage", ""] {
                let candidate = drive.isEmpty ? root.appendingPathComponent("Notability") : root.appendingPathComponent(drive).appendingPathComponent("Notability")
                var dir: ObjCBool = false
                if fileManager.fileExists(atPath: candidate.path, isDirectory: &dir), dir.boolValue { return candidate }
            }
        }
        return GoodNotesBackup.candidateFolders(home: home, fileManager: fileManager)
            .first { $0.app == .notability && $0.service == .googleDrive }?.url
    }

    /// True for a notes path Orbit set by default in older versions that the student didn't want
    /// (a OneDrive / OneNote export folder) when a Notability backup exists instead.
    public static func isLegacyOneNoteDefault(_ path: String) -> Bool {
        let l = path.lowercased()
        return (l.contains("onenote") || l.contains("onedrive")) && !l.contains("notability")
    }
}
