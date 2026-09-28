import Foundation

// MARK: - Typed notes on disk

/// Orbit's own typed notes: Markdown files in ~/Documents/Orbit Notes/<Module name>/Week N.md
/// (root changeable in Settings). Plain files, so they open in any editor and back up with
/// the rest of Documents. Imported PDFs and other files sit in the same module folders.
public struct TypedNotesStore: Sendable {
    public var root: URL

    public init(root: URL) { self.root = root }

    public static func defaultRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Documents/Orbit Notes", isDirectory: true)
    }

    /// A safe folder name for a module: its name ("Introduction to Statistics"), else its code.
    public static func folderName(moduleCode: String?, moduleName: String?) -> String {
        let raw = [moduleName, moduleCode].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "Other"
        let cleaned = raw.replacingOccurrences(of: #"[/:\\?%*|"<>]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return cleaned.isEmpty ? "Other" : cleaned
    }

    public static func fileName(week: Int?) -> String {
        week.map { "Week \($0).md" } ?? "Notes.md"
    }

    /// "Week 1 — Introduction to Statistics".
    public static func title(week: Int?, moduleName: String) -> String {
        week.map { "Week \($0) — \(moduleName)" } ?? moduleName
    }

    public func folder(moduleCode: String?, moduleName: String?) -> URL {
        root.appendingPathComponent(Self.folderName(moduleCode: moduleCode, moduleName: moduleName), isDirectory: true)
    }

    public func url(moduleCode: String?, moduleName: String?, week: Int?) -> URL {
        folder(moduleCode: moduleCode, moduleName: moduleName).appendingPathComponent(Self.fileName(week: week))
    }

    /// The note's file, created with a title heading when it doesn't exist yet.
    @discardableResult
    public func create(moduleCode: String?, moduleName: String?, week: Int?, fileManager: FileManager = .default) throws -> URL {
        let url = url(moduleCode: moduleCode, moduleName: moduleName, week: week)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            let name = moduleName ?? moduleCode ?? "Notes"
            var header = "# \(Self.title(week: week, moduleName: name))\n\n"
            if let moduleCode, moduleName != nil { header += "<!-- orbit: module=\(moduleCode)\(week.map { " week=\($0)" } ?? "") -->\n\n" }
            try header.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// A new rich typed note: <root>/<Subject>/<Title>.rtfd (" 2", " 3"… when taken).
    /// Only the path is chosen here; the app writes the RTFD package.
    public func newRichNoteURL(subject: String, title: String, fileManager: FileManager = .default) -> URL {
        let dir = root.appendingPathComponent(Self.folderName(moduleCode: nil, moduleName: subject), isDirectory: true)
        let base = Self.folderName(moduleCode: nil, moduleName: title.isEmpty ? "Untitled" : title)
        var target = dir.appendingPathComponent(base + ".rtfd", isDirectory: true)
        var n = 2
        while fileManager.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(base) \(n).rtfd", isDirectory: true)
            n += 1
        }
        return target
    }

    /// Copies a file into a module folder, adding " 2", " 3"… when the name is taken.
    public func importFile(_ source: URL, moduleCode: String?, moduleName: String?, fileManager: FileManager = .default) throws -> URL {
        let dir = folder(moduleCode: moduleCode, moduleName: moduleName)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var target = dir.appendingPathComponent(source.lastPathComponent)
        var n = 2
        while fileManager.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        try fileManager.copyItem(at: source, to: target)
        return target
    }

    /// Reads the "<!-- orbit: module=BEE1022 week=1 -->" marker a new note carries.
    public static func marker(in text: String) -> (module: String?, week: Int?) {
        guard let r = text.range(of: #"<!--\s*orbit:([^>]*)-->"#, options: .regularExpression) else { return (nil, nil) }
        let body = String(text[r])
        func value(_ key: String) -> String? {
            guard let m = body.range(of: key + #"=([A-Za-z0-9]+)"#, options: .regularExpression) else { return nil }
            return String(body[m].dropFirst(key.count + 1))
        }
        return (value("module"), value("week").flatMap(Int.init))
    }

    /// A typed note as a `LectureNote`: all `.typed` segments (the student's key points),
    /// one per Markdown block so the merger can link each to the handwriting it summarises.
    public static func note(markdown: String, relativePath: String, modified: Date,
                            matcher: NotebookModuleMatcher) -> LectureNote {
        let parts = relativePath.split(separator: "/").map(String.init)
        let file = ((parts.last ?? relativePath) as NSString).deletingPathExtension
        let folder = parts.count > 1 ? parts[parts.count - 2] : nil
        let mark = marker(in: markdown)
        var title = file
        let body = markdown.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        if let first = body.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           first.hasPrefix("# ") {
            title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        let module = mark.module ?? folder.flatMap(matcher.moduleCode(forNotebook:)) ?? NoteMetadataDetector.moduleCode(in: [title, file])
        let week = mark.week ?? NoteMetadataDetector.week(in: [file, title])
        let blocks = body.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("# ") }
        return LectureNote(id: "typed:" + relativePath, title: title, notebook: "Orbit Notes", section: folder ?? "",
                           moduleCode: module, week: week, created: modified, modified: modified,
                           segments: blocks.map { NoteSegment(kind: .typed, text: $0) })
    }
}

// MARK: - Library tree

/// One file in the notes library.
public struct LibraryEntry: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A handwritten note PDF from the Notability / GoodNotes backup.
        case handwritten
        /// An Orbit typed note (Markdown).
        case typed
        /// A file imported into an Orbit Notes module folder.
        case imported
    }

    public enum Origin: String, Codable, Sendable {
        case backup, orbit
    }

    public var id: String { url.path }
    public var url: URL
    public var kind: Kind
    public var origin: Origin
    public var title: String
    /// Path below its root ("Year 1 Economics/Introduction to Statistics/Week 1.pdf").
    public var relativePath: String
    public var moduleCode: String?
    public var week: Int?
    public var modified: Date
    public var size: Int
    /// The `LectureNote` id Orbit stores this file under.
    public var noteID: String
    /// The matching typed note / handwritten PDF (same module and week), by `id`.
    public var companionID: String?

    public var isPDF: Bool { url.pathExtension.lowercased() == "pdf" }

    public init(url: URL, kind: Kind, origin: Origin, title: String, relativePath: String, moduleCode: String?,
                week: Int?, modified: Date, size: Int, noteID: String, companionID: String? = nil) {
        self.url = url; self.kind = kind; self.origin = origin; self.title = title; self.relativePath = relativePath
        self.moduleCode = moduleCode; self.week = week; self.modified = modified; self.size = size
        self.noteID = noteID; self.companionID = companionID
    }
}

