import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Uploads Orbit's PDFs to Google Drive ("Orbit/Practice/<Module>") so Notability on the
/// iPad can import them. Uses the `drive.file` scope: Orbit only ever sees files it made.
public struct GoogleDriveUploader: Sendable {
    public var http: HTTPClient
    public var tokens: AccessTokenProvider
    public var apiBase: URL
    public var uploadBase: URL

    public init(http: HTTPClient = HTTPClient(timeout: 120), tokens: AccessTokenProvider,
                apiBase: URL = URL(string: "https://www.googleapis.com/drive/v3")!,
                uploadBase: URL = URL(string: "https://www.googleapis.com/upload/drive/v3")!) {
        self.http = http; self.tokens = tokens; self.apiBase = apiBase; self.uploadBase = uploadBase
    }

    public static let folderMime = "application/vnd.google-apps.folder"

    struct FileList: Decodable { struct F: Decodable { let id: String }; let files: [F] }
    public struct UploadedFile: Decodable, Sendable { public let id: String; public let webViewLink: String? }

    /// True when the error means the token lacks the Drive scope (reconnect Google to grant it).
    public static func isScopeError(_ error: Error) -> Bool {
        guard let e = error as? HTTPError else { return false }
        return e.status == 403 && (e.body.contains("insufficient") || e.body.contains("scope") || e.body.contains("PERMISSION"))
            || e.status == 401
    }

    /// The Drive query for a folder by name under a parent.
    public static func folderQuery(name: String, parent: String?) -> String {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return "mimeType='\(folderMime)' and name='\(escaped)' and trashed=false and '\(parent ?? "root")' in parents"
    }

    func auth() async throws -> [String: String] { ["Authorization": "Bearer " + (try await tokens.accessToken())] }

    /// Finds or creates each folder of a path ("Orbit/Practice/BEE1025") and returns the last id.
    public func ensureFolder(path: [String]) async throws -> String {
        var parent: String? = nil
        for name in path {
            var c = URLComponents(url: apiBase.appendingPathComponent("files"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "q", value: Self.folderQuery(name: name, parent: parent)),
                            URLQueryItem(name: "fields", value: "files(id)"), URLQueryItem(name: "spaces", value: "drive")]
            let found = try await http.get(FileList.self, c.url!, headers: try await auth())
            if let id = found.files.first?.id { parent = id; continue }
            var meta: [String: Any] = ["name": name, "mimeType": Self.folderMime]
            if let parent { meta["parents"] = [parent] }
            let body = try JSONSerialization.data(withJSONObject: meta)
            let created = try await http.json(UploadedFile.self, "POST", apiBase.appendingPathComponent("files"),
                                              headers: try await auth(), body: body)
            parent = created.id
        }
        return parent ?? "root"
    }

    /// multipart/related body: JSON metadata + file bytes.
    public static func multipartBody(name: String, parent: String, mime: String, data: Data, boundary: String) -> Data {
        let meta = (try? JSONSerialization.data(withJSONObject: ["name": name, "parents": [parent]])) ?? Data()
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(meta)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    @discardableResult
    public func upload(data: Data, name: String, mime: String = "application/pdf", folderPath: [String]) async throws -> UploadedFile {
        let parent = try await ensureFolder(path: folderPath)
        let boundary = "orbit-" + UUID().uuidString
        var c = URLComponents(url: uploadBase.appendingPathComponent("files"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "uploadType", value: "multipart"), URLQueryItem(name: "fields", value: "id,webViewLink")]
        var headers = try await auth()
        headers["Content-Type"] = "multipart/related; boundary=\(boundary)"
        return try await http.json(UploadedFile.self, "POST", c.url!, headers: headers,
                                   body: Self.multipartBody(name: name, parent: parent, mime: mime, data: data, boundary: boundary))
    }

    public static func practiceFolder(moduleCode: String) -> [String] { ["Orbit", "Practice", moduleCode] }
}
