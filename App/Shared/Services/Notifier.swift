import Foundation
import SwiftData
import UserNotifications

/// Local notifications. The Mac posts them as it finds things; the iPhone
/// posts the same alerts when the matching `StoredNotification` records sync in.
enum Notifier {
    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func post(id: String, title: String, body: String, category: String = "general") async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = category
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// iPhone side: shows alerts for notification records the Mac created, once each.
@MainActor
enum NotificationRelay {
    private static let deliveredKey = "deliveredNotificationIDs"
    private static let primedKey = "notificationRelayPrimed"

    static func deliverNew(in context: ModelContext) async {
        let defaults = UserDefaults.standard
        var delivered = Set(defaults.stringArray(forKey: deliveredKey) ?? [])
        let recent = context.all(StoredNotification.self)
            .filter { $0.createdAt > Date().addingTimeInterval(-2 * 86400) }
            .sorted { $0.createdAt < $1.createdAt }
        // First run: don't replay the backlog.
        if !defaults.bool(forKey: primedKey) {
            defaults.set(true, forKey: primedKey)
            defaults.set(recent.map(\.id), forKey: deliveredKey)
            return
        }
        for n in recent where !delivered.contains(n.id) {
            await Notifier.post(id: n.id, title: n.title, body: n.body, category: n.category)
            delivered.insert(n.id)
        }
        // Keep the list bounded.
        let keep = Set(recent.map(\.id))
        defaults.set(Array(delivered.intersection(keep)), forKey: deliveredKey)
    }
}
