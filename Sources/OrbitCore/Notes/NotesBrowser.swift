import Foundation

// MARK: - Notability-style browser: Subjects → Sections → Notes
//
// Mirrors the Notability auto-backup layout on Google Drive:
//
//   Notability/<Divider?>/<Subject>/<Section…?>/<Note>.pdf     (handwritten)
//   Orbit Notes/<Subject>/<Section…?>/<Note>.rtfd | .md          (typed in Orbit)
//
// A top-level backup folder that only holds folders is a divider ("Year 1"); otherwise it
// is the subject itself. Typed notes join the handwritten subject with the same name (or
// the same module). Notes in a section are sorted by week, then name.

public struct NoteSection: Identifiable, Hashable, Sendable {
    /// "" for notes directly in the subject folder.
    public var name: String
    public var entries: [LibraryEntry]
    public var subjectID: String
    public var id: String { subjectID + "§" + name }
}

public struct NoteSubject: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// The divider the subject sits under in Notability, if any.
    public var group: String?
    public var moduleCode: String?
    public var sections: [NoteSection]

    public var entries: [LibraryEntry] { sections.flatMap(\.entries) }
    public var count: Int { sections.reduce(0) { $0 + $1.entries.count } }
    public var latest: Date? { entries.map(\.modified).max() }
}

public enum NotesBrowser {
    public static let unfiled = "Unfiled"

    /// Where one entry sits: its subject's divider and name, and its section.
    public struct Placement: Hashable, Sendable {
        public var group: String?
        public var subject: String
        public var section: String
    }

    public static func subjects(_ entries: [LibraryEntry]) -> [NoteSubject] {
        let dividers = self.dividers(entries.filter { $0.origin == .backup })
        var bySubject: [String: (subject: NoteSubject, sections: [String: [LibraryEntry]])] = [:]
        var order: [String] = []

        func key(for p: Placement, module: String?) -> String {
            let k = p.subject.lowercased()
            if bySubject[k] != nil { return k }
            // A typed folder named after the module code, or a slightly different name, joins by module.
            if let module, let match = order.first(where: { bySubject[$0]?.subject.moduleCode == module }) { return match }
            return k
        }

        // Handwritten first so their names and dividers win; typed notes join them.
        let sorted = entries.filter { $0.origin == .backup } + entries.filter { $0.origin != .backup }
        for e in sorted {
            let p = placement(e, dividers: dividers)
            let k = key(for: p, module: e.moduleCode)
            if bySubject[k] == nil {
                bySubject[k] = (NoteSubject(id: "subject:" + k, name: p.subject, group: p.group, moduleCode: e.moduleCode, sections: []), [:])
                order.append(k)
            }
            if bySubject[k]!.subject.moduleCode == nil { bySubject[k]!.subject.moduleCode = e.moduleCode }
            bySubject[k]!.sections[p.section, default: []].append(e)
        }

        return order.compactMap { k -> NoteSubject? in
            guard var (subject, sections) = bySubject[k] else { return nil }
            subject.sections = sections.keys.sorted(by: sectionOrder).map { name in
                NoteSection(name: name, entries: sections[name]!.sorted(by: NotesLibrary.order), subjectID: subject.id)
            }
            return subject
        }.sorted { a, b in
            if (a.name == unfiled) != (b.name == unfiled) { return b.name == unfiled }
            let ga = a.group ?? "", gb = b.group ?? ""
            if ga != gb { return ga.localizedStandardCompare(gb) == .orderedAscending }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    public static func placement(_ e: LibraryEntry, dividers: Set<String>) -> Placement {
        let folders = e.relativePath.split(separator: "/").dropLast().map(String.init)
        guard let first = folders.first else { return Placement(group: nil, subject: unfiled, section: "") }
        if e.origin == .backup, dividers.contains(first), folders.count >= 2 {
            return Placement(group: first, subject: folders[1], section: folders.dropFirst(2).joined(separator: " / "))
        }
        return Placement(group: nil, subject: first, section: folders.dropFirst().joined(separator: " / "))
    }

    /// Top-level backup folders that contain only folders (never a note directly).
    public static func dividers(_ backup: [LibraryEntry]) -> Set<String> {
        var depthOK: [String: Bool] = [:]
        for e in backup {
            let folders = e.relativePath.split(separator: "/").dropLast()
            guard let first = folders.first.map(String.init) else { continue }
            depthOK[first] = (depthOK[first] ?? true) && folders.count >= 2
        }
        return Set(depthOK.filter(\.value).keys)
    }

    static func sectionOrder(_ a: String, _ b: String) -> Bool {
        if a.isEmpty != b.isEmpty { return a.isEmpty }
        if let wa = NoteMetadataDetector.week(in: [a]), let wb = NoteMetadataDetector.week(in: [b]), wa != wb { return wa < wb }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    /// Notes matching a filter ("week 3", "hoe", …) by title, section and week.
    public static func filter(_ subject: NoteSubject, query: String) -> [NoteSection] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return subject.sections }
        let week = NoteMetadataDetector.week(in: [q])
        return subject.sections.compactMap { s in
            let hits = s.entries.filter { e in
                e.title.lowercased().contains(q) || s.name.lowercased().contains(q) || (week != nil && e.week == week)
            }
            return hits.isEmpty ? nil : NoteSection(name: s.name, entries: hits, subjectID: s.subjectID)
        }
    }
}
