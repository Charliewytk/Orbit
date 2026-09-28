import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OrbitCore

final class NotesBrowserTests: XCTestCase {
    func entry(_ path: String, origin: LibraryEntry.Origin = .backup, week: Int? = nil, module: String? = nil) -> LibraryEntry {
        let title = ((path.split(separator: "/").last.map(String.init) ?? path) as NSString).deletingPathExtension
        return LibraryEntry(url: URL(fileURLWithPath: "/tmp/" + path), kind: origin == .backup ? .handwritten : .typed,
                            origin: origin, title: title, relativePath: path, moduleCode: module,
                            week: week ?? NoteMetadataDetector.week(in: [title]), modified: Date(), size: 1, noteID: path)
    }

    func testSubjectsMirrorNotabilityFoldersSortedByWeek() {
        let subjects = NotesBrowser.subjects([
            entry("History of Economics/Hoe week 2.pdf"),
            entry("History of Economics/Hoe week 1.pdf"),
            entry("History of Economics/Hoe week 10.pdf"),
            entry("Introduction to Statistics/Stats week 1.pdf"),
            entry("History of Economics/Tutorial.rtfd", origin: .orbit),
        ])
        XCTAssertEqual(subjects.map(\.name), ["History of Economics", "Introduction to Statistics"])
        let hoe = subjects[0]
        XCTAssertEqual(hoe.sections.count, 1)
        XCTAssertEqual(hoe.sections[0].entries.map(\.title), ["Hoe week 1", "Hoe week 2", "Hoe week 10", "Tutorial"])
        XCTAssertNil(hoe.group)
    }

    func testDividersAndSubfoldersBecomeGroupsAndSections() {
        let subjects = NotesBrowser.subjects([
            entry("Year 1/Economics 1/Micro/Week 2.pdf"),
            entry("Year 1/Economics 1/Macro/Week 1.pdf"),
            entry("Year 1/Economics 1/Overview.pdf"),
            entry("Year 1/Mathematics for Economists/Week 1.pdf"),
        ])
        XCTAssertEqual(subjects.map(\.name), ["Economics 1", "Mathematics for Economists"])
        XCTAssertEqual(subjects[0].group, "Year 1")
        XCTAssertEqual(subjects[0].sections.map(\.name), ["", "Macro", "Micro"])
    }

    func testTypedNotesJoinSubjectByModule() {
        let subjects = NotesBrowser.subjects([
            entry("Introduction to Statistics/Week 1.pdf", module: "BEE1022"),
            entry("BEE1022/Summary.rtfd", origin: .orbit, module: "BEE1022"),
            entry("Loose.pdf"),
        ])
        XCTAssertEqual(subjects.map(\.name), ["Introduction to Statistics", NotesBrowser.unfiled])
        XCTAssertEqual(subjects[0].count, 2)
    }

    func testFilterByWeek() {
        let s = NotesBrowser.subjects([entry("HoE/Hoe week 1.pdf"), entry("HoE/Hoe week 2.pdf")])[0]
        XCTAssertEqual(NotesBrowser.filter(s, query: "week 2").flatMap(\.entries).map(\.title), ["Hoe week 2"])
    }

    func testScannerTreatsRTFDPackagesAsNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-rtfd-\(UUID().uuidString)")
        let pkg = root.appendingPathComponent("Economics 1/Lecture.rtfd")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data("{\\rtf1 hi}".utf8).write(to: pkg.appendingPathComponent("TXT.rtf"))
        try Data([0x89, 0x50]).write(to: pkg.appendingPathComponent("image.png"))
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try NotesFolderScanner(root: root).scan().items
        XCTAssertEqual(items.map(\.relativePath), ["Economics 1/Lecture.rtfd"])
        XCTAssertEqual(items.first?.kind, .richText)
        let store = TypedNotesStore(root: root)
        XCTAssertEqual(store.newRichNoteURL(subject: "Economics 1", title: "Lecture").lastPathComponent, "Lecture 2.rtfd")
    }

    // MARK: Drive mirror

    func testMirrorPlanDownloadsOnlyChangesAndDeletesRemoved() {
        var manifest = DriveMirrorManifest()
        manifest.files["1"] = DriveNoteFile(id: "1", name: "Hoe week 1.pdf", path: "HoE/Hoe week 1.pdf", md5: "aaa")
        manifest.files["2"] = DriveNoteFile(id: "2", name: "Old.pdf", path: "HoE/Old.pdf", md5: "bbb")
        manifest.files["3"] = DriveNoteFile(id: "3", name: "W2.pdf", path: "HoE/W2.pdf", md5: "ccc")
        let plan = DriveMirrorPlan.make(remote: [
            DriveNoteFile(id: "1", name: "Hoe week 1.pdf", path: "HoE/Hoe week 1.pdf", md5: "aaa"),
            DriveNoteFile(id: "3", name: "W2.pdf", path: "HoE/W2.pdf", md5: "changed"),
            DriveNoteFile(id: "4", name: "New.pdf", path: "Stats/New.pdf", md5: "ddd"),
        ], manifest: manifest)
        XCTAssertEqual(plan.download.map(\.id), ["3", "4"])
        XCTAssertEqual(plan.delete, ["HoE/Old.pdf"])
    }

    func testSafePath() {
        XCTAssertEqual(DriveNotesMirror.safePath("HoE/../a:b.pdf"), "HoE/a-b.pdf")
    }

    func testMirrorSyncDownloadsIntoCache() async throws {
        let transport = NotesStubTransport()
        transport.on("name='Notability'", json: #"{"files":[{"id":"root","name":"Notability","mimeType":"application/vnd.google-apps.folder"}]}"#)
        transport.on("'root' in parents", json: #"{"files":[{"id":"f1","name":"History of Economics","mimeType":"application/vnd.google-apps.folder"}]}"#)
        transport.on("'f1' in parents", json: #"{"files":[{"id":"p1","name":"Hoe week 1.pdf","mimeType":"application/pdf","modifiedTime":"2026-09-22T10:00:00.000Z","md5Checksum":"abc","size":"3"}]}"#)
        transport.on("files/p1?alt=media", NotesStubTransport.Reply(headers: ["Content-Type": "application/pdf"], body: Data("PDF".utf8)))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-drive-\(UUID().uuidString)/Notability")
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let mirror = DriveNotesMirror(http: HTTPClient(transport: transport), tokens: StaticTokenProvider("t"), cache: cache)
        let r = try await mirror.sync()
        XCTAssertEqual(r.downloaded, 1)
        XCTAssertEqual(try String(contentsOf: cache.appendingPathComponent("History of Economics/Hoe week 1.pdf"), encoding: .utf8), "PDF")
        let again = try await mirror.sync()
        XCTAssertEqual(again.downloaded, 0)
    }

    func testLegacyOneNoteDefaultDetection() {
        XCTAssertTrue(NotabilityLocator.isLegacyOneNoteDefault("/Users/c/Library/CloudStorage/OneDrive-UniversityofExeter/OneNote Export"))
        XCTAssertFalse(NotabilityLocator.isLegacyOneNoteDefault("/Users/c/Library/CloudStorage/GoogleDrive-charlie@wuytack.net/My Drive/Notability"))
    }

    func testLocatorPrefersGoogleDriveNotability() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent("Library/CloudStorage/OneDrive-UniversityofExeter/OneNote"), withIntermediateDirectories: true)
        let nb = home.appendingPathComponent("Library/CloudStorage/GoogleDrive-charlie@wuytack.net/My Drive/Notability")
        try fm.createDirectory(at: nb, withIntermediateDirectories: true)
        XCTAssertEqual(NotabilityLocator.preferredFolder(account: "charlie@wuytack.net", home: home)?.standardizedFileURL.path,
                       nb.standardizedFileURL.path)
    }
}