/// A folder (divider, subject, module) or a file in the library outline.
public struct LibraryNode: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var moduleCode: String?
    public var entry: LibraryEntry?
    /// nil for files (so `OutlineGroup` / `List(children:)` shows no disclosure arrow).
    public var children: [LibraryNode]?

    public var isFolder: Bool { entry == nil }

    /// Every file below this node.
    public var allEntries: [LibraryEntry] {
        if let entry { return [entry] }
        return (children ?? []).flatMap(\.allEntries)
    }
}

public enum NotesLibrary {
    /// Scans the backup folder (handwritten PDFs) and the Orbit Notes folder (typed + imported).
    public static func entries(backupRoot: URL?, typedRoot: URL?, matcher: NotebookModuleMatcher,
                               notability: Bool = true) -> [LibraryEntry] {
        var out: [LibraryEntry] = []
        if let backupRoot, let result = try? NotesFolderScanner(root: backupRoot).scan() {
            for item in result.items where item.kind == .pdf || item.kind == .image {
                let meta = NotabilityNote.metadata(relativePath: item.relativePath, matcher: matcher)
                out.append(LibraryEntry(url: item.url, kind: .handwritten, origin: .backup, title: meta.title,
                                        relativePath: item.relativePath, moduleCode: meta.moduleCode,
                                        week: meta.week, modified: item.modified, size: item.size,
                                        noteID: "file:" + item.relativePath))
            }
        }
        if let typedRoot, let result = try? NotesFolderScanner(root: typedRoot).scan() {
            for item in result.items {
                let isTyped = item.kind == .markdown || item.kind == .text || item.kind == .richText
                let folder = item.relativePath.split(separator: "/").dropLast().last.map(String.init)
                let title = item.url.deletingPathExtension().lastPathComponent
                let module = folder.flatMap(matcher.moduleCode(forNotebook:)) ?? NoteMetadataDetector.moduleCode(in: [title])
                out.append(LibraryEntry(url: item.url, kind: isTyped ? .typed : .imported, origin: .orbit, title: title,
                                        relativePath: item.relativePath, moduleCode: module,
                                        week: NoteMetadataDetector.week(in: [title]), modified: item.modified,
                                        size: item.size, noteID: (isTyped ? "typed:" : "orbit-file:") + item.relativePath))
            }
        }
        return pairCompanions(out)
    }

