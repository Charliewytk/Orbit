import XCTest
@testable import OrbitCore

final class NotesLibraryTests: XCTestCase {
    var tmp: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() { try? fm.removeItem(at: tmp) }

    func testCreatesTypedNoteWithTitleAndMarker() throws {
        let store = TypedNotesStore(root: tmp.appendingPathComponent("Orbit Notes"))
        let url = try store.create(moduleCode: "BEE1022", moduleName: "Introduction to Statistics", week: 1)
        XCTAssertEqual(url.lastPathComponent, "Week 1.md")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Introduction to Statistics")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# Week 1 — Introduction to Statistics\n"))
        XCTAssertEqual(TypedNotesStore.marker(in: text).module, "BEE1022")
        XCTAssertEqual(TypedNotesStore.marker(in: text).week, 1)
        // Creating again leaves the student's text alone.
        try (text + "Population = everything\n").write(to: url, atomically: true, encoding: .utf8)
        _ = try store.create(moduleCode: "BEE1022", moduleName: "Introduction to Statistics", week: 1)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("Population"))
    }

    func testFolderNamesAreSafe() {
        XCTAssertEqual(TypedNotesStore.folderName(moduleCode: "BEE1022", moduleName: "Stats: Part 1/2"), "Stats- Part 1-2")
        XCTAssertEqual(TypedNotesStore.folderName(moduleCode: "BEE1022", moduleName: nil), "BEE1022")
        XCTAssertEqual(TypedNotesStore.folderName(moduleCode: nil, moduleName: "  "), "Other")
    }

    func testTypedMarkdownBecomesKeyPoints() {
        let md = """
        # Week 1 — Introduction to Statistics

        <!-- orbit: module=BEE1022 week=1 -->

        - Population = everything we care about
        - Sample = the part we measure

        Homework: read chapter 1
        """
        let note = TypedNotesStore.note(markdown: md, relativePath: "Introduction to Statistics/Week 1.md", modified: Date(),
                                        matcher: NotebookModuleMatcher(modules: []))
        XCTAssertEqual(note.id, "typed:Introduction to Statistics/Week 1.md")
        XCTAssertEqual(note.title, "Week 1 — Introduction to Statistics")
        XCTAssertEqual(note.moduleCode, "BEE1022")
        XCTAssertEqual(note.week, 1)
        XCTAssertEqual(note.segments.count, 2)
        XCTAssertTrue(note.segments.allSatisfy { $0.kind == .typed })
        XCTAssertFalse(note.allText.contains("orbit:"))
    }

    func testImportAvoidsOverwriting() throws {
        let store = TypedNotesStore(root: tmp.appendingPathComponent("Orbit Notes"))
        let src = tmp.appendingPathComponent("Slides.pdf")
        try Data("x".utf8).write(to: src)
        let a = try store.importFile(src, moduleCode: "BEE1022", moduleName: "Introduction to Statistics")
        let b = try store.importFile(src, moduleCode: "BEE1022", moduleName: "Introduction to Statistics")
        XCTAssertEqual(a.lastPathComponent, "Slides.pdf")
        XCTAssertEqual(b.lastPathComponent, "Slides 2.pdf")
    }

    func testLibraryMirrorsBackupAndPairsTypedNotes() throws {
        let backup = tmp.appendingPathComponent("Notability")
        let stats = backup.appendingPathComponent("Year 1 Economics/Introduction to Statistics")
        let maths = backup.appendingPathComponent("Year 1 Economics/Mathematics for Economists")
        for d in [stats, maths] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        for (dir, name) in [(stats, "Week 2.pdf"), (stats, "Week 1.pdf"), (maths, "Week 1.pdf")] {
            try Data("%PDF".utf8).write(to: dir.appendingPathComponent(name))
        }
        let typedRoot = tmp.appendingPathComponent("Orbit Notes")
        let store = TypedNotesStore(root: typedRoot)
        try store.create(moduleCode: "BEE1022", moduleName: "Introduction to Statistics", week: 1)
        let src = tmp.appendingPathComponent("handout.pdf")
        try Data("%PDF".utf8).write(to: src)
        try store.importFile(src, moduleCode: "BEE1022", moduleName: "Introduction to Statistics")

        let entries = NotesLibrary.entries(backupRoot: backup, typedRoot: typedRoot, matcher: NotebookModuleMatcher(modules: []))
        XCTAssertEqual(entries.count, 5)
        let hw1 = entries.first { $0.kind == .handwritten && $0.moduleCode == "BEE1022" && $0.week == 1 }!
        let typed = entries.first { $0.kind == .typed }!
        XCTAssertEqual(typed.moduleCode, "BEE1022")
        XCTAssertEqual(typed.week, 1)
        XCTAssertEqual(hw1.companionID, typed.id)
        XCTAssertEqual(typed.companionID, hw1.id)
        XCTAssertEqual(hw1.noteID, "file:Year 1 Economics/Introduction to Statistics/Week 1.pdf")
        XCTAssertEqual(entries.first { $0.kind == .imported }?.moduleCode, "BEE1022")

        let tree = NotesLibrary.tree(entries)
        XCTAssertEqual(tree.map(\.name), ["Notability", "Orbit Notes"])
        let divider = tree[0].children![0]
        XCTAssertEqual(divider.name, "Year 1 Economics")
        XCTAssertEqual(divider.children!.map(\.name), ["Introduction to Statistics", "Mathematics for Economists"])
        let subject = divider.children![0]
        XCTAssertEqual(subject.moduleCode, "BEE1022")
        XCTAssertEqual(subject.children!.map(\.name), ["Week 1", "Week 2"])
        XCTAssertNil(subject.children![0].children)
        XCTAssertEqual(tree[1].children!.map(\.name), ["Introduction to Statistics"])
        XCTAssertEqual(tree[1].allEntries.count, 2)
    }

    func testTypedNoteCombinesWithHandwriting() {
        let hw = LectureNote(id: "file:Stats/Week 1.pdf", title: "Week 1", moduleCode: "BEE1022", week: 1,
                             segments: [NoteSegment(kind: .handwriting, text: "Population = everything\nSample is part of population", confidence: 0.7)])
        let typed = LectureNote(id: "typed:Stats/Week 1.md", title: "Week 1 — Stats", moduleCode: "BEE1022", week: 1,
                                segments: [NoteSegment(kind: .typed, text: "Population = everything")])
        let merged = NoteMerger().combine(handwritten: hw, typed: typed)
        XCTAssertEqual(merged.note.id, hw.id)
        XCTAssertEqual(merged.note.segments.map(\.kind), [.typed, .handwriting])
        XCTAssertEqual(merged.note.keyPoints, "Population = everything")
        XCTAssertEqual(merged.links.handwriting(forTyped: 0), [1])
    }
}

