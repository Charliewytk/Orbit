import XCTest
@testable import OrbitCore

final class OneNoteFolderScannerTests: XCTestCase {
    func testFindsNoteFilesSinceCursorAndReportsOneFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("orbit-scan-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("BEM2031"), withIntermediateDirectories: true)
        let old = Date(timeIntervalSince1970: 1_700_000_000), new = Date(timeIntervalSince1970: 1_760_000_000)
        func write(_ path: String, _ text: String, _ date: Date) throws {
            let url = root.appendingPathComponent(path)
            try Data(text.utf8).write(to: url)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try write("BEM2031/Week 5.md", "# Market failure\n- Externalities", new)
        try write("old.pdf", "%PDF", old)
        try write("scan.JPG", "jpg", new)
        try write("Lectures.one", "binary", new)
        try write("ignore.docx", "x", new)

        let scanner = NotesFolderScanner(root: root)
        let all = try scanner.scan()
        XCTAssertEqual(Set(all.items.map(\.relativePath)), ["BEM2031/Week 5.md", "old.pdf", "scan.JPG"])
        XCTAssertEqual(all.unsupported.map(\.lastPathComponent), ["Lectures.one"])
        XCTAssertEqual(all.cursor, new)

        let since = try scanner.scan(since: Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(since.items.map(\.kind).sorted { $0.rawValue < $1.rawValue }, [.image, .markdown])

        let md = since.items.first { $0.kind == .markdown }!
        let note = NotesFolderScanner.note(fromText: "# Market failure\n- Externalities", item: md)
        XCTAssertEqual(note.title, "Market failure")
        XCTAssertEqual(note.moduleCode, "BEM2031")
        XCTAssertEqual(note.week, 5)
        XCTAssertTrue(note.hasTyped)
    }
}
