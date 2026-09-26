import Foundation
import SwiftData
import OrbitCore

// MARK: - Notes Library: accessor API for the UI
//
// `brain.notesLibrary` (a `NotesLibraryModel`, @Observable, main actor):
//   .tree / .entries          the Library outline: backup folders (Divider → Subject → notes) + "Orbit Notes"
//   .status[noteID]           how a file was read (text layer / OCR pages, low confidence)
//   .suggestions              to-dos found in notes, not added or dismissed yet
//   .actions(noteID:)         everything found in one note, with its status
//   .typedRoot                ~/Documents/Orbit Notes (or the folder picked in Settings)
//
// Actions: `brain.refreshLibrary()`, `brain.createTypedNote(…)`, `brain.importIntoModule(…)`,
// `brain.typedNoteChanged(url)` (after an edit: merge with the handwriting, index, review),
// `brain.addNoteAction(_)`, `brain.dismissNoteAction(_)`.

/// How one note file was read.
struct NoteReadStatus: Codable, Hashable {
    var pages: Int
    /// Pages whose text layer was used as is.
    var textPages: Int
    /// Pages (or parts of pages) read by handwriting OCR.
    var ocrPages: Int
    var lowConfidence: Bool
    var readAt: Date

    var label: String {
        if pages == 0 { return "Typed" }
        if ocrPages == 0 { return "Text layer" }
        if textPages == 0 { return lowConfidence ? "Handwriting · check" : "Handwriting read" }
        return "Text + handwriting"
    }
}

/// Kept in Application Support/Orbit/notes-library.json.
struct NotesLibraryState: Codable {
    var ledger = NoteActionLedger()
    var status: [String: NoteReadStatus] = [:]
    /// Typed note path → MD5 of its text when last ingested.
    var typedHashes: [String: String] = [:]
}

@MainActor
@Observable
final class NotesLibraryModel {
    private(set) var entries: [LibraryEntry] = []
    private(set) var tree: [LibraryNode] = []
    private(set) var suggestions: [NoteAction] = []
    private(set) var status: [String: NoteReadStatus] = [:]
    private(set) var isScanning = false
    var typedRoot: URL = TypedNotesStore.defaultRoot()
    /// Bumped when anything changes, so views can refresh derived data.
    private(set) var revision = 0

    @ObservationIgnored var state = NotesLibraryState()
    @ObservationIgnored var loaded = false

    func entry(id: String?) -> LibraryEntry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }

    func actions(noteID: String) -> [NoteActionLedger.Entry] { state.ledger.actions(noteID: noteID) }

    func todoCount(noteID: String) -> Int {
        state.ledger.actions(noteID: noteID).filter { $0.status != .dismissed }.count
    }

    func publish() {
        suggestions = state.ledger.suggestions
        status = state.status
        revision += 1
    }

    func setEntries(_ e: [LibraryEntry], backupName: String) {
        entries = e
        tree = NotesLibrary.tree(e, backupName: backupName)
        revision += 1
    }

    func setScanning(_ on: Bool) { isScanning = on }
}

extension OrbitBrain {
    var typedNotesStore: TypedNotesStore {
        let root = MacPrefs.string(MacPrefs.typedNotesRoot).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? TypedNotesStore.defaultRoot()
        return TypedNotesStore(root: root)
    }

    func loadNotesLibraryIfNeeded() {
        guard !notesLibrary.loaded else { return }
        notesLibrary.loaded = true
        guard let saved = local.load(NotesLibraryState.self, "notes-library.json") else { return }
        notesLibrary.state = saved
        notesLibrary.publish()
    }

    func saveNotesLibrary() {
        local.save(notesLibrary.state, "notes-library.json")
        notesLibrary.publish()
    }

    /// Module names Orbit knows (ELE + stored + Exeter defaults), for pickers and folder names.
    func knownModules() -> [(code: String, name: String)] {
        var modules = academic.modules.map { (code: $0.code, name: $0.name) }
        for m in context.all(StoredModule.self) where !modules.contains(where: { $0.code == m.id }) {
            modules.append((code: m.id, name: m.name))
        }
        for d in NotebookModuleMatcher.exeterYear1Economics where !modules.contains(where: { $0.code == d.code }) {
            modules.append(d)
        }
        return modules.sorted { $0.code < $1.code }
    }

    func moduleName(_ code: String?) -> String? {
        guard let code else { return nil }
        return knownModules().first { $0.code == code }?.name
    }

    // MARK: Scanning

