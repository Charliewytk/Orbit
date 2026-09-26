import AppKit
import Foundation
import Observation
import OrbitCore

/// Checks the "mac-latest" GitHub release on launch and every 6 hours. If it was
/// built from a different commit than this app (Info.plist `OrbitBuildSHA`, set by
/// the release workflow), offers to update: downloads Orbit-mac.zip, unzips it with
/// ditto, and hands over to a small script that waits for Orbit to quit, swaps the
/// app, clears quarantine and relaunches. Everything is logged under "update".
@MainActor
@Observable
final class UpdateService {
    enum Phase: Equatable {
        case idle, checking, downloading, installing
        case failed(String)
    }

    @ObservationIgnored weak var hub: FeatureHub?
    private(set) var status: UpdateStatus = .unknown("Not checked yet")
    private(set) var phase: Phase = .idle
    private(set) var lastChecked: Date?

    var isAvailable: Bool { status.isAvailable }

    /// Commit this build came from (empty for local Xcode builds).
    var currentSHA: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "OrbitBuildSHA") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return raw.hasPrefix("$(") ? "" : raw
    }

    var currentShortSHA: String { currentSHA.isEmpty ? "local build" : String(currentSHA.prefix(7)) }

    /// When this copy was built (the executable's modification date).
    var buildDate: Date? {
        guard let path = Bundle.main.executablePath else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    var statusText: String {
        switch phase {
        case .checking: return "Checking for updates…"
        case .downloading: return "Downloading the update…"
        case .installing: return "Installing; Orbit will restart…"
        case .failed(let e): return e
        case .idle: break
        }
        switch status {
        case .upToDate: return "Orbit is up to date (\(currentShortSHA))."
        case .available(let sha, _, let published):
            let when = published.map { " from \(DayCalendar().shortDay($0))" } ?? ""
            return "Update available\(sha.map { " (\($0.prefix(7)))" } ?? "")\(when)."
        case .unknown(let why): return why
        }
    }

    func checkIfDue(now: Date) async {
        guard now.timeIntervalSince(lastChecked ?? .distantPast) >= 6 * 3600 else { return }
        await check(reason: "timer")
    }

    func check(reason: String) async {
        guard phase == .idle || isFailed else { return }
        phase = .checking
        lastChecked = Date()
        defer { if phase == .checking { phase = .idle } }
        do {
            let release = try await UpdateDecision.fetch()
            status = UpdateDecision.evaluate(release, currentSHA: currentSHA, buildDate: buildDate)
            OrbitLog.log("update", "check (\(reason)): running \(currentShortSHA), release \(release.commitSHA.map { String($0.prefix(7)) } ?? "?") → \(statusText)")
            if status.isAvailable {
                hub?.notify(id: "update-\(release.commitSHA ?? release.published_at ?? "new")", title: "Orbit update available",
                            body: "Open Orbit's menu or Settings → Updates to install it.", category: "general", onMac: true)
            }
        } catch {
            status = .unknown("Couldn't check for updates (\(error.localizedDescription)).")
            OrbitLog.log("update", "check failed: \(error)")
        }
    }

    private var isFailed: Bool { if case .failed = phase { return true }; return false }

    /// Where the new app goes: the running bundle, unless macOS is running it from a
    /// read-only translocated copy (then /Applications/Orbit.app).
    var destinationPath: String {
        let running = Bundle.main.bundlePath
        if running.contains("/AppTranslocation/") || running.hasPrefix("/Volumes/") { return "/Applications/Orbit.app" }
        return running
    }

    func install() async {
        guard case .available(let sha, let zipURL, _) = status else { return }
        phase = .downloading
        OrbitLog.log("update", "downloading \(zipURL.absoluteString) (\(sha ?? "no sha"))")
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (downloaded, response) = try await URLSession.shared.download(from: zipURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw UpdateError("Download failed (HTTP \(http.statusCode)).")
            }
            let zip = work.appendingPathComponent("Orbit-mac.zip")
            try FileManager.default.moveItem(at: downloaded, to: zip)
            OrbitLog.log("update", "downloaded \((try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0) bytes")

            phase = .installing
            let unzipped = work.appendingPathComponent("unzipped", isDirectory: true)
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path])
            guard let newApp = try FileManager.default.contentsOfDirectory(at: unzipped, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { throw UpdateError("The download didn't contain Orbit.app.") }

            let dest = destinationPath
            let parent = (dest as NSString).deletingLastPathComponent
            guard FileManager.default.isWritableFile(atPath: parent) else {
                throw UpdateError("Orbit can't write to \(parent). Move Orbit to Applications and try again.")
            }
            let script = UpdateInstallerScript.make(pid: ProcessInfo.processInfo.processIdentifier, newApp: newApp.path,
                                                    destination: dest, logFile: OrbitLog.fileURL.path)
            let scriptURL = work.appendingPathComponent("install.sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/bash")
            helper.arguments = [scriptURL.path]
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            try helper.run()
            OrbitLog.log("update", "helper started for \(dest); quitting")
            hub?.willTerminate()
            try? await Task.sleep(for: .milliseconds(300))
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
            OrbitLog.log("update", "install failed: \(error.localizedDescription)")
        }
    }

    struct UpdateError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// Runs a tool off the main thread and throws if it fails.
    nonisolated static func run(_ tool: String, _ args: [String]) async throws {
        try await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let err = Pipe()
            p.standardError = err
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw UpdateError("\((tool as NSString).lastPathComponent) failed: \(msg.prefix(200))")
            }
        }.value
    }
}