/// The student's real Notability layout: subject folders at the top level (no divider),
/// notes named like "Hoe week 1".
final class NotabilityRealLayoutTests: XCTestCase {
    let eleNames = NotebookModuleMatcher(modules: [
        ("BEE1036", "Economics I"), ("BEE1024", "Mathematics for Economists"),
        ("BEE1022", "Introduction to Statistics"), ("BEE1032", "History of Economic Thought"),
    ], includeDefaults: false)

    func testFolderNamesMapToModules() {
        for m in [eleNames, NotebookModuleMatcher(modules: [])] {
            XCTAssertEqual(m.moduleCode(forNotebook: "History of Economics"), "BEE1032")
            XCTAssertEqual(m.moduleCode(forNotebook: "HoE"), "BEE1032")
            XCTAssertEqual(m.moduleCode(forNotebook: "HET"), "BEE1032")
            XCTAssertEqual(m.moduleCode(forNotebook: "Economics 1"), "BEE1036")
            XCTAssertEqual(m.moduleCode(forNotebook: "Econ 1"), "BEE1036")
            XCTAssertEqual(m.moduleCode(forNotebook: "Maths for Economists"), "BEE1024")
            XCTAssertEqual(m.moduleCode(forNotebook: "Mathematics for Economists"), "BEE1024")
            XCTAssertEqual(m.moduleCode(forNotebook: "Maths"), "BEE1024")
            XCTAssertEqual(m.moduleCode(forNotebook: "Introduction to Statistics"), "BEE1022")
            XCTAssertEqual(m.moduleCode(forNotebook: "Intro to Stats"), "BEE1022")
            XCTAssertEqual(m.moduleCode(forNotebook: "Intro to Statistic"), "BEE1022")
        }
    }

    func testNotesInTopLevelSubjectFolders() {
        let m = NotabilityNote.metadata(relativePath: "History of Economics/Hoe week 1.pdf", matcher: eleNames)
        XCTAssertEqual(m.title, "Hoe week 1")
        XCTAssertEqual(m.subject, "History of Economics")
        XCTAssertEqual(m.moduleCode, "BEE1032")
        XCTAssertEqual(m.week, 1)
        XCTAssertEqual(NotabilityNote.metadata(relativePath: "Economics 1/Econ week 3.pdf", matcher: eleNames).moduleCode, "BEE1036")
        XCTAssertEqual(NotabilityNote.metadata(relativePath: "Economics 1/Econ week 3.pdf", matcher: eleNames).week, 3)
        XCTAssertEqual(NotabilityNote.metadata(relativePath: "Mathematics for Economists/Maths wk2.pdf", matcher: eleNames).week, 2)
        XCTAssertEqual(NotabilityNote.metadata(relativePath: "Introduction to Statistics/Week 1.pdf", matcher: eleNames).moduleCode, "BEE1022")
        // A loose note at the top level still finds its module from the title.
        let loose = NotabilityNote.metadata(relativePath: "Hoe week 4.pdf", matcher: eleNames)
        XCTAssertEqual(loose.moduleCode, "BEE1032")
        XCTAssertEqual(loose.week, 4)
    }

    func testLibraryTreeWithoutDivider() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nb-\(UUID().uuidString)/Notability")
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        for (folder, file) in [("History of Economics", "Hoe week 1.pdf"), ("Introduction to Statistics", "Week 1.pdf"),
                               ("Mathematics for Economists", "Week 1.pdf"), ("Economics 1", "Week 1.pdf")] {
            let dir = root.appendingPathComponent(folder)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("%PDF".utf8).write(to: dir.appendingPathComponent(file))
        }
        let entries = NotesLibrary.entries(backupRoot: root, typedRoot: nil, matcher: eleNames)
        let tree = NotesLibrary.tree(entries)
        XCTAssertEqual(tree[0].children!.map(\.name),
                       ["Economics 1", "History of Economics", "Introduction to Statistics", "Mathematics for Economists"])
        XCTAssertEqual(tree[0].children!.map { $0.moduleCode ?? "-" }, ["BEE1036", "BEE1032", "BEE1022", "BEE1024"])
        XCTAssertEqual(entries.first { $0.title == "Hoe week 1" }?.week, 1)
    }
}