    /// Rebuilds the Library tree from the backup folder and the typed notes folder (off the main thread).
    func refreshLibrary() async {
        loadNotesLibraryIfNeeded()
        notesLibrary.setScanning(true)
        defer { notesLibrary.setScanning(false) }
        let backupPath = MacPrefs.string(MacPrefs.notesFolderPath)
        let backup = backupPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let typedRoot = typedNotesStore.root
        notesLibrary.typedRoot = typedRoot
        let matcher = NotebookModuleMatcher(modules: knownModules(), includeDefaults: false)
        let entries = await Task.detached(priority: .userInitiated) {
            NotesLibrary.entries(backupRoot: backup, typedRoot: typedRoot, matcher: matcher)
        }.value
        let name = backup?.lastPathComponent ?? "Notes folder"
        notesLibrary.setEntries(entries, backupName: name)
        notesLibrary.publish()
    }

    // MARK: Typed notes

    /// Creates (or opens) ~/Documents/Orbit Notes/<Module>/Week N.md.
    func createTypedNote(moduleCode: String?, week: Int?) async -> URL? {
        let store = typedNotesStore
        do {
            let url = try store.create(moduleCode: moduleCode, moduleName: moduleName(moduleCode), week: week)
            await refreshLibrary()
            return url
        } catch {
            FeatureHub.shared.toast("Couldn't create the note: \(error.localizedDescription)")
            return nil
        }
    }

