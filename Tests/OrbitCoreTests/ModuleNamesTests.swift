import XCTest
@testable import OrbitCore

final class ModuleNamesTests: XCTestCase {
    override func setUp() { ModuleNames.resetRegistry() }
    override func tearDown() { ModuleNames.resetRegistry() }

    func testOverridesForTheFourModules() {
        XCTAssertEqual(ModuleNames.title(for: "BEE1032"), "History of Economic Thought")
        XCTAssertEqual(ModuleNames.title(for: "BEE1022"), "Introduction to Statistics")
        XCTAssertEqual(ModuleNames.title(for: "BEE1024"), "Mathematics for Economists")
        XCTAssertEqual(ModuleNames.title(for: "BEE1036"), "Economics 1")
        XCTAssertEqual(ModuleNames.title(for: "bee1036"), "Economics 1")
        XCTAssertEqual(ModuleNames.title(for: "BEE1022_A_1_202627"), "Introduction to Statistics")
    }

    func testOverridesBeatELE() {
        ModuleNames.register(code: "BEE1036", courseName: "Economics I (BEE1036_A_1_202627)")
        XCTAssertEqual(ModuleNames.title(for: "BEE1036"), "Economics 1")
    }

    func testUnknownCodeFallsBackToCleanedELEName() {
        ModuleNames.register(code: "BEM2031", courseName: "BEM2031 - Business Analytics 2026/7")
        XCTAssertEqual(ModuleNames.title(for: "BEM2031"), "Business Analytics")
        ModuleNames.register(code: "ECM1400", courseName: "Programming (ECM1400_A_1_202627)")
        XCTAssertEqual(ModuleNames.title(for: "ECM1400"), "Programming")
    }

    func testUnknownCodeWithoutNameIsTheCode() {
        XCTAssertEqual(ModuleNames.title(for: "XYZ9999"), "XYZ9999")
        XCTAssertNil(ModuleNames.knownTitle(for: "XYZ9999"))
        XCTAssertEqual(ModuleNames.title(for: nil), "")
    }

    func testHumanise() {
        XCTAssertEqual(ModuleNames.humanise("Revise BEE1022 week 2"), "Revise Introduction to Statistics week 2")
        XCTAssertEqual(ModuleNames.humanise("XYZ9999 stays"), "XYZ9999 stays")
    }

    func testSymbols() {
        XCTAssertEqual(ModuleNames.symbol(for: "BEE1024"), "function")
        XCTAssertEqual(ModuleNames.symbol(for: nil), "book.closed.fill")
    }
}
