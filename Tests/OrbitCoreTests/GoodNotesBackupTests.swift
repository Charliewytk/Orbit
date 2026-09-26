import XCTest
@testable import OrbitCore

final class GoodNotesBackupTests: XCTestCase {
    func testFindsOneDriveAndGoogleDriveFolders() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("gn-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let storage = home.appendingPathComponent("Library/CloudStorage")
        let one = storage.appendingPathComponent("OneDrive-UniversityofExeter/GoodNotes/Year 1 Economics")
        let google = storage.appendingPathComponent("GoogleDrive-charlie@gmail.com/My Drive/Goodnotes 6")
        let other = storage.appendingPathComponent("Dropbox/GoodNotes")
        for d in [one, google, other] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }

        let found = GoodNotesBackup.candidateFolders(home: home)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[0].service, .googleDrive)
        XCTAssertEqual(found[0].url.lastPathComponent, "Goodnotes 6")
        XCTAssertEqual(found[0].label, "Google Drive (charlie@gmail.com)")
        XCTAssertEqual(found[1].label, "OneDrive (University of Exeter)")
        XCTAssertEqual(found[1].url.lastPathComponent, "GoodNotes")
        XCTAssertTrue(GoodNotesBackup.isGoodNotesPath(found[1].url.path))
    }

    func testNotebookNamesMapToModules() {
        // Module names as ELE lists them (slightly different from the notebook names).
        let matcher = NotebookModuleMatcher(modules: [
            ("BEE1036", "Economics 1"), ("BEE1024", "Mathematics for Economists"),
            ("BEE1022", "Introduction to Statistics"), ("BEE1032", "History of Economic Thought"),
        ], includeDefaults: false)
        XCTAssertEqual(matcher.moduleCode(forNotebook: "Economics I"), "BEE1036")
        XCTAssertEqual(matcher.moduleCode(forNotebook: "Mathematics for Economists"), "BEE1024")
        XCTAssertEqual(matcher.moduleCode(forNotebook: "Introduction to Statistics"), "BEE1022")
        XCTAssertEqual(matcher.moduleCode(forNotebook: "Intro to Stats"), "BEE1022")
        XCTAssertEqual(matcher.moduleCode(forNotebook: "History of Economic Thought"), "BEE1032")
        XCTAssertEqual(matcher.moduleCode(forNotebook: "BEE1022 scribbles"), "BEE1022")
        XCTAssertNil(matcher.moduleCode(forNotebook: "Shopping list"))
    }

    func testDefaultsWhenELEHasNoModules() {
        let matcher = NotebookModuleMatcher(modules: [])
        XCTAssertEqual(matcher.moduleCode(forNotebook: "Economics I"), "BEE1036")
        XCTAssertEqual(matcher.moduleCode(forNotebook: "History of Economic Thought"), "BEE1032")
    }

    func testPageHeaderDate() {
        let tz = TimeZone(identifier: "Europe/London")!
        let ref = ISO8601.parse("2026-10-01T12:00:00Z")!
        let r = PageHeaderDate.parse("Week 1 Monday, 21 September 2026\nSupply and demand\n• elasticity", timeZone: tz, reference: ref)
        XCTAssertEqual(r.week, 1)
        XCTAssertEqual(r.date, DayCalendar(timeZone: tz).date(year: 2026, month: 9, day: 21))
        let none = PageHeaderDate.parse("Supply and demand\nMonday recap", timeZone: tz, reference: ref)
        XCTAssertNil(none.date)
    }
}