    /// Copies files into a module's Orbit Notes folder (drag and drop onto the Library).
    func importIntoModule(_ urls: [URL], moduleCode: String?, folderName: String?) async -> Int {
        let store = typedNotesStore
        var copied = 0
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if (try? store.importFile(url, moduleCode: moduleCode, moduleName: moduleName(moduleCode) ?? folderName)) != nil {
                copied += 1
            }
        }
        await refreshLibrary()
        if copied > 0 { FeatureHub.shared.toast("Imported \(copied) file\(copied == 1 ? "" : "s")") }
        return copied
    }

    /// Reads every typed note that changed since last time into the notes store.
    func syncTypedNotes() async {
        loadNotesLibraryIfNeeded()
        let root = typedNotesStore.root
        guard let result = try? NotesFolderScanner(root: root).scan() else { return }
        for item in result.items where item.kind == .markdown || item.kind == .text {
            await ingestTypedNote(item: item, root: root, force: false)
        }
        saveNotesLibrary()
    }

    /// After the editor saves: merge with the handwriting, index, find to-dos, and run the
    /// notes-vs-slides review for that module week.
    func typedNoteChanged(_ url: URL) async {
        loadNotesLibraryIfNeeded()
        let root = typedNotesStore.root
        let rootPath = root.standardizedFileURL.path
        var rel = url.standardizedFileURL.path
        guard rel.hasPrefix(rootPath) else { return }
        rel = String(rel.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let item = NotesFolderScanner.Item(url: url, kind: .markdown, modified: values?.contentModificationDate ?? Date(),
                                           size: values?.fileSize ?? 0, relativePath: rel)
        guard let note = await ingestTypedNote(item: item, root: root, force: false) else { return }
        saveNotesLibrary()
        saveIndex()
        await refreshLibrary()
        if note.moduleCode != nil, note.week != nil {
            await academicAfterNotesSync(maxReviews: 1)
        }
    }

    /// One typed note in: merged into its handwritten companion when there is one
    /// (typed = key points, handwriting = detail), else stored on its own.
    @discardableResult
    private func ingestTypedNote(item: NotesFolderScanner.Item, root: URL, force: Bool) async -> LectureNote? {
        guard let text = try? String(contentsOf: item.url, encoding: .utf8) else { return nil }
        let hash = MD5.hex(text)
        if !force, notesLibrary.state.typedHashes[item.relativePath] == hash { return nil }
        let matcher = NotebookModuleMatcher(modules: knownModules(), includeDefaults: false)
        let typed = TypedNotesStore.note(markdown: text, relativePath: item.relativePath, modified: item.modified, matcher: matcher)
        notesLibrary.state.typedHashes[item.relativePath] = hash
        guard typed.hasTyped else { return typed }
        if let raw = handwrittenCompanion(module: typed.moduleCode, week: typed.week) {
            let merged = NoteMerger().combine(handwritten: raw, typed: typed)
            learn(fromCombined: merged, typed: typed.keyPoints)
            await store(note: merged.note)
            await removeStandalone(typedID: typed.id)
            return merged.note
        }
        await store(note: typed)
        return typed
    }

    /// The handwritten note (as read, before merging) for a module week.
    func handwrittenCompanion(module: String?, week: Int?) -> LectureNote? {
        guard let module, let week else { return nil }
        return local.allRawNotes()
            .filter { $0.moduleCode == module && $0.week == week && $0.id.hasPrefix("file:") }
            .max { $0.modified < $1.modified }
    }

    /// The typed note for a handwritten note's module week, if the student typed one up.
    func typedCompanion(for note: LectureNote) -> LectureNote? {
        guard let module = note.moduleCode, let week = note.week else { return nil }
        let root = typedNotesStore.root
        let matcher = NotebookModuleMatcher(modules: knownModules(), includeDefaults: false)
        guard let result = try? NotesFolderScanner(root: root).scan() else { return nil }
        for item in result.items where item.kind == .markdown || item.kind == .text {
            guard let text = try? String(contentsOf: item.url, encoding: .utf8) else { continue }
            let typed = TypedNotesStore.note(markdown: text, relativePath: item.relativePath, modified: item.modified, matcher: matcher)
            if typed.moduleCode == module, typed.week == week, typed.hasTyped {
                notesLibrary.state.typedHashes[item.relativePath] = MD5.hex(text)
                return typed
            }
        }
        return nil
    }

    private func removeStandalone(typedID: String) async {
        guard local.note(id: typedID) != nil else { return }
        local.deleteNote(id: typedID)
        noteIndex.remove(noteID: typedID)
        if let s = context.record(StoredNote.self, id: typedID) { context.delete(s) }
        context.saveQuietly()
    }

    /// The typed-up version is a free answer key for the handwriting.
    func learn(fromCombined merged: MergedNote, typed: String) {
        guard !typed.isEmpty, !merged.handwriting.isEmpty else { return }
        var profile = handwritingProfile
        HandwritingLearner().learn(regions: merged.handwriting.map(\.learnerRegion), typed: typed,
                                   pageID: merged.note.id, into: &profile)
        handwritingProfile = profile
        local.save(handwritingProfile, "handwriting-profile.json")
    }

    // MARK: To-dos found in notes

    /// Finds to-dos and notes-to-self in a note (rules, then the local model), adds clear
    /// homework as Required tasks and keeps the rest as suggestions. Re-scans never duplicate.
    func extractNoteActions(from note: LectureNote) async {
        loadNotesLibraryIfNeeded()
        let extractor = NoteActionExtractor(calendar: academic.calendar, timeZone: prefs.timeZone)
        var actions = extractor.extract(from: note)
        if note.hasHandwriting || !actions.isEmpty {
            actions = await extractor.refine(actions, note: note, router: router)
        }
        let update = notesLibrary.state.ledger.record(actions, noteID: note.id)
        var created = 0
        for action in update.toAdd where context.record(StoredTask.self, id: action.taskID.uuidString) == nil {
            context.insert(StoredTask(task: action.task()))
            created += 1
            let cal = DayCalendar(timeZone: prefs.timeZone)
            let due = action.due.map { " · due \(Fmt.dayTime($0, cal))" } ?? ""
            notify(id: "note-homework-\(action.key)", title: "\(action.moduleCode ?? "Notes"): homework from your notes",
                   body: "\(action.title)\(due)", category: "notes")
        }
        if created > 0 {
            context.saveQuietly()
            tasksChanged()
        }
        saveNotesLibrary()
    }

    /// One click from "Suggested from your notes".
    func addNoteAction(_ action: NoteAction) {
        loadNotesLibraryIfNeeded()
        if context.record(StoredTask.self, id: action.taskID.uuidString) == nil {
            context.insert(StoredTask(task: action.task()))
            context.saveQuietly()
            tasksChanged()
        }
        notesLibrary.state.ledger.mark(action.key, .added)
        saveNotesLibrary()
        FeatureHub.shared.toast("Added: \(action.title)")
    }

    func dismissNoteAction(_ action: NoteAction) {
        loadNotesLibraryIfNeeded()
        notesLibrary.state.ledger.mark(action.key, .dismissed)
        saveNotesLibrary()
    }

    func recordReadStatus(noteID: String, pages: Int, textPages: Int, ocrPages: Int, lowConfidence: Bool) {
        loadNotesLibraryIfNeeded()
        notesLibrary.state.status[noteID] = NoteReadStatus(pages: pages, textPages: textPages, ocrPages: ocrPages,
                                                           lowConfidence: lowConfidence, readAt: Date())
    }
}
