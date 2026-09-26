import SwiftUI
import AppKit
import QuickLook
import UniformTypeIdentifiers
import OrbitCore

/// Notes → Library: a Finder-like outline of the notes backup (Divider → Subject → notes)
/// and Orbit's own typed notes, with a PDF viewer, typed-note editor and to-dos found in notes.
struct NotesLibraryView: View {
    @Environment(OrbitBrain.self) private var brain
    @State private var selection: String?
    @State private var showNew = false
    @State private var newDefaults: (module: String?, week: Int?) = (nil, nil)
    @State private var quickLook: URL?
    @State private var dropTarget: String?

    private var library: NotesLibraryModel { brain.notesLibrary }

    var body: some View {
        TwoPane(selection: $selection, listWidth: 330) {
            sidebar
        } detail: { id in
            detail(id)
        }
        .quickLookPreview($quickLook)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    newDefaults = (moduleOfSelection, nil)
                    showNew = true
                } label: {
                    Label("New typed note", systemImage: "square.and.pencil")
                }
                .help("New typed note (Markdown in \(library.typedRoot.path))")
                Button {
                    Task { await brain.refreshLibrary() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Look for new and changed notes")
                .disabled(library.isScanning)
            }
        }
        .sheet(isPresented: $showNew) {
            NewTypedNoteSheet(module: newDefaults.module, week: newDefaults.week) { url in
                selection = url.path
            }
        }
        .task { await brain.refreshLibrary() }
    }

    private var moduleOfSelection: String? {
        if let e = library.entry(id: selection) { return e.moduleCode }
        return findNode(selection, in: library.tree)?.moduleCode
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            if !library.suggestions.isEmpty {
                NoteSuggestionsList(limit: 3, compact: true)
                    .padding(Theme.Space.s)
                Hairline()
            }
            if library.tree.isEmpty {
                ScrollView {
                    EmptyState(systemImage: "folder",
                               title: library.isScanning ? "Looking for your notes…" : "No notes yet.",
                               message: "Pick your Notability backup folder in Settings → Notes, or start a typed note with the pencil button. Drop PDFs onto a module folder to import them.")
                        .padding(Theme.Space.l)
                }
            } else {
                List(library.tree, children: \.children, selection: $selection) { node in
                    LibraryRow(node: node, status: node.entry.flatMap { library.status[$0.noteID] },
                               todos: node.entry.map { library.todoCount(noteID: $0.noteID) } ?? 0,
                               companion: node.entry.flatMap { library.entry(id: $0.companionID) },
                               isDropTarget: dropTarget == node.id)
                        .contextMenu { contextMenu(node) }
                        .dropDestination(for: URL.self) { urls, _ in
                            guard node.isFolder else { return false }
                            let module = node.moduleCode
                            let name = node.name
                            Task { _ = await brain.importIntoModule(urls, moduleCode: module, folderName: name) }
                            return true
                        } isTargeted: { on in
                            if node.isFolder { dropTarget = on ? node.id : (dropTarget == node.id ? nil : dropTarget) }
                        }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ node: LibraryNode) -> some View {
        if let e = node.entry {
            Button("Quick Look") { quickLook = e.url }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }
            if e.kind == .handwritten {
                Button("Type up this note") {
                    Task {
                        if let url = await brain.createTypedNote(moduleCode: e.moduleCode, week: e.week) {
                            selection = e.id
                            _ = url
                        }
                    }
                }
            }
        } else {
            Button("New typed note here") {
                newDefaults = (node.moduleCode, nil)
                showNew = true
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(_ id: String?) -> some View {
        if let entry = library.entry(id: id) {
            switch entry.kind {
            case .typed:
                TypedNoteDetail(entry: entry, companion: library.entry(id: entry.companionID))
                    .id(entry.id)
            case .handwritten, .imported:
                if entry.isPDF {
                    PDFNoteDetail(entry: entry, quickLook: $quickLook)
                        .id(entry.id)
                } else {
                    FileDetail(entry: entry, quickLook: $quickLook)
                }
            }
        } else if let node = findNode(id, in: library.tree) {
            FolderDetail(node: node) {
                newDefaults = (node.moduleCode, nil)
                showNew = true
            } open: { selection = $0 }
        } else {
            LibraryOverview()
        }
    }

    private func findNode(_ id: String?, in nodes: [LibraryNode]) -> LibraryNode? {
        guard let id else { return nil }
        for n in nodes {
            if n.id == id { return n }
            if let hit = findNode(id, in: n.children ?? []) { return hit }
        }
        return nil
    }
}

// MARK: - Row

private struct LibraryRow: View {
    var node: LibraryNode
    var status: NoteReadStatus?
    var todos: Int
    var companion: LibraryEntry?
    var isDropTarget: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .font(Theme.body.weight(node.isFolder ? .semibold : .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let e = node.entry {
                    HStack(spacing: 5) {
                        if let w = e.week { Text("Wk \(w)") }
                        Text(e.modified.formatted(.dateTime.day().month(.abbreviated)))
                        if let status { Text(status.label).foregroundStyle(status.lowConfidence ? Theme.warning : Theme.textTertiary) }
                    }
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if companion != nil {
                Image(systemName: node.entry?.kind == .typed ? "pencil.and.scribble" : "keyboard")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .help(node.entry?.kind == .typed ? "Handwritten version exists" : "Typed up")
            }
            if todos > 0 {
                Text("\(todos)")
                    .font(Theme.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(TaskOrigin.required.color))
                    .help("\(todos) to-do\(todos == 1 ? "" : "s") found in this note")
            }
        }
        .padding(.vertical, 2)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        let color = node.moduleCode.map { Theme.moduleColor($0) } ?? Theme.textTertiary
        switch node.entry?.kind {
        case nil:
            Image(systemName: "folder.fill").foregroundStyle(color)
        case .handwritten?:
            Image(systemName: "doc.richtext").foregroundStyle(color)
        case .typed?:
            Image(systemName: "doc.text").foregroundStyle(color)
        case .imported?:
            Image(systemName: "doc").foregroundStyle(color)
        }
    }
}

// MARK: - Overview & folder

private struct LibraryOverview: View {
    @Environment(OrbitBrain.self) private var brain

    var body: some View {
        Page(maxWidth: 720) {
            PageHeader(title: "Library", subtitle: "Your handwritten notes, typed notes and imported files, by module and week.")
                .padding(.top, Theme.Space.xl)
            if !brain.notesLibrary.suggestions.isEmpty {
                PageSection(title: "Suggested from your notes", count: brain.notesLibrary.suggestions.count) {
                    NoteSuggestionsList(limit: 12)
                }
            }
            PageSection(title: "Where notes live") {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Handwritten: \(MacPrefs.string(MacPrefs.notesFolderPath) ?? "pick your Notability backup folder in Settings")")
                    Text("Typed: \(brain.notesLibrary.typedRoot.path)")
                    Button("Show typed notes in Finder") {
                        try? FileManager.default.createDirectory(at: brain.notesLibrary.typedRoot, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([brain.notesLibrary.typedRoot])
                    }
                    .orbitGlassButton()
                }
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct FolderDetail: View {
    @Environment(OrbitBrain.self) private var brain
    var node: LibraryNode
    var newNote: () -> Void
    var open: (String) -> Void

    var body: some View {
        let entries = node.allEntries.sorted { $0.modified > $1.modified }
        Page(maxWidth: 720) {
            HStack(spacing: Theme.Space.s) {
                IconTile(symbol: "folder.fill", color: node.moduleCode.map { Theme.moduleColor($0) } ?? Destination.notes.color, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).font(Theme.pageTitle).foregroundStyle(Theme.textPrimary)
                    HStack(spacing: Theme.Space.s) {
                        ModuleTag(code: node.moduleCode, name: brain.moduleName(node.moduleCode))
                        Text("\(entries.count) note\(entries.count == 1 ? "" : "s")")
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
                Button(action: newNote) { Label("New typed note", systemImage: "square.and.pencil") }
                    .orbitGlassProminentButton(Destination.notes.color)
            }
            .padding(.top, Theme.Space.xl)
            PageSection(title: "Recent") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entries.prefix(20)) { e in
                        Button { open(e.id) } label: {
                            HStack {
                                Image(systemName: e.kind == .typed ? "doc.text" : "doc.richtext")
                                    .foregroundStyle(Theme.moduleColor(e.moduleCode))
                                Text(e.title).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text(e.modified.formatted(date: .abbreviated, time: .omitted))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .font(Theme.body)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("Drop PDFs or other files on this folder in the sidebar to copy them into Orbit Notes.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, Theme.Space.m)
        }
    }
}

private struct FileDetail: View {
    var entry: LibraryEntry
    @Binding var quickLook: URL?

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable()
                .frame(width: 96, height: 96)
            Text(entry.url.lastPathComponent).font(Theme.headline).foregroundStyle(Theme.textPrimary)
            HStack {
                Button("Quick Look") { quickLook = entry.url }.orbitGlassProminentButton()
                Button("Open") { NSWorkspace.shared.open(entry.url) }.orbitGlassButton()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }.orbitGlassButton()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - PDF note

/// A handwritten (or imported) PDF: PDFKit viewer with thumbnails, zoom and search, and a
/// side panel with the OCR transcript, key points, to-dos and the week's lecture slides.
struct PDFNoteDetail: View {
    @Environment(OrbitBrain.self) private var brain
    var entry: LibraryEntry
    @Binding var quickLook: URL?
    @State private var controller = PDFViewController()
    @State private var query = ""
    @State private var showThumbnails = true
    @State private var showPanel = true
    @State private var typingUp: URL?
    @State private var note: LectureNote?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Hairline()
            if let typingUp {
                HSplitView {
                    PDFKitView(url: entry.url, controller: controller, showThumbnails: false)
                        .frame(minWidth: 320)
                    RichNoteEditor(url: typingUp)
                        .frame(minWidth: 320)
                }
            } else {
                HStack(spacing: 0) {
                    PDFKitView(url: entry.url, controller: controller, showThumbnails: showThumbnails)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showPanel {
                        Rectangle().fill(Theme.separator).frame(width: Theme.hairline).frame(maxHeight: .infinity)
                        NoteSidePanel(entry: entry, note: note, query: query)
                            .frame(width: 300)
                    }
                }
            }
        }
        .onAppear { note = brain.fullNote(id: entry.noteID) }
        .onChange(of: brain.notesLibrary.revision) { _, _ in note = brain.fullNote(id: entry.noteID) }
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(Theme.headline).foregroundStyle(Theme.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    ModuleTag(code: entry.moduleCode)
                    if let w = entry.week { Text("Week \(w)") }
                    if controller.pageCount > 0 { Text("Page \(controller.pageIndex + 1) of \(controller.pageCount)") }
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: Theme.Space.s)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField("Search page text and OCR", text: $query)
                    .textFieldStyle(.plain)
                    .frame(width: 170)
                    .onSubmit {
                        if controller.matches.isEmpty { controller.search(query) } else { controller.nextMatch() }
                    }
                    .onChange(of: query) { _, q in controller.search(q) }
                if !query.isEmpty {
                    Text(controller.matches.isEmpty ? "0" : "\(controller.matchIndex + 1)/\(controller.matches.count)")
                        .font(Theme.caption.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .orbitGlass(in: Capsule())
            ControlGroup {
                Button { controller.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
                Button { controller.zoomToFit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }.help("Fit")
                Button { controller.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
            }
            .frame(width: 110)
            Button {
                if typingUp != nil { typingUp = nil; return }
                let subject = brain.notesLibrary.subjects.first { $0.entries.contains { $0.id == entry.id } }?.name
                    ?? brain.moduleName(entry.moduleCode) ?? "Notes"
                Task { typingUp = await brain.createRichNote(subject: subject, title: entry.title + " (typed)") }
            } label: {
                Label(typingUp == nil ? "Type up" : "Done typing", systemImage: typingUp == nil ? "keyboard" : "checkmark")
            }
            .orbitGlassProminentButton(Destination.notes.color)
            .help("Type up this note side by side (a typed note in the same subject)")
            Menu {
                Toggle("Page thumbnails", isOn: $showThumbnails)
                Toggle("Notes panel", isOn: $showPanel)
                Divider()
                Button("Quick Look") { quickLook = entry.url }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                Button("Open in Notability") {
                    // Notability has no documented URL scheme for a note: reveal the file instead.
                    NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                }
                Button("Open in Preview") { NSWorkspace.shared.open(entry.url) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
    }
}

/// Transcript, key points, to-dos and the week's slides for one note.
private struct NoteSidePanel: View {
    @Environment(OrbitBrain.self) private var brain
    var entry: LibraryEntry
    var note: LectureNote?
    var query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let status = brain.notesLibrary.status[entry.noteID] {
                    HStack(spacing: 6) {
                        Image(systemName: status.ocrPages > 0 ? "pencil.and.scribble" : "text.alignleft")
                        Text(status.label)
                        if status.pages > 0 {
                            Text("· \(status.textPages) text, \(status.ocrPages) OCR of \(status.pages)")
                        }
                    }
                    .font(Theme.caption)
                    .foregroundStyle(status.lowConfidence ? Theme.warning : Theme.textTertiary)
                }

                let actions = brain.notesLibrary.actions(noteID: entry.noteID).filter { $0.status != .dismissed }
                if !actions.isEmpty {
                    section("To-dos in this note", count: actions.count) {
                        ForEach(actions, id: \.action.key) { e in
                            NoteActionRow(action: e.action, status: e.status)
                        }
                    }
                }

                if let note, !note.keyPoints.isEmpty {
                    section("Key points") {
                        Text(note.keyPoints).font(Theme.body).foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }

                section("Transcript") {
                    if let note, !note.fullDetail.isEmpty {
                        Text(highlight(note.fullDetail))
                            .font(Theme.body)
                            .foregroundStyle(Theme.textPrimary)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(note == nil ? "Not read yet. It's read on the next notes sync." : "No handwriting on this note.")
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                }

                if let module = entry.moduleCode, let week = entry.week {
                    let slides = brain.academic.materials(module: module, week: week)
                    if !slides.isEmpty {
                        section("Week \(week) materials", count: slides.count) {
                            ForEach(slides) { doc in
                                Button {
                                    if let s = doc.url, let url = URL(string: s) { NSWorkspace.shared.open(url) }
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Image(systemName: doc.kind == .slides ? "rectangle.on.rectangle" : "doc")
                                            .foregroundStyle(Theme.moduleColor(module))
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(doc.title).foregroundStyle(Theme.textPrimary).lineLimit(2)
                                            Text(doc.kind.label).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                        }
                                    }
                                    .font(Theme.body)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(doc.url == nil)
                            }
                        }
                    }
                    if let review = brain.academic.review(module: module, week: week), !review.missed.isEmpty {
                        section("Missed vs slides", count: review.missed.count) {
                            ForEach(Array(review.missed.prefix(8).enumerated()), id: \.offset) { _, m in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.topic).font(Theme.body).foregroundStyle(Theme.textPrimary)
                                    if !m.slides.isEmpty {
                                        Text("Slides \(m.slides.map(String.init).joined(separator: ", "))")
                                            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.l)
        }
    }

    private func section<C: View>(_ title: String, count: Int? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 6) {
                Text(title).font(Theme.cardTitle).foregroundStyle(Theme.textPrimary)
                if let count { Text("\(count)").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary) }
            }
            content()
        }
    }

    private func highlight(_ text: String) -> AttributedString {
        var s = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return s }
        var range = s.startIndex..<s.endIndex
        while let r = s[range].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            s[r].backgroundColor = Color.yellow.opacity(0.45)
            range = r.upperBound..<s.endIndex
        }
        return s
    }
}

// MARK: - Typed note

private struct TypedNoteDetail: View {
    var entry: LibraryEntry
    var companion: LibraryEntry?
    @State private var sideBySide = false
    @State private var controller = PDFViewController()

    var body: some View {
        VStack(spacing: 0) {
            if let companion, companion.isPDF {
                HStack {
                    Image(systemName: "doc.richtext").foregroundStyle(Theme.moduleColor(companion.moduleCode))
                    Text("Handwritten: \(companion.relativePath)")
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Toggle("Side by side", isOn: $sideBySide).toggleStyle(.switch).controlSize(.small)
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, 6)
                Hairline()
            }
            if sideBySide, let companion {
                HSplitView {
                    PDFKitView(url: companion.url, controller: controller, showThumbnails: false).frame(minWidth: 300)
                    TypedNoteEditor(url: entry.url).frame(minWidth: 300)
                }
            } else {
                TypedNoteEditor(url: entry.url)
            }
        }
    }
}

// MARK: - New typed note

struct NewTypedNoteSheet: View {
    @Environment(OrbitBrain.self) private var brain
    @Environment(\.dismiss) private var dismiss
    @State var module: String?
    @State var week: Int?
    var created: (URL) -> Void
    @State private var weekValue = 1
    @State private var working = false

    var body: some View {
        let modules = brain.knownModules()
        let name = brain.moduleName(module) ?? module ?? "Module"
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("New typed note").font(Theme.title(Theme.Size.title2))
            Picker("Module", selection: $module) {
                Text("No module").tag(String?.none)
                ForEach(modules, id: \.code) { m in
                    Text("\(m.code) · \(m.name)").tag(String?.some(m.code))
                }
            }
            Stepper(value: $weekValue, in: 1...15) {
                Text("Week \(weekValue)").font(Theme.body.monospacedDigit())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(TypedNotesStore.title(week: weekValue, moduleName: name))
                    .font(Theme.headline).foregroundStyle(Theme.textPrimary)
                Text(TypedNotesStore(root: brain.notesLibrary.typedRoot)
                    .url(moduleCode: module, moduleName: brain.moduleName(module), week: weekValue).path)
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).orbitGlassButton()
                Button("Create") {
                    working = true
                    Task {
                        if let url = await brain.createTypedNote(moduleCode: module, week: weekValue) { created(url) }
                        working = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .orbitGlassProminentButton(Destination.notes.color)
                .disabled(working)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 440)
        .onAppear {
            weekValue = week ?? brain.academic.currentWeek?.week ?? 1
        }
    }
}

// MARK: - Suggestions

/// "Suggested from your notes": one click adds a task, the cross dismisses it for good.
struct NoteSuggestionsList: View {
    @Environment(OrbitBrain.self) private var brain
    var limit: Int = 5
    var compact: Bool = false

    var body: some View {
        let items = Array(brain.notesLibrary.suggestions.prefix(limit))
        VStack(alignment: .leading, spacing: compact ? 2 : Theme.Space.xs) {
            if compact {
                Text("Suggested from your notes")
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(TaskOrigin.recommended.color)
                    .padding(.horizontal, Theme.Space.xs)
            }
            ForEach(items) { a in
                NoteActionRow(action: a, status: .suggested, compact: compact)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(Motion.snappy, value: items.map(\.key))
    }
}

struct NoteActionRow: View {
    @Environment(OrbitBrain.self) private var brain
    var action: NoteAction
    var status: NoteActionLedger.Status
    var compact: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: action.kind.symbol)
                .font(.system(size: 11))
                .foregroundStyle(action.kind == .homework ? TaskOrigin.required.color : TaskOrigin.recommended.color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(compact ? 1 : 2)
                if !compact {
                    HStack(spacing: 6) {
                        ModuleTag(code: action.moduleCode)
                        Text(action.kind.label)
                        if let due = action.due {
                            Text((action.dueInferred ? "~" : "") + due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        }
                        Text(action.noteTitle).lineLimit(1)
                    }
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 4)
            switch status {
            case .suggested:
                Button { brain.addNoteAction(action) } label: { Image(systemName: "plus") }
                    .orbitGlassButton()
                    .controlSize(.small)
                    .help("Add to your to-dos")
                Button { brain.dismissNoteAction(action) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                    .help("Not a to-do")
            case .added:
                Label(action.kind == .homework ? "Required" : "Added", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.success)
            case .dismissed:
                EmptyView()
            }
        }
        .padding(.horizontal, Theme.Space.xs)
        .padding(.vertical, compact ? 2 : 4)
        .help(action.sourceText)
    }
}
