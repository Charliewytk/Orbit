import SwiftUI
import SwiftData
import UIKit
import BackgroundTasks
import UserNotifications

@main
struct OrbitIOSApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var app: AppModel

    init() {
        let container = OrbitStore.shared
        let model = AppModel(container: container, backend: RemoteBackend(container: container))
        PhoneAppDelegate.app = model
        _app = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task { await PhoneRefresh.run(app) }
        }
        .modelContainer(app.container)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await PhoneRefresh.run(app) }
            case .background: PhoneAppDelegate.scheduleRefresh()
            default: break
            }
        }
    }
}

/// What the iPhone does when it comes forward or wakes in the background:
/// pick up share-sheet items, show new alerts from the Mac, refresh widgets.
@MainActor
enum PhoneRefresh {
    static func run(_ app: AppModel) async {
        app.reloadSettings()
        await app.ingestPendingInbox()
        await NotificationRelay.deliverNew(in: app.context)
        app.refreshWidgets()
    }
}

final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var app: AppModel?

    static var refreshTaskID: String { (Bundle.main.bundleIdentifier ?? "com.charliewytk.orbit") + ".refresh" }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: DispatchQueue.main) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // Registered on the main queue, so this runs on the main actor.
            MainActor.assumeIsolated { Self.handleRefresh(refresh) }
        }
        // CloudKit sends silent pushes when synced data changes.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            // Give SwiftData a moment to import the change the push announced.
            try? await Task.sleep(for: .seconds(6))
            if let app = PhoneAppDelegate.app { await PhoneRefresh.run(app) }
            completionHandler(.newData)
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task { @MainActor in
            if let app = PhoneAppDelegate.app { await PhoneRefresh.run(app) }
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
