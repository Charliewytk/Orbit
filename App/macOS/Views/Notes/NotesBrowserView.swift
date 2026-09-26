import SwiftUI
import AppKit
import QuickLook
import OrbitCore

/// Notes, Notability-style: Subjects │ Notes (by section, sorted by week) │ Page viewer.
/// Handwritten notes are the Notability backup PDFs from Google Drive; typed notes are
/// Orbit's own rich notes, in the same subject.
struct NotesBrowserView: View {
    @Environment(OrbitBrain.self) private var brain
    @AppStorage("notesBrowserSubject") private var subjectID = ""
    @State private var noteID: String?
    @State private var filter = ""
    @State private var quickLook: URL?

    private var library: NotesLibraryModel { brain.notesLibrary }
    private var subject: NoteSubject? {
        library.subjects.first { $0.id == subjectID } ?? library.subjects.first
    }

    var body: some View {
        HSplitView {
            NotesSubjectsPane(subjects: library.subjects, selection: subject?.id, select: selectSubject)
                .frame(minWidth: 170, idealWidth: 210, maxWidth: 300)
            NotesListPane(subject: subject, filter: $filter, selection: $noteID, newNote: newNote)
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
            NoteViewerPane(entry: library.entry(id: noteID), quickLook: $quickLook)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .quickLookPreview($quickLook)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { newNote() } label: { Label("New typed note", systemImage: "square.and.pencil") }
                    .help("New typed note in this subject")
                NotesSourceMenu()
            }
        }
        .task { await brain.refreshLibrary() }
    }

    private func selectSubject(_ id: String) {
        subjectID = id
        filter = ""
        noteID = nil
    }

    private func newNote() {
        let name = subject?.name ?? "Notes"
        Task {
            if let url = await brain.createRichNote(subject: name == NotesBrowser.unfiled ? "Notes" : name) {
                noteID = url.path
            }
        }
    }
}

// MARK: - Pane 1: subjects

private struct NotesSubjectsPane: View {
    var subjects: [NoteSubject]
    var selection: String?
    var select: (String) -> Void

    struct Group: Identifiable {
        var name: String?
        var subjects: [NoteSubject]
        var id: String { name ?? "" }
    }

    private var groups: [Group] {
        var out: [Group] = []
        for s in subjects {
            if let i = out.firstIndex(where: { $0.name == s.group }) { out[i].subjects.append(s) } else { out.append(Group(name: s.group, subjects: [s])) }
        }
        return out
    }

    var body: some View {
        if subjects.isEmpty {
            NotesSourceEmptyState()
        } else {
            List(selection: Binding(get: { selection }, set: { if let id = $0 { select(id) } })) {
                ForEach(groups) { group in
                    Section(group.name ?? "Subjects") {
                        ForEach(group.subjects) { s in
                            SubjectRow(subject: s).tag(s.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct SubjectRow: View {
    var subject: NoteSubject

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Theme.moduleColor(subject.moduleCode))
            Text(subject.name)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(subject.count)")
                .font(Theme.caption.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

// MARK: - Pane 2: notes in a subject

private struct NotesListPane: View {
    var subject: NoteSubject?
    @Binding var filter: String
    @Binding var selection: String?
    var newNote: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if let subject {
                List(selection: $selection) {
                    ForEach(NotesBrowser.filter(subject, query: filter)) { section in
                        Section(section.name.isEmpty ? "Notes" : section.name) {
                            ForEach(section.entries) { e in NoteRow(entry: e).tag(e.id) }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            } else {
                Spacer()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text(subject?.name ?? "Notes")
                    .font(Theme.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Button(action: newNote) { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help("New typed note")
            }
            TextField("Filter (e.g. week 3)", text: $filter)
                .textFieldStyle(.roundedBorder)
        }
        .padding(Theme.Space.m)
    }
}

private struct NoteRow: View {
    var entry: LibraryEntry

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: entry.kind == .typed ? "doc.richtext" : "pencil.and.scribble")
                .foregroundStyle(entry.kind == .typed ? Theme.textSecondary : Destination.notes.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let w = entry.week { Text("Week \(w)") }
                    Text(entry.modified.formatted(.dateTime.day().month(.abbreviated)))
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Pane 3: the note

private struct NoteViewerPane: View {
    var entry: LibraryEntry?
    @Binding var quickLook: URL?

    var body: some View {
        if let entry {
            switch entry.url.pathExtension.lowercased() {
            case "pdf":
                PDFNoteDetail(entry: entry, quickLook: $quickLook).id(entry.id)
            case "rtfd", "rtf":
                RichNoteEditor(url: entry.url).id(entry.id)
            case "md", "markdown", "txt":
                TypedNoteEditor(url: entry.url).id(entry.id)
            default:
                EmptyState(systemImage: "doc", title: entry.title, message: "Orbit can't show this file here.",
                           actionTitle: "Quick Look") { quickLook = entry.url }
                    .padding(Theme.Space.xl)
            }
        } else {
            EmptyState(systemImage: "book.pages", title: "Pick a note",
                       message: "Choose a subject, then a note. Handwritten pages open with thumbnails, zoom and search; typed notes open in the editor.")
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Source

/// Where handwritten notes come from: the Google Drive folder, or Drive sync.
struct NotesSourceMenu: View {
    @Environment(OrbitBrain.self) private var brain
    @AppStorage(MacPrefs.notesDriveSync) private var driveSync = false

    var body: some View {
        Menu {
            if let root = brain.notesLibrary.backupRoot {
                Text("Reading " + root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                Divider()
            }
            Button("Choose Notability folder…") { Task { await brain.chooseNotesFolder() } }
            Toggle("Sync from Google Drive (read-only)", isOn: Binding(get: { driveSync }, set: { on in
                if on { Task { await brain.enableDriveNotesSync() } } else { brain.disableDriveNotesSync() }
            }))
            Divider()
            Button("Read notes now") { Task { await brain.syncNotes() } }
                .disabled(brain.running.contains(.notes))
            Button("Refresh list") { Task { await brain.refreshLibrary() } }
        } label: {
            Label("Notes source", systemImage: brain.running.contains(.notes) ? "arrow.triangle.2.circlepath" : "externaldrive.badge.icloud")
        }
        .help("Where your Notability notes come from")
    }
}

private struct NotesSourceEmptyState: View {
    @Environment(OrbitBrain.self) private var brain

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                EmptyState(systemImage: "folder",
                           title: brain.notesLibrary.isScanning ? "Looking for your notes…" : "No notes yet",
                           message: "In Notability: Settings → Auto-backup → Google Drive, format PDF. Orbit reads My Drive → Notability through Google Drive for Mac, or syncs it directly.")
                Button("Choose Notability folder…") { Task { await brain.chooseNotesFolder() } }
                    .orbitGlassButton()
                Button("Sync from Google Drive") { Task { await brain.enableDriveNotesSync() } }
                    .orbitGlassButton()
            }
            .padding(Theme.Space.m)
        }
    }
}
