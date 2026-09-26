import SwiftUI
import SwiftData
import AppKit
import UserNotifications

@main
struct OrbitMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var app: AppModel
    @State private var brain: OrbitBrain

    init() {
        let container = OrbitStore.shared
        let brain = OrbitBrain(container: container)
        let app = AppModel(container: container, backend: brain)
        brain.app = app
        MacAppDelegate.brain = brain
        _brain = State(initialValue: brain)
        _app = State(initialValue: app)
    }

    var body: some Scene {
        Window("Orbit", id: "main") {
            RootView()
                .modifier(ShutdownPresenter())
                .environment(app)
                .environment(brain)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    brain.start()
                    await Notifier.requestAuthorization()
                }
        }
        .modelContainer(app.container)
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Task…") { post(.orbitQuickAdd) }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Search and Commands…") { post(.orbitCommandPalette) }
                    .keyboardShortcut("k", modifiers: [.command])
                Divider()
                Button("Sync Now") { Task { await brain.syncNow() } }
                    .keyboardShortcut("r", modifiers: [.command])
            }
            CommandMenu("Go") {
                ForEach(Array(Destination.macSidebar.enumerated()), id: \.element) { index, d in
                    Button(d.title) { NotificationCenter.default.post(name: .orbitNavigate, object: d) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
                }
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(app)
                .environment(brain)
                .modelContainer(app.container)
        } label: {
            Image(systemName: "circle.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettingsView()
                .environment(app)
                .environment(brain)
                .modelContainer(app.container)
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var brain: OrbitBrain?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated {
            // Start syncing even if the window isn't opened (e.g. launched at login).
            MacAppDelegate.brain?.start()
            if let brain = MacAppDelegate.brain { CompanionHub.shared.start(brain: brain) }
        }
    }

    /// Orbit keeps running in the menu bar when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            MacAppDelegate.brain?.stop()
        }
    }

    /// Notification actions: Start focus / Snooze 30m / Not now on nudges, and the shutdown ritual.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let nudgeID = response.notification.request.content.userInfo[NudgeService.nudgeIDKey] as? String
        let category = response.notification.request.content.categoryIdentifier
        completionHandler()
        Task { @MainActor in
            if nudgeID != nil || category == NudgeService.shutdownCategory {
                FeatureHub.shared.nudges.handle(action: action, nudgeID: nudgeID)
            } else if action == UNNotificationDefaultActionIdentifier {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // Show notifications even while Orbit is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
