import Foundation
import AppKit
import OrbitCore

// MARK: - Notes browser: where notes come from
//
// Handwritten notes are Notability's auto-backup PDFs in Google Drive
// (charlie@… → My Drive/Notability/<Subject>/<Note>.pdf). Orbit reads them from:
//   1. the Google Drive for Desktop folder (auto-detected, or picked), else
//   2. a local mirror kept by the Drive API (drive.readonly, asked for only when turned on).
// Typed notes are rich-text .rtfd packages in ~/Documents/Orbit Notes/<Subject>/.
// Both go through the same notes pipeline into the knowledge store (which dedupes globally).

extension MacPrefs {
    /// Mirror the Notability folder through the Google Drive API.
    static let notesDriveSync = "notesDriveSync"
    /// The folder the notes scan cursor belongs to (so a new folder is read in full).
    static let notesFolderCursorPath = "notesFolderCursorPath"
}

extension OrbitBrain {
    var driveNotesCache: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Orbit/Drive/Notability", isDirectory: true)
    }

    var driveNotesSyncOn: Bool { MacPrefs.defaults.bool(forKey: MacPrefs.notesDriveSync) }

    /// The handwritten-notes folder to read: the picked folder, the auto-detected Google Drive
    /// Notability folder (replacing an old OneDrive/OneNote default), or the Drive API mirror.
    func effectiveNotesFolder() -> URL? {
        let picked = MacPrefs.string(MacPrefs.notesFolderPath)
        if let picked, !NotabilityLocator.isLegacyOneNoteDefault(picked) {
            return URL(fileURLWithPath: picked, isDirectory: true)
        }
        if let found = NotabilityLocator.preferredFolder(account: accounts.googleEmail) {
            MacPrefs.defaults.set(found.path, forKey: MacPrefs.notesFolderPath)
            MacPrefs.defaults.set("folder", forKey: MacPrefs.noteSource)
            return found
        }
        if driveNotesSyncOn { return driveNotesCache }
        return picked.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Resets the scan cursor when the folder changes, so the new folder is read in full.
    func notesCursorMatches(_ folder: URL) {
        if MacPrefs.string(MacPrefs.notesFolderCursorPath) != folder.path {
            state.notesFolderCursor = nil
            MacPrefs.defaults.set(folder.path, forKey: MacPrefs.notesFolderCursorPath)
        }
    }

    /// Picks a notes folder (Notability backup) with an open panel.
    func chooseNotesFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use this folder"
        panel.message = "Choose your Notability backup folder (Google Drive → My Drive → Notability)"
        if let found = NotabilityLocator.preferredFolder(account: accounts.googleEmail) { panel.directoryURL = found }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        MacPrefs.defaults.set(url.path, forKey: MacPrefs.notesFolderPath)
        MacPrefs.defaults.set("folder", forKey: MacPrefs.noteSource)
        await refreshLibrary()
        await syncNotes()
    }

    // MARK: Drive API mirror

    /// Turns Drive notes sync on: asks Google for read-only Drive access (incremental), then syncs.
    func enableDriveNotesSync() async {
        let scope = OAuthConfig.googleDriveReadonlyScope
        if !(await accounts.googleHasScopes([scope])) {
            guard await accounts.grantGoogle(scopes: [scope]) else {
                FeatureHub.shared.toast("Google didn't grant Drive access, so notes can't sync from Drive.")
                return
            }
        }
        MacPrefs.defaults.set(true, forKey: MacPrefs.notesDriveSync)
        MacPrefs.defaults.set("folder", forKey: MacPrefs.noteSource)
        await syncNotes()
    }

    func disableDriveNotesSync() {
        MacPrefs.defaults.set(false, forKey: MacPrefs.notesDriveSync)
    }

    /// Downloads new / changed Notability PDFs into the local mirror (only when no Drive for Desktop folder is used).
    func syncDriveNotes() async {
        guard driveNotesSyncOn, let session = accounts.google else { return }
        if let picked = MacPrefs.string(MacPrefs.notesFolderPath), !NotabilityLocator.isLegacyOneNoteDefault(picked) { return }
        let mirror = DriveNotesMirror(tokens: session, cache: driveNotesCache)
        do {
            let r = try await mirror.sync()
            OrbitLog.log("notes", "Drive notes: \(r.downloaded) downloaded, \(r.deleted) removed, \(r.failed) failed")
        } catch let e as DriveMirrorError {
            record(.notes, error: e.description)
        } catch {
            if GoogleDriveUploader.isScopeError(error) {
                record(.notes, error: "Reconnect Google to let Orbit read your Notability folder in Drive.")
            } else {
                record(.notes, error: "Drive notes: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Typed (rich) notes

    /// A new empty rich note in a subject folder; returns its URL.
    func createRichNote(subject: String, title: String = "") async -> URL? {
        let base = title.isEmpty ? "Notes \(Date().formatted(.dateTime.day().month(.abbreviated)))" : title
        let url = typedNotesStore.newRichNoteURL(subject: subject, title: base)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let heading = NSAttributedString(string: base + "\n", attributes: RichNoteStyle.heading(1))
            let body = NSAttributedString(string: "\n", attributes: RichNoteStyle.body)
            let text = NSMutableAttributedString(attributedString: heading)
            text.append(body)
            try RichNoteFile.write(text, to: url)
            await refreshLibrary()
            return url
        } catch {
            FeatureHub.shared.toast("Couldn't create the note: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Rich note files

/// Fonts for typed notes (kept here so the editor and new-note template agree).
enum RichNoteStyle {
    static let bodySize: CGFloat = 14
    static var body: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: NSColor.textColor]
    }
    static func heading(_ level: Int) -> [NSAttributedString.Key: Any] {
        let size: CGFloat = level == 1 ? 24 : level == 2 ? 19 : 16
        return [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: NSColor.textColor]
    }
    /// 1, 2, 3 for heading fonts, nil for body text.
    static func headingLevel(of font: NSFont?) -> Int? {
        guard let font, font.fontDescriptor.symbolicTraits.contains(.bold) else { return nil }
        switch font.pointSize {
        case 22...: return 1
        case 18..<22: return 2
        case 16..<18: return 3
        default: return nil
        }
    }
}

enum RichNoteFile {
    static func read(_ url: URL) -> NSAttributedString? {
        switch url.pathExtension.lowercased() {
        case "rtfd", "rtf":
            return try? NSAttributedString(url: url, options: [:], documentAttributes: nil)
        default:
            return (try? String(contentsOf: url, encoding: .utf8)).map { NSAttributedString(string: $0, attributes: RichNoteStyle.body) }
        }
    }

    static func write(_ text: NSAttributedString, to url: URL) throws {
        let range = NSRange(location: 0, length: text.length)
        if url.pathExtension.lowercased() == "rtfd" {
            let wrapper = try text.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            try wrapper.write(to: url, options: [.atomic], originalContentsURL: nil)
        } else {
            let data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try data.write(to: url, options: .atomic)
        }
    }

    /// The note as Markdown-ish text for the AI: headings as "#", list items as "- ", paragraphs apart.
    static func markdown(at url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "txt": return try? String(contentsOf: url, encoding: .utf8)
        default: return read(url).map(markdown(from:))
        }
    }

    static func markdown(from text: NSAttributedString) -> String {
        var out: [String] = []
        var inList = false
        let ns = text.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { para, range, _, _ in
            let line = (para ?? "").replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, range.length > 0 else { inList = false; return }
            let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let lists = style?.textLists ?? []
            if !lists.isEmpty {
                let indent = String(repeating: "  ", count: lists.count - 1)
                let bare = line.replacingOccurrences(of: #"^\t?[^\t]*\t"#, with: "", options: .regularExpression)
                let item = indent + "- " + (bare.isEmpty ? line : bare)
                if inList, let last = out.popLast() { out.append(last + "\n" + item) } else { out.append(item) }
                inList = true
            } else if let level = RichNoteStyle.headingLevel(of: font) {
                out.append(String(repeating: "#", count: level) + " " + line)
                inList = false
            } else {
                out.append(line)
                inList = false
            }
        }
        return out.joined(separator: "\n\n")
    }
}
