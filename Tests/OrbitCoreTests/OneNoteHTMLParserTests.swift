import XCTest
@testable import OrbitCore

final class OneNoteHTMLParserTests: XCTestCase {
    func testParsesBlocksPositionsAndMetadata() throws {
        let doc = OneNoteHTMLParser.parse(NotesFixtures.pageHTML)
        XCTAssertEqual(doc.title, "BEM2031 Week 5 – Market failure")
        XCTAssertEqual(doc.created, ISO8601.parse("2025-10-14T09:05:00Z"))

        let kinds = doc.blocks.map(\.kind)
        XCTAssertEqual(kinds, [.text, .image, .text, .attachment])

        let key = doc.blocks[0]
        XCTAssertEqual(key.top, 620)
        XCTAssertEqual(key.left, 48)
        XCTAssertEqual(key.width, 600)
        XCTAssertEqual(key.dataID, "keypts")
        XCTAssertEqual(key.text, """
        ## Key points
        - Externalities cause market failure
        - Pigouvian tax corrects negative externalities
        ☐ Read Ch. 4
        Merit goods & public goods are under-provided
        Type | Example
        Negative | Pollution
        """)

        let img = doc.blocks[1]
        XCTAssertEqual(img.top, 620)
        XCTAssertEqual(img.text, "Supply and demand graph")
        XCTAssertEqual(img.mimeType, "image/png")
        XCTAssertTrue(img.fullResolutionSrc!.contains("0-imgfull"))
        XCTAssertEqual(img.width, 300)

        let heading = doc.blocks[2]
        XCTAssertEqual(heading.text, "Lecture 5")
        XCTAssertEqual(heading.top!, 40 * 4 / 3, accuracy: 0.01)

        XCTAssertEqual(doc.blocks[3].text, "slides.pdf")
        XCTAssertEqual(doc.blocks[3].top, 40)
        XCTAssertFalse(doc.typedText.contains("ignored"))
    }

    func testOrderedListsAndNestedLists() {
        let html = "<body><ol><li>One</li><li>Two<ul><li>Sub</li></ul></li></ol><p>a<br/>b</p></body>"
        XCTAssertEqual(OneNoteHTMLParser.parse(html).typedText, "1. One\n2. Two\n  - Sub\na\nb")
    }

    func testInkPlaceholder() {
        let html = #"<body><div style="position:absolute;left:10px;top:300px" data-ink-id="x"></div></body>"#
        let doc = OneNoteHTMLParser.parse(html)
        XCTAssertEqual(doc.blocks.map(\.kind), [.ink])
        XCTAssertEqual(doc.blocks[0].top, 300)
    }

    func testModuleCodeAndWeekDetection() {
        XCTAssertEqual(NoteMetadataDetector.moduleCode(in: ["Lecture 3", "bem2031 Economics"]), "BEM2031")
        XCTAssertEqual(NoteMetadataDetector.moduleCode(in: [nil, "ECM 1400 Programming"]), "ECM1400")
        XCTAssertNil(NoteMetadataDetector.moduleCode(in: ["Week 5", "2025"]))
        XCTAssertEqual(NoteMetadataDetector.week(in: ["Week 5 – Market failure"]), 5)
        XCTAssertEqual(NoteMetadataDetector.week(in: ["Wk5 notes"]), 5)
        XCTAssertEqual(NoteMetadataDetector.week(in: ["BEM2031 W11"]), 11)
        XCTAssertEqual(NoteMetadataDetector.week(in: ["week-05"]), 5)
        XCTAssertNil(NoteMetadataDetector.week(in: ["Weekly reading", "Wave 5 of 2025"]))
    }

    func testEntitiesAndStyleUnits() {
        XCTAssertEqual(HTMLTokenizer.decodeEntities("a &lt;b&gt; &#x2192; &#8364; &pound;5 &unknown;"), "a <b> → € £5 &unknown;")
        let p = OneNoteHTMLParser.position(fromStyle: "position:absolute; LEFT: 72pt; top:1in; width:10mm")
        XCTAssertEqual(p.left, 96)
        XCTAssertEqual(p.top, 96)
        XCTAssertEqual(p.width!, 37.795, accuracy: 0.01)
    }
}
