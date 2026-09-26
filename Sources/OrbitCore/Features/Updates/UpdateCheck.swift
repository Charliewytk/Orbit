import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A GitHub release as returned by the Releases API.
public struct GitHubRelease: Codable, Hashable, Sendable {
    public struct Asset: Codable, Hashable, Sendable {
        public var name: String
        public var browser_download_url: String
        public var updated_at: String?
        public var size: Int?
    }

    public var tag_name: String
    public var name: String?
    public var body: String?
    public var published_at: String?
    public var assets: [Asset]

    /// The full commit SHA from a "sha: <40 hex>" line in the release notes.
    public var commitSHA: String? {
        guard let body else { return nil }
        let pattern = "(?im)^\\s*[*_`]*sha[*_`]*\\s*:[*_`]*\\s*`?([0-9a-f]{7,40})"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let r = Range(m.range(at: 1), in: body) else { return nil }
        return String(body[r]).lowercased()
    }

    public func asset(named name: String) -> Asset? { assets.first { $0.name == name } }
}

public enum UpdateStatus: Hashable, Sendable {
    case upToDate
    /// Newer build: its commit, the zip to download, and when it was published.
    case available(sha: String?, zipURL: URL, publishedAt: Date?)
    /// Can't tell (e.g. a local Xcode build without an embedded SHA).
    case unknown(String)

    public var isAvailable: Bool { if case .available = self { return true }; return false }
}

public enum UpdateDecision {
    public static let zipName = "Orbit-mac.zip"

    /// Same commit when one SHA is a prefix of the other (short vs full), case-insensitive.
    public static func sameCommit(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().trimmingCharacters(in: .whitespaces), y = b.lowercased().trimmingCharacters(in: .whitespaces)
        guard x.count >= 7, y.count >= 7 else { return false }
        return x.hasPrefix(y) || y.hasPrefix(x)
    }

    /// Compares the release with the running build.
    /// - currentSHA: `OrbitBuildSHA` from Info.plist (empty for local builds).
    /// - buildDate: when the running app was built (fallback when the release has no SHA).
    public static func evaluate(_ release: GitHubRelease, currentSHA: String?, buildDate: Date?) -> UpdateStatus {
        guard let asset = release.asset(named: zipName), let url = URL(string: asset.browser_download_url) else {
            return .unknown("The release has no \(zipName).")
        }
        let published = (asset.updated_at ?? release.published_at).flatMap(ISO8601.parse)
        let current = (currentSHA ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let validCurrent = current.count >= 7 && current.allSatisfy(\.isHexDigit)
        if let remote = release.commitSHA {
            guard validCurrent else { return .unknown("This build has no commit id (built locally), so updates aren't compared.") }
            return sameCommit(remote, current) ? .upToDate : .available(sha: remote, zipURL: url, publishedAt: published)
        }
        // No SHA in the notes: compare the asset's upload time with our build time (10 min slack).
        guard let published, let buildDate else { return .unknown("Couldn't compare versions.") }
        return published > buildDate.addingTimeInterval(600) ? .available(sha: nil, zipURL: url, publishedAt: published) : .upToDate
    }

    public static func releaseURL(owner: String = "Charliewytk", repo: String = "Orbit", tag: String = "mac-latest") -> URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/tags/\(tag)")!
    }

    public static func fetch(http: HTTPClient = HTTPClient(timeout: 20), url: URL = releaseURL()) async throws -> GitHubRelease {
        let data = try await http.data("GET", url, headers: ["Accept": "application/vnd.github+json", "User-Agent": "Orbit-Updater"])
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}

/// The helper script that swaps the app while it isn't running.
public enum UpdateInstallerScript {
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Waits for `pid` to exit (up to 60 s), replaces `destination` with `newApp`
    /// (keeping a backup until the copy succeeds), clears quarantine and relaunches.
    public static func make(pid: Int32, newApp: String, destination: String, logFile: String) -> String {
        let dst = quote(destination), src = quote(newApp), log = quote(logFile), backup = quote(destination + ".orbit-backup")
        return """
        #!/bin/bash
        # Orbit updater: runs after Orbit quits.
        exec >> \(log) 2>&1
        echo "$(date '+%Y-%m-%d %H:%M:%S') [update] helper started (waiting for pid \(pid))"
        for i in $(seq 1 120); do
          if ! kill -0 \(pid) 2>/dev/null; then break; fi
          sleep 0.5
        done
        if kill -0 \(pid) 2>/dev/null; then
          echo "$(date '+%Y-%m-%d %H:%M:%S') [update] Orbit didn't quit; giving up"
          exit 1
        fi
        rm -rf \(backup)
        if [ -d \(dst) ]; then
          mv \(dst) \(backup) || { echo "$(date '+%Y-%m-%d %H:%M:%S') [update] couldn't move the old app aside"; exit 1; }
        fi
        if ditto \(src) \(dst); then
          rm -rf \(backup)
          echo "$(date '+%Y-%m-%d %H:%M:%S') [update] installed new version"
        else
          echo "$(date '+%Y-%m-%d %H:%M:%S') [update] copy failed; restoring the old app"
          rm -rf \(dst)
          mv \(backup) \(dst)
        fi
        xattr -dr com.apple.quarantine \(dst) 2>/dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S') [update] relaunching"
        open \(dst)
        """
    }
}
