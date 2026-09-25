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
                .environment(app)
                .environment(brain)
                .frame(minWidth: 820, minHeight: 560)
                .task {
                    brain.start()
                    await Notifier.requestAuthorization()
                }
        }
        .modelContainer(app.container)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Sync Now") { Task { await brain.syncNow() } }
                    .keyboardShortcut("r", modifiers: [.command])
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
            NavigationStack {
                SettingsView()
            }
            .environment(app)
            .environment(brain)
            .modelContainer(app.container)
            .frame(minWidth: 560, minHeight: 640)
        }
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var brain: OrbitBrain?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated {
            // Start syncing even if the window isn't opened (e.g. launched at login).
            MacAppDelegate.brain?.start()
        }
    }

    /// Orbit keeps running in the menu bar when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            MacAppDelegate.brain?.stop()
        }
    }

    // Show notifications even while Orbit is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
