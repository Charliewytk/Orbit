import AppKit
import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers
import OrbitCore

/// Nightly backups of Orbit's own data (never tokens or secrets): a JSON export of the
/// store (tasks, blocks, notes metadata, flashcards, preferences), the feature files
/// (stats and streak history, routine, careers watchlist), money categorisation rules,
/// the typed notes folder and optionally the course knowledge base. Zipped with
/// `ditto -c -k` into Google Drive for Desktop (then OneDrive, then ~/Documents), keeping
/// 14 dailies and 8 weeklies. Runs at 03:00, or at the next launch if the Mac was asleep.
@MainActor
@Observable
final class BackupService {
    @ObservationIgnored weak var hub: FeatureHub?
    private(set) var running = false
    private(set) var restoring = false
    var status = ""

    private var routine: RoutineService? { hub?.routine }

    var lastBackup: Date? { routine?.state.lastBackup }
    var lastError: String? { routine?.state.lastBackupError }

    var planner: BackupPlanner { BackupPlanner(calendar: DayCalendar(timeZone: hub?.prefs.timeZone ?? .current)) }

    /// Where backups go (a chosen folder, else auto-detected).
    var destination: (url: URL, label: String) {
        if let custom = routine?.state.backupFolder, !custom.isEmpty {
            return (URL(fileURLWithPath: custom, isDirectory: true), "Chosen folder")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cloud = (try? FileManager.default.contentsOfDirectory(atPath: home + "/Library/CloudStorage")) ?? []
        let d = BackupPlanner.destination(home: home, cloudStorage: cloud) { FileManager.default.fileExists(atPath: $0) }
        return (URL(fileURLWithPath: d.path, isDirectory: true), d.label)
    }

    // MARK: Schedule

    func tick(now: Date) async {
        guard !running, planner.isDue(now: now, lastBackup: lastBackup) else { return }
        // Don't retry a failing destination more than hourly.
        if lastError != nil, let last = routine?.state.lastBackupAttempt, now.timeIntervalSince(last) < 3600 { return }
        await backUp(reason: "scheduled")
    }

    // MARK: Back up

    @discardableResult
    func backUp(reason: String = "manual") async -> URL? {
        guard !running, let hub, let context = hub.context, let brain = hub.brain else { return nil }
        running = true
        status = "Backing up…"
        defer { running = false }
        let now = Date()
        routine?.update { $0.lastBackupAttempt = now }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("orbit-backup-\(UUID().uuidString)", isDirectory: true)
        let root = staging.appendingPathComponent("Orbit Backup", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
            var counts: [String: Int] = [:]
            func write<T: Encodable>(_ value: T, _ name: String, count: Int? = nil) throws {
                try FeatureFiles.encoder.encode(value).write(to: root.appendingPathComponent("data/\(name)"))
                if let count { counts[name.replacingOccurrences(of: ".json", with: "")] = count }
            }
            // 1. The store.
            let tasks = context.all(StoredTask.self).map(\.value)
            try write(tasks, "tasks.json", count: tasks.count)
            let blocks = context.all(StoredBlock.self).map(\.value)
            try write(blocks, "blocks.json", count: blocks.count)
            let notes = context.all(StoredNote.self).map(BackupNoteMeta.init)
            try write(notes, "notes-metadata.json", count: notes.count)
            let cards = context.all(StoredFlashcard.self).map(\.value)
            try write(cards, "flashcards.json", count: cards.count)
            try write(hub.prefs, "prefs.json")
            // 2. Feature files (stats + streak history, routine + shutdown history, careers watchlist).
            let featureDir = root.appendingPathComponent("features", isDirectory: true)
            try fm.createDirectory(at: featureDir, withIntermediateDirectories: true)
            for name in Self.featureFiles {
                let src = hub.files.root.appendingPathComponent(name)
                if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: featureDir.appendingPathComponent(name)) }
            }
            // 3. Money: only the categorisation rules (no transactions, no tokens).
            try write(hub.money.data.categoriser, "money-categorisation.json")
            // 4. Typed notes.
            let includeTyped = routine?.state.backupIncludeTypedNotes ?? true
            if includeTyped {
                let typedRoot = brain.typedNotesStore.root
                if fm.fileExists(atPath: typedRoot.path) {
                    try fm.copyItem(at: typedRoot, to: root.appendingPathComponent("Typed Notes", isDirectory: true))
                }
            }
            // 5. Knowledge base (large, off by default).
            let includeKB = routine?.state.backupIncludeKnowledge ?? false
            if includeKB, fm.fileExists(atPath: brain.local.knowledgeURL.path) {
                try fm.copyItem(at: brain.local.knowledgeURL, to: root.appendingPathComponent("course-knowledge.json"))
            }
            // Manifest.
            var files: [String: Int] = [:]
            if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in e {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
                    if let size { files[String(url.path.dropFirst(root.path.count + 1))] = size }
                }
            }
            let manifest = BackupManifest(createdAt: now, appVersion: AppConfig.appVersion, hostName: Host.current().localizedName ?? "Mac",
                                          files: files, counts: counts, includesTypedNotes: includeTyped, includesKnowledgeBase: includeKB)
            try FeatureFiles.encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"))