    /// Links each typed note to the handwritten PDF for the same module and week.
    public static func pairCompanions(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        var out = entries
        var handwrittenByKey: [String: Int] = [:]
        for (i, e) in out.enumerated() where e.kind == .handwritten {
            guard let k = pairKey(e) else { continue }
            // Newest PDF wins when two share a week.
            if let j = handwrittenByKey[k], out[j].modified >= e.modified { continue }
            handwrittenByKey[k] = i
        }
        for (i, e) in out.enumerated() where e.kind == .typed {
            guard let k = pairKey(e), let j = handwrittenByKey[k] else { continue }
            out[i].companionID = out[j].id
            out[j].companionID = e.id
        }
        return out
    }

    static func pairKey(_ e: LibraryEntry) -> String? {
        guard let m = e.moduleCode, let w = e.week else { return nil }
        return "\(m)|\(w)"
    }

    /// The outline: the backup's own folders (Divider → Subject → notes), then "Orbit Notes"
    /// (Module → typed notes and imported files). Folders first, then notes by week, then name.
    public static func tree(_ entries: [LibraryEntry], backupName: String = "Notability") -> [LibraryNode] {
        var roots: [LibraryNode] = []
        let backup = entries.filter { $0.origin == .backup }
        let orbit = entries.filter { $0.origin == .orbit }
        if !backup.isEmpty { roots.append(folder(id: "backup", name: backupName, entries: backup, depth: 0)) }
        if !orbit.isEmpty { roots.append(folder(id: "orbit", name: "Orbit Notes", entries: orbit, depth: 0)) }
        return roots
    }

    static func folder(id: String, name: String, entries: [LibraryEntry], depth: Int) -> LibraryNode {
        var files: [LibraryEntry] = []
        var sub: [String: [LibraryEntry]] = [:]
        for e in entries {
            let parts = e.relativePath.split(separator: "/").map(String.init)
            if parts.count - 1 > depth { sub[parts[depth], default: []].append(e) } else { files.append(e) }
        }
        let folders = sub.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            folder(id: id + "/" + key, name: key, entries: sub[key]!, depth: depth + 1)
        }
        let fileNodes = files.sorted(by: order).map {
            LibraryNode(id: $0.id, name: $0.title, moduleCode: $0.moduleCode, entry: $0, children: nil)
        }
        // A folder's module: the one all its files agree on.
        let modules = Set(entries.compactMap(\.moduleCode))
        return LibraryNode(id: id, name: name, moduleCode: modules.count == 1 ? modules.first : nil, entry: nil,
                           children: folders + fileNodes)
    }

    static func order(_ a: LibraryEntry, _ b: LibraryEntry) -> Bool {
        switch (a.week, b.week) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            if a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            return a.kind == .handwritten && b.kind != .handwritten
        }
    }
}

// MARK: - Typed ↔ handwritten

extension NoteMerger {
    /// One note from a handwritten page and the typed-up version of it: typed blocks are the
    /// key points (first), handwriting the lecture detail, each typed block linked to the
    /// handwriting it summarises. Keeps the handwritten note's id, title and dates.
    public func combine(handwritten: LectureNote, typed: LectureNote) -> MergedNote {
        let typedSegments = typed.segments.filter { $0.kind == .typed && !$0.text.isEmpty }
        // Text-layer typed segments from the PDF stay after the typed-up key points.
        let segments = typedSegments + handwritten.segments
        var note = handwritten
        note.segments = segments
        note.moduleCode = handwritten.moduleCode ?? typed.moduleCode
        note.week = handwritten.week ?? typed.week
        note.modified = max(handwritten.modified, typed.modified)
        let hwIndices = segments.indices.filter { segments[$0].kind != .typed }
        let regions = hwIndices.map { i in
            TranscribedRegion(regionID: "seg-\(i)", bounds: nil, segments: [segments[i]], rawText: segments[i].text,
                              engines: [], escalated: false)
        }
        let layout = segments.indices.map { i in
            NoteLayoutItem(segmentIndex: i, top: Double(i), left: nil, blockDataID: nil,
                           regionID: segments[i].kind == .typed ? nil : "seg-\(i)", imageSrc: nil)
        }
        let links = link(segments: segments, layout: layout, regions: regions, noteID: note.id)
        let low = segments.indices.filter { segments[$0].kind != .typed && segments[$0].confidence < lowConfidence }
        return MergedNote(note: note, links: links, layout: layout, handwriting: regions, lowConfidenceSegments: low)
    }
}
