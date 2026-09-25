import XCTest
@testable import OrbitCore

final class InkMLParserTests: XCTestCase {
    let px = InkMLParser.himetricToPixels

    func testOneNoteInkMLWithDifferencesBrushAndUnits() throws {
        let doc = try InkMLParser().parse(NotesFixtures.inkML)
        XCTAssertEqual(doc.strokes.map(\.id), ["st0", "st1"])
        let s0 = doc.strokes[0]
        // 3969 himetric ≈ 150 px; "'265" adds ≈ 10 px; the "\"0" keeps the same velocity.
        XCTAssertEqual(s0.points.map(\.x), [3969, 4234, 4499].map { $0 * px })
        XCTAssertEqual(s0.points.map(\.y), [3969, 3969, 3969].map { $0 * px })
        XCTAssertEqual(s0.points[0].x, 150, accuracy: 0.05)
        XCTAssertEqual(s0.brush.color, "#1F1F1F")
        XCTAssertEqual(s0.brush.width, 100 * px, accuracy: 0.001)
        XCTAssertEqual(s0.pressure!.first!, 16000.0 / 32767.0, accuracy: 0.0001)
        XCTAssertEqual(s0.pressure![2], 16200.0 / 32767.0, accuracy: 0.0001)

        // "'0'265'0": values run together without spaces.
        let s1 = doc.strokes[1]
        XCTAssertEqual(s1.points.map(\.y), [4500, 4765].map { $0 * px })
        XCTAssertEqual(s1.points.map(\.x), [3969, 3969].map { $0 * px })
    }

    func testDifferenceEncodingGrammar() {
        // explicit → first difference → second difference → explicit ("!") → sticky explicit → run-together.
        let rows = InkMLParser.decode("1000 2000 100, '10 '20 '5, \"2 \"0 \"0, !1100 !2100 !200, 1110 2110 210, '5'-5'0",
                                      channels: 3)
        XCTAssertEqual(rows, [
            [1000, 2000, 100],
            [1010, 2020, 105],
            [1022, 2040, 110],
            [1100, 2100, 200],
            [1110, 2110, 210],
            [1115, 2105, 210],
        ])
    }

    func testSecondDifferencesAccumulateVelocity() {
        // Velocity starts at 3 from the first difference, then grows by 1 each point.
        let rows = InkMLParser.decode("0 0,'3 '0,\"1\"0,\"1\"0,\"0\"0", channels: 2)
        XCTAssertEqual(rows.map { $0[0] }, [0, 3, 7, 12, 17])
        XCTAssertEqual(rows.map { $0[1] }, [0, 0, 0, 0, 0])
    }

    func testTokenizerEdgeCases() {
        let rows = InkMLParser.decode("1.5.5 -2-3, * ?", channels: 3)
        XCTAssertEqual(rows[0], [1.5, 0.5, -2])
        XCTAssertEqual(rows[1], [1.5, 0.5, -2], "* repeats and ? keeps the previous value")
    }

    func testPlainInkMLWithoutNamespacesOrDefinitions() throws {
        let xml = """
        <ink xmlns="http://www.w3.org/2003/InkML">
          <traceFormat><channel name="Y"/><channel name="X"/></traceFormat>
          <traceGroup brushRef="#b"><trace>10 20, 30 40</trace></traceGroup>
          <trace type="penUp">0 0, 1 1</trace>
        </ink>
        """
        let doc = try InkMLParser(pixelsPerUnit: 1).parse(xml)
        XCTAssertEqual(doc.strokes.count, 1)
        XCTAssertEqual(doc.strokes[0].points, [InkPoint(x: 20, y: 10), InkPoint(x: 40, y: 30)], "channel order respected")
        XCTAssertEqual(doc.bounds, InkRect(minX: 20, minY: 10, maxX: 40, maxY: 30))
    }

    func testInvalidXMLThrows() {
        XCTAssertThrowsError(try InkMLParser().parse("<ink><trace>1 2</ink>"))
    }

    // MARK: Regions

    /// A zig-zag "word" of height h at (x, y).
    static func word(_ x: Double, _ y: Double, width: Double = 40, h: Double = 16) -> InkStroke {
        var pts: [InkPoint] = []
        var cx = x
        var up = false
        while cx <= x + width { pts.append(InkPoint(x: cx, y: up ? y : y + h)); cx += 4; up.toggle() }
        return InkStroke(id: "w\(Int(x))-\(Int(y))", points: pts)
    }

    func testGroupsStrokesIntoLinesAndParagraphs() {
        var strokes: [InkStroke] = []
        // Paragraph 1: two lines.
        for x in stride(from: 50.0, through: 250, by: 50) { strokes.append(Self.word(x, 100)) }
        for x in stride(from: 50.0, through: 200, by: 50) { strokes.append(Self.word(x, 124)) }
        // A dot (i-dot) above line 1 and a tall stroke across line 2 ("l").
        strokes.append(InkStroke(id: "dot", points: [InkPoint(x: 60, y: 97)]))
        strokes.append(InkStroke(id: "tall", points: [InkPoint(x: 300, y: 118), InkPoint(x: 300, y: 142)]))
        // Paragraph 2 far below.
        for x in stride(from: 50.0, through: 150, by: 50) { strokes.append(Self.word(x, 300)) }
        // Highlighter is ignored.
        strokes.append(InkStroke(id: "hl", points: [InkPoint(x: 0, y: 200), InkPoint(x: 400, y: 200)],
                                 brush: InkBrush(color: "#FFFF00", width: 12, transparency: 0.5)))

        let regions = InkRegionGrouper().regions(from: strokes)
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0].lines.count, 2)
        XCTAssertEqual(regions[0].strokes.count, 11)
        XCTAssertTrue(regions[0].strokes.contains { $0.id == "dot" })
        XCTAssertTrue(regions[0].strokes.contains { $0.id == "tall" })
        XCTAssertEqual(regions[0].bounds.minY, 97)
        XCTAssertEqual(regions[1].lines.count, 1)
        XCTAssertEqual(regions[1].bounds.minY, 300)
        XCTAssertEqual(regions[0].lineHeight, 18, accuracy: 3)
        XCTAssertFalse(regions[0].features.looksLikeDiagram)
    }

    func testSideBySideColumnsBecomeSeparateRegions() {
        let strokes = [Self.word(0, 0), Self.word(50, 0), Self.word(600, 0), Self.word(650, 0)]
        let regions = InkRegionGrouper().regions(from: strokes)
        XCTAssertEqual(regions.count, 2)
    }

    func testDiagramFeatures() {
        // Axes and a long curve: few lines, long and tall strokes.
        let strokes = [
            InkStroke(id: "y", points: [InkPoint(x: 0, y: 0), InkPoint(x: 0, y: 200)]),
            InkStroke(id: "x", points: [InkPoint(x: 0, y: 200), InkPoint(x: 300, y: 200)]),
            InkStroke(id: "d", points: (0...30).map { InkPoint(x: Double($0) * 10, y: 20 + Double($0 * $0) / 5) }),
            Self.word(20, 210), Self.word(80, 210),
        ]
        let region = InkRegion(id: "r", strokes: strokes, lines: [InkRect(minX: 0, minY: 205, maxX: 120, maxY: 226)],
                               bounds: InkRect.union(strokes.map(\.bounds))!)
        XCTAssertTrue(region.features.looksLikeDiagram)
    }
}
