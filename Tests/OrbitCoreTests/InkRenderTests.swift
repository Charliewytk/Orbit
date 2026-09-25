import XCTest
@testable import OrbitCore

final class InkRenderTests: XCTestCase {
    func sampleRegion() -> InkRegion {
        let strokes = [InkMLParserTests.word(10, 10), InkMLParserTests.word(60, 10),
                       InkStroke(id: "dot", points: [InkPoint(x: 120, y: 12)])]
        return InkRegionGrouper().regions(from: strokes)[0]
    }

    func testRasteriserDrawsScaledInk() throws {
        let region = sampleRegion()
        let renderer = InkRenderer(targetLineHeight: 48, padding: 16, backend: .software)
        let bmp = try XCTUnwrap(renderer.rasterize(region.strokes, lineHeight: region.lineHeight))
        let scale = 48 / region.lineHeight
        XCTAssertEqual(Double(bmp.height), region.bounds.height * scale + 32, accuracy: 2)
        XCTAssertGreaterThan(bmp.inkPixelCount(), 300)
        // Padding stays white; the corner is untouched.
        XCTAssertEqual(bmp[0, 0], 255)
        XCTAssertLessThan(bmp.pixels.min()!, 10, "stroke centres are black")
        XCTAssertTrue(bmp.pixels.contains { $0 > 10 && $0 < 245 }, "edges are anti-aliased")
    }

    func testPNGIsValid() throws {
        let region = sampleRegion()
        let renderer = InkRenderer(backend: .software)
        let png = try XCTUnwrap(renderer.render(region))
        let bytes = [UInt8](png)
        XCTAssertEqual(Array(bytes.prefix(8)), PNGEncoder.signature)

        // Walk the chunks, checking each CRC, and inflate the stored IDAT.
        var i = 8
        var types: [String] = []
        var idat: [UInt8] = []
        var width = 0, height = 0
        while i < bytes.count {
            let len = Int(be32(bytes, i))
            let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
            let data = Array(bytes[(i + 8)..<(i + 8 + len)])
            XCTAssertEqual(be32(bytes, i + 8 + len), PNGEncoder.crc32(Array(bytes[(i + 4)..<(i + 8)]) + data), "CRC of \(type)")
            if type == "IHDR" { width = Int(be32(data, 0)); height = Int(be32(data, 4)); XCTAssertEqual(Array(data[8...]), [8, 0, 0, 0, 0]) }
            if type == "IDAT" { idat += data }
            types.append(type)
            i += 12 + len
        }
        XCTAssertEqual(types.first, "IHDR")
        XCTAssertEqual(types.last, "IEND")

        let raw = inflateStored(idat)
        XCTAssertEqual(raw.count, (width + 1) * height)
        XCTAssertEqual(be32(Array(idat.suffix(4)), 0), PNGEncoder.adler32(raw))
        let bmp = renderer.rasterize(region.strokes, lineHeight: region.lineHeight)!
        XCTAssertEqual(width, bmp.width)
        let pixels = (0..<height).flatMap { y in raw[(y * (width + 1) + 1)..<((y + 1) * (width + 1))] }
        XCTAssertEqual(pixels, bmp.pixels)
    }

    func testLargeImagesUseSeveralStoredBlocks() {
        var bmp = GrayBitmap(width: 400, height: 300)
        bmp[10, 10] = 0
        let png = [UInt8](PNGEncoder.encode(bmp))
        XCTAssertGreaterThan(png.count, 400 * 300)
        XCTAssertEqual(PNGEncoder.adler32(Array("Wikipedia".utf8)), 0x11E60398)
        XCTAssertEqual(PNGEncoder.crc32(Array("123456789".utf8)), 0xCBF43926)
    }

    func testRenderLinesAndClampedSize() {
        let strokes = [InkMLParserTests.word(0, 0), InkMLParserTests.word(0, 30)]
        let region = InkRegionGrouper().regions(from: strokes)[0]
        XCTAssertEqual(region.lines.count, 2)
        XCTAssertEqual(InkRenderer(backend: .software).renderLines(region).count, 2)
        let huge = InkRenderer(targetLineHeight: 48, maxDimension: 500, backend: .software)
            .layout(for: [InkStroke(id: "l", points: [InkPoint(x: 0, y: 0), InkPoint(x: 5000, y: 10)])], lineHeight: 10)!
        XCTAssertLessThanOrEqual(huge.width, 500)
    }

    // MARK: Helpers

    func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    /// Inflates a zlib stream made only of stored blocks.
    func inflateStored(_ z: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 2
        while true {
            let final = z[i] & 1
            XCTAssertEqual((z[i] >> 1) & 3, 0, "stored block")
            let len = Int(z[i + 1]) | Int(z[i + 2]) << 8
            let nlen = Int(z[i + 3]) | Int(z[i + 4]) << 8
            XCTAssertEqual(len ^ 0xFFFF, nlen)
            out += z[(i + 5)..<(i + 5 + len)]
            i += 5 + len
            if final == 1 { break }
        }
        return out
    }
}
