import Foundation

/// The App Group shared by the app, the widgets and the share extension.
/// The identifier comes from Info.plist (`OrbitAppGroup`, set from the xcconfig)
/// so the bundle prefix lives in exactly one place.
enum AppGroup {
    static var identifier: String {
        (Bundle.main.object(forInfoDictionaryKey: "OrbitAppGroup") as? String)
            ?? "group.com.charliewytk.orbit"
    }

    /// The shared container. Falls back to the app's own Application Support
    /// folder if the entitlement is missing (e.g. an unsigned debug build),
    /// so nothing crashes; widgets just won't see the data in that case.
    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orbit", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var widgetSnapshotURL: URL { containerURL.appendingPathComponent("widget-snapshot.json") }

    static var pendingInboxDirectory: URL {
        let url = containerURL.appendingPathComponent("PendingInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Small shared preferences (e.g. the user's first name for the share extension).
    static var defaults: UserDefaults { UserDefaults(suiteName: identifier) ?? .standard }
}
