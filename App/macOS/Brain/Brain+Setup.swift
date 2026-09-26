import Foundation
import Observation
import OrbitCore

/// Live status for the "Exeter email via Apple Mail" setup: whether Orbit has
/// Full Disk Access and whether Apple Mail has any @exeter.ac.uk mail yet.
@MainActor
@Observable
final class ExeterMailStatus {
    static let shared = ExeterMailStatus()

    private(set) var fullDiskAccess = false
    private(set) var exeterMailFound = false
    private(set) var checking = false
    private(set) var checkedOnce = false

    private init() {}

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false; checkedOnce = true }
        let result = await Task.detached(priority: .userInitiated) { () -> (Bool, Bool) in
            let access = AppleMailReader.canReadMailFolder()
            guard access else { return (false, false) }
            let folders = (try? AppleMailReader.detectAccountFolders()) ?? []
            return (true, !folders.isEmpty)
        }.value
        fullDiskAccess = result.0
        exeterMailFound = result.1
        OrbitLog.log("exeter", "Check: Full Disk Access \(result.0 ? "yes" : "no"), Exeter mail in Apple Mail \(result.1 ? "found" : "not found")")
    }
}

extension OrbitBrain {
    /// Google Connect button: sign in, then sync straight away so Today and Inbox fill up.
    func connectGoogleAndSync() async {
        guard await accounts.connectGoogle() else { return }
        app?.show("Connected to Google as \(accounts.googleEmail ?? "your account"). Syncing…")
        await syncAfterConnecting()
    }

    /// Optional Microsoft Graph sign-in (advanced).
    func connectMicrosoftAndSync() async {
        guard await accounts.connectMicrosoft() else { return }
        await syncAfterConnecting()
    }

    /// Runs a calendar + mail sync now (waiting for any sync already running)
    /// and shows what arrived.
    func syncAfterConnecting() async {
        for _ in 0..<150 where running.contains(.calendar) || running.contains(.gmail) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        OrbitLog.log("sync", "Sync after connecting: starting")
        await syncCalendar()
        await syncMail()
        let from = Date().addingTimeInterval(-8 * 86400)
        let events = context.all(StoredEvent.self).filter { $0.end > from }.count
        let emails = context.all(StoredEmailDigest.self).count
        let message = "Synced \(emails) email\(emails == 1 ? "" : "s"), \(events) event\(events == 1 ? "" : "s")"
        OrbitLog.log("sync", "Sync after connecting: \(message)")
        app?.show(message)
    }
}
