import Foundation
import AppKit
import OrbitCore

extension OrbitBrain {
    /// Reads new iMessages (local, read-only; needs Full Disk Access) and turns plans into suggestions.
    func syncIMessage() async {
        guard MacPrefs.defaults.bool(forKey: MacPrefs.iMessageEnabled), begin(.imessage) else { return }
        defer { end(.imessage) }
        let reader = IMessageReader(myName: firstName.isEmpty ? "Me" : firstName)
        guard reader.hasAccess() else {
            record(.imessage, error: "Orbit needs Full Disk Access to read Messages. Settings → Mac → Open Full Disk Access.")
            return
        }
        do {
            // Overlap by a day so plans that span the cursor keep their context.
            let cursor = state.iMessageCursor ?? Date().addingTimeInterval(-7 * 86400)
            let since = cursor.addingTimeInterval(-86400)
            let messages = try await Task.detached(priority: .utility) { try reader.messages(since: since) }.value
            let fresh = messages.filter { $0.date > cursor }
            guard !fresh.isEmpty else {
                record(.imessage, detail: "No new messages")
                return
            }
            state.iMessageCursor = fresh.map(\.date).max()
            saveState()
            let extractor = PlanExtractor(router: router, purpose: .privateData, timeZone: prefs.timeZone)
            let plans = await extractor.extract(from: messages, since: since)
            let added = app?.ingest(plans: plans, source: "imessage") ?? 0
            if added > 0 {
                notify(id: "imessage-\(Int(Date().timeIntervalSince1970))", title: "💬 Plans spotted in Messages",
                       body: "\(added) new plan\(added == 1 ? "" : "s") to review in Orbit.", category: "plan")
            }
            record(.imessage, detail: "\(fresh.count) new messages, \(added) plan(s)")
        } catch {
            record(.imessage, error: "\(error)")
        }
    }

    /// Opens System Settings → Privacy & Security → Full Disk Access.
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