            // Zip into the destination.
            let dest = destination.url
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let zip = dest.appendingPathComponent(planner.fileName(for: now))
            try await Self.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, zip.path])
            prune(in: dest)
            routine?.update { s in
                s.lastBackup = now
                s.lastBackupFile = zip.path
                s.lastBackupError = nil
            }
            status = "Backed up to \(destination.label)"
            OrbitLog.log("backup", "\(reason) backup → \(zip.path) (\(counts))")
            return zip
        } catch {
            routine?.update { $0.lastBackupError = error.localizedDescription }
            status = "Backup failed: \(error.localizedDescription)"
            OrbitLog.log("backup", "FAILED: \(error)")
            return nil
        }
    }

    static let featureFiles = ["feature-state.json", "stats.json", "routine-state.json", "careers.json"]

    /// Deletes backups beyond 14 dailies + 8 weeklies.
    private func prune(in dir: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let files = names.compactMap { planner.parse($0) }
        for f in planner.toDelete(files) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f.name))
            OrbitLog.log("backup", "pruned \(f.name)")
        }
    }

    // MARK: Restore

    /// Picks a backup zip, confirms, and imports it (tasks and flashcards are merged; the
    /// feature files and preferences replace the current ones; typed notes only fill gaps).
    func restoreInteractively() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = destination.url
        panel.message = "Choose an Orbit backup to restore"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Restore “\(url.lastPathComponent)”?"
        alert.informativeText = "Tasks, study blocks and flashcards from the backup are added back (current ones are kept). Preferences, the routine, stats and streak history are replaced. Typed notes that are missing are copied back. Orbit restarts its features afterwards."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await restore(from: url)
    }

    func restore(from zip: URL) async {
        guard let hub, let context = hub.context, let brain = hub.brain else { return }
        restoring = true
        defer { restoring = false }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("orbit-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        do {
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, tmp.path])
            let root = tmp.appendingPathComponent("Orbit Backup", isDirectory: true)
            guard fm.fileExists(atPath: root.appendingPathComponent("manifest.json").path) else {
                throw BackupError("That zip isn't an Orbit backup (no manifest.json).")
            }
            func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
                (try? Data(contentsOf: root.appendingPathComponent("data/\(name)"))).flatMap { try? FeatureFiles.decoder.decode(T.self, from: $0) }
            }
            var added = 0
            let taskIndex = context.indexed(StoredTask.self)
            for t in read([OrbitTask].self, "tasks.json") ?? [] where taskIndex[t.id.uuidString] == nil {
                context.insert(StoredTask(task: t))
                added += 1
            }
            let blockIndex = context.indexed(StoredBlock.self)
            for b in read([ScheduledBlock].self, "blocks.json") ?? [] where blockIndex[b.id.uuidString] == nil && b.end < Date() {
                context.insert(StoredBlock(block: b))
            }
            let cardIndex = context.indexed(StoredFlashcard.self)
            for c in read([Flashcard].self, "flashcards.json") ?? [] where cardIndex[c.id.uuidString] == nil {
                context.insert(StoredFlashcard(card: c))
            }
            if let prefs = read(UserPrefs.self, "prefs.json") { brain.app?.savePrefs(prefs) }
            if let rules = read(Categoriser.self, "money-categorisation.json") {
                hub.money.data.categoriser = rules
                hub.money.save()
            }
            context.saveQuietly()
            // Feature files: replace, then reload.
            for name in Self.featureFiles {
                let src = root.appendingPathComponent("features/\(name)")
                guard fm.fileExists(atPath: src.path) else { continue }
                let dst = hub.files.root.appendingPathComponent(name)
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
            }
            hub.reloadAfterRestore()
            // Typed notes: copy back what's missing.
            let typedSrc = root.appendingPathComponent("Typed Notes", isDirectory: true)
            if fm.fileExists(atPath: typedSrc.path), let e = fm.enumerator(at: typedSrc, includingPropertiesForKeys: [.isDirectoryKey]) {
                let dstRoot = brain.typedNotesStore.root
                for case let url as URL in e where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                    let rel = String(url.path.dropFirst(typedSrc.path.count + 1))
                    let dst = dstRoot.appendingPathComponent(rel)
                    guard !fm.fileExists(atPath: dst.path) else { continue }
                    try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.copyItem(at: url, to: dst)
                }
            }
            hub.tasksChanged()
            status = "Restored \(zip.lastPathComponent) (\(added) tasks added back)"
            hub.toast(status)
            OrbitLog.log("backup", "restored \(zip.path)")
        } catch {
            status = "Restore failed: \(error.localizedDescription)"
            hub.toast(status)
        }
    }

    /// Lets the student pick a different folder.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        routine?.update { $0.backupFolder = url.path }
    }

    func useAutomaticFolder() { routine?.update { $0.backupFolder = nil } }

    // MARK: Process

    struct BackupError: LocalizedError {
        var message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// Runs a tool off the main thread; throws with its output on failure.
    static func run(_ tool: String, _ args: [String]) async throws {
        try await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                throw BackupError("\((tool as NSString).lastPathComponent) failed: \(String(decoding: out, as: UTF8.self).prefix(300))")
            }
        }.value
    }
}

/// Notes metadata in a backup (no full text; the typed notes folder carries the text).
struct BackupNoteMeta: Codable {
    var id: String
    var title: String
    var notebook: String
    var section: String
    var moduleCode: String?
    var week: Int?
    var created: Date
    var modified: Date
    var summary: String?
    var hasTyped: Bool
    var hasHandwriting: Bool

    init(_ n: StoredNote) {
        id = n.id; title = n.title; notebook = n.notebook; section = n.section; moduleCode = n.moduleCode; week = n.week
        created = n.created; modified = n.modified; summary = n.summary; hasTyped = n.hasTyped; hasHandwriting = n.hasHandwriting
    }
}
