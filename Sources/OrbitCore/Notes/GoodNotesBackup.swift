import Foundation

// GoodNotes 6 auto-backup: GoodNotes writes each notebook as a PDF into a cloud
// folder (Settings → Auto-backup → OneDrive / Google Drive, format PDF). Those
// sync to the Mac under ~/Library/CloudStorage (OneDrive-<org>, GoogleDrive-<account>).
// Layout the student uses:
//   GoodNotes/Year 1 Economics/Economics I.pdf              → BEE1036
//   GoodNotes/Year 1 Economics/Mathematics for Economists.pdf → BEE1024
//   GoodNotes/Year 1 Economics/Introduction to Statistics.pdf → BEE1022
//   GoodNotes/Year 1 Economics/History of Economic Thought.pdf → BEE1032
// Each page becomes its own note; its date comes from the page header when the
// OCR finds one ("Week 1 Monday, 21 September 2026"), else the file's date.

/// Finds GoodNotes backup folders in OneDrive and Google Drive for Desktop.
public enum GoodNotesBackup {
    public struct Folder: Hashable, Sendable, Identifiable {
        public var url: URL
        /// "OneDrive (University of Exeter)", "Google Drive (me@gmail.com)".
        public var label: String
        public var service: Service
        public var id: String { url.path }
    }

    public enum Service: String, Sendable {
        case oneDrive, googleDrive, other
    }

    /// Every "GoodNotes" folder (any case, also "Goodnotes 6") up to three levels
    /// inside ~/Library/CloudStorage/OneDrive-* and GoogleDrive-*.
    public static func candidateFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                        fileManager: FileManager = .default) -> [Folder] {
        let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        guard let roots = try? fileManager.contentsOfDirectory(at: storage, includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: [.skipsHiddenFiles]) else { return [] }
        var out: [Folder] = []
        for root in roots.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = root.lastPathComponent
            let service: Service
            if name.hasPrefix("OneDrive") { service = .oneDrive } else if name.hasPrefix("GoogleDrive") { service = .googleDrive } else { continue }
            for folder in find(in: root, depth: 3, fileManager: fileManager) {
                out.append(Folder(url: folder, label: label(forRoot: name, service: service), service: service))
            }
        }
        return out
    }

    /// Whether a notes folder path looks like a GoodNotes backup (turns on page-by-page notes).
    public static func isGoodNotesPath(_ path: String) -> Bool {
        path.lowercased().contains("goodnotes")
    }

    static func isGoodNotesName(_ name: String) -> Bool {
        let n = name.lowercased().replacingOccurrences(of: " ", with: "")
        return n == "goodnotes" || n.hasPrefix("goodnotes")
    }

    private static func find(in dir: URL, depth: Int, fileManager: FileManager) -> [URL] {
        guard depth > 0, let children = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if isGoodNotesName(child.lastPathComponent) {
                found.append(child)
            } else {
                found += find(in: child, depth: depth - 1, fileManager: fileManager)
            }
        }
        return found
    }

    /// "OneDrive-UniversityofExeter" → "OneDrive (University of Exeter)".
    static func label(forRoot name: String, service: Service) -> String {
        let prefix = service == .oneDrive ? "OneDrive" : "GoogleDrive"
        var rest = String(name.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        if rest == "UniversityofExeter" { rest = "University of Exeter" }
        let title = service == .oneDrive ? "OneDrive" : "Google Drive"
        return rest.isEmpty ? title : "\(title) (\(rest))"
    }
}

/// Maps a notebook name ("Mathematics for Economists") to a module code by fuzzy
/// matching the module names Orbit knows from ELE.
public struct NotebookModuleMatcher: Sendable {
    public var modules: [(code: String, name: String)]

    /// Exeter Year 1 Economics notebooks, used when ELE hasn't named the modules yet.
    public static let exeterYear1Economics: [(code: String, name: String)] = [
        ("BEE1036", "Economics I"),
        ("BEE1024", "Mathematics for Economists"),
        ("BEE1022", "Introduction to Statistics"),
        ("BEE1032", "History of Economic Thought"),
    ]

    public init(modules: [(code: String, name: String)], includeDefaults: Bool = true) {
        var list = modules
        if includeDefaults {
            for d in Self.exeterYear1Economics where !list.contains(where: { $0.code == d.code }) { list.append(d) }
        }
        self.modules = list
    }

    static let stopWords: Set<String> = ["for", "of", "the", "and", "to", "in", "a", "an", "with", "module", "notes", "notebook"]
    static let synonyms: [String: String] = [
        "i": "1", "ii": "2", "iii": "3", "one": "1", "two": "2",
        "maths": "mathematics", "math": "mathematics", "stats": "statistics", "stat": "statistics",
        "intro": "introduction", "econ": "economics", "econs": "economics", "hist": "history",
        "economists": "economist", "economic": "economics", "thoughts": "thought",
    ]

    static func tokens(_ s: String) -> [String] {
        let cleaned = String(s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        return cleaned.split(separator: " ").map(String.init)
            .filter { !stopWords.contains($0) && !($0.count == 4 && Int($0) != nil) }
            .map { synonyms[$0] ?? $0 }
    }

    /// The best module for a notebook name, or nil when nothing is close.
    public func moduleCode(forNotebook notebook: String) -> String? {
        // A code in the name wins ("BEE1022 Stats").
        if let code = NoteMetadataDetector.moduleCode(in: [notebook]) { return code }
        let a = Self.tokens(notebook)
        guard !a.isEmpty else { return nil }
        var best: (code: String, score: Double)?
        for m in modules {
            let nameTokens = Self.tokens(m.name.replacingOccurrences(of: m.code, with: ""))
            guard !nameTokens.isEmpty else { continue }
            let setA = Set(a), setB = Set(nameTokens)
            let overlap = Double(setA.intersection(setB).count)
            // Dice coefficient, with a small bonus when one name contains the other in order.
            var score = 2 * overlap / Double(setA.count + setB.count)
            if a.joined(separator: " ") == nameTokens.joined(separator: " ") { score += 0.5 }
            if score > (best?.score ?? 0) { best = (m.code, score) }
        }
        guard let best, best.score >= 0.6 else { return nil }
        return best.code
    }
}

/// Reads the header GoodNotes page templates print ("Week 1 Monday, 21 September 2026").
public enum PageHeaderDate {
    public struct Result: Hashable, Sendable {
        public var date: Date?
        public var week: Int?
    }

    /// Looks at the first few lines of a page's text (typed or OCR).
    public static func parse(_ text: String, timeZone: TimeZone, reference: Date) -> Result {
        let head = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(4)
            .joined(separator: "\n")
        guard !head.isEmpty else { return Result(date: nil, week: nil) }
        let week = NoteMetadataDetector.week(in: [head])
        // Only full dates with a year or a month name count; a lone weekday isn't enough.
        let matches = DateExtractor(now: reference, timeZone: timeZone).extract(from: head)
            .filter { m in
                let t = m.text.lowercased()
                return m.periodEnd == nil && (t.rangeOfCharacter(from: .decimalDigits) != nil)
                    && (t.range(of: "20[0-9]{2}", options: .regularExpression) != nil
                        || ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].contains { t.contains($0) })
            }
        return Result(date: matches.first?.date, week: week)
    }
}
