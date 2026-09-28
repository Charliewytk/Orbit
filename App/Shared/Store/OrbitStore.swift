import Foundation
import SwiftData

/// Builds the shared SwiftData container: stored in the App Group and synced
/// with the CloudKit private database. Falls back to a local-only store (and
/// finally an in-memory one) so a signing or iCloud problem never stops the
/// app from launching; Diagnostics shows which mode is active.
enum OrbitStore {
    enum Mode: String { case cloudKit = "iCloud sync", local = "This device only", memory = "Temporary (in memory)" }

    static let schema = Schema([
        StoredTask.self, StoredBlock.self, StoredEvent.self, StoredEmailDigest.self, StoredModule.self,
        StoredAssessment.self, StoredReading.self, StoredAnnouncement.self, StoredNote.self,
        StoredFlashcard.self, StoredPlan.self, StoredChatMessage.self, StoredBrief.self,
        StoredNotification.self, StoredSettings.self,
    ])

    @MainActor static let shared: ModelContainer = makeContainer()
    @MainActor private(set) static var mode: Mode = .cloudKit
    @MainActor private(set) static var setupError: String?

    static var cloudKitContainerID: String? {
        Bundle.main.object(forInfoDictionaryKey: "OrbitICloudContainer") as? String
    }

    @MainActor
    private static func makeContainer() -> ModelContainer {
        let group = ModelConfiguration.GroupContainer.identifier(AppGroup.identifier)
        if let cloud = cloudKitContainerID, !cloud.isEmpty, !cloud.contains("$(") {
            do {
                let config = ModelConfiguration("Orbit", schema: schema, isStoredInMemoryOnly: false, allowsSave: true,
                                                groupContainer: group, cloudKitDatabase: .private(cloud))
                mode = .cloudKit
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                setupError = "iCloud store: \(error.localizedDescription)"
            }
        }
        do {
            let config = ModelConfiguration("OrbitLocal", schema: schema, isStoredInMemoryOnly: false, allowsSave: true,
                                            groupContainer: .automatic, cloudKitDatabase: .none)
            mode = .local
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            setupError = (setupError.map { $0 + "; " } ?? "") + "Local store: \(error.localizedDescription)"
        }
        mode = .memory
        let memory = ModelConfiguration("OrbitMemory", schema: schema, isStoredInMemoryOnly: true,
                                        allowsSave: true, groupContainer: .none, cloudKitDatabase: .none)
        // An in-memory store with this schema can't fail short of a programming error.
        return try! ModelContainer(for: schema, configurations: [memory])
    }
}
