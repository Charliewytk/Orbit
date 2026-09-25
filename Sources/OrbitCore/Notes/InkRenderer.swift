import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif

/// An 8-bit grayscale image (0 = black, 255 = white), row-major.
public struct GrayBitmap: Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, fill: UInt8 = 255) {
        self.width = width; self.height = height
        pixels = [UInt8](repeating: fill, count: width * height)
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Number of pixels darker than `threshold` (i.e. ink).
    public func inkPixelCount(threshold: UInt8 = 128) -> Int { pixels.lazy.filter { $0 < threshold }.count }
}

/// Renders ink strokes to a PNG that OCR engines can read: black ink on white,
/// round caps, scaled so a line of writing is about `targetLineHeight` px tall.
public struct InkRenderer: Sendable {
    public enum Backend: Sendable {
        /// CoreGraphics where available, otherwise the built-in rasteriser.
        case automatic
        /// The portable pure-Swift rasteriser (works on Linux and in tests).
        case software
    }

    public var targetLineHeight: Double
    public var padding: Int
    /// Fixed pen width in output px. nil uses each brush's width, scaled and clamped to 2…7 px.
    public var lineWidth: Double?
    /// Longest allowed side, so big drawings don't make huge images.
    public var maxDimension: Int
    public var backend: Backend

    public init(targetLineHeight: Double = 48, padding: Int = 16, lineWidth: Double? = nil,
                maxDimension: Int = 4000, backend: Backend = .automatic) {
        self.targetLineHeight = targetLineHeight; self.padding = padding; self.lineWidth = lineWidth
        self.maxDimension = maxDimension; self.backend = backend
    }

    /// The transform from page px to image px for these strokes.
    public struct Layout: Sendable, Hashable {
        public var scale: Double
        public var originX: Double
        public var originY: Double
        public var width: Int
        public var height: Int
    }

    public func layout(for strokes: [InkStroke], lineHeight: Double?) -> Layout? {
        guard let bounds = InkRect.union(strokes.filter { !$0.points.isEmpty }.map(\.bounds)) else { return nil }
        let lh = max(lineHeight ?? bounds.height, 1)
        var scale = targetLineHeight / lh
        let longest = max(bounds.width, bounds.height, 1)
        let usable = Double(maxDimension - 2 * padding)
        if longest * scale > usable { scale = usable / longest }
        let w = Int((bounds.width * scale).rounded(.up)) + 2 * padding
        let h = Int((bounds.height * scale).rounded(.up)) + 2 * padding
        return Layout(scale: scale, originX: bounds.minX, originY: bounds.minY,
                      width: min(max(w, 1), maxDimension), height: min(max(h, 1), maxDimension))
    }

    /// PNG of one region.
    public func render(_ region: InkRegion) -> Data? {
        render(region.strokes, lineHeight: region.lineHeight)
    }

    /// PNG of some strokes. `lineHeight` (page px) sets the scale; defaults to the strokes' height.
    public func render(_ strokes: [InkStroke], lineHeight: Double? = nil) -> Data? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        if backend == .automatic, let png = renderCoreGraphics(strokes, lineHeight: lineHeight) { return png }
        #endif
        return rasterize(strokes, lineHeight: lineHeight).map(PNGEncoder.encode)
    }

    func penWidth(_ stroke: InkStroke, scale: Double) -> Double {
        lineWidth ?? min(7, max(2, stroke.brush.width * scale))
    }

    /// Draws with the portable rasteriser (anti-aliased thick lines with round caps).
    public func rasterize(_ strokes: [InkStroke], lineHeight: Double? = nil) -> GrayBitmap? {
        let visible = strokes.filter { !$0.points.isEmpty && !$0.brush.isHighlighter }
        guard let L = layout(for: visible, lineHeight: lineHeight) else { return nil }
        var bmp = GrayBitmap(width: L.width, height: L.height)
        let pad = Double(padding)
        for s in visible {
            let r = penWidth(s, scale: L.scale) / 2
            let pts = s.points.map { ((($0.x - L.originX) * L.scale) + pad, (($0.y - L.originY) * L.scale) + pad) }
            if pts.count == 1 { Self.drawSegment(&bmp, pts[0], pts[0], radius: r); continue }
            for (a, b) in zip(pts, pts.dropFirst()) { Self.drawSegment(&bmp, a, b, radius: r) }
        }
        return bmp
    }

    /// Darkens pixels within `radius` of segment a–b, with a 1 px soft edge.
    static func drawSegment(_ bmp: inout GrayBitmap, _ a: (Double, Double), _ b: (Double, Double), radius r: Double) {
        let minX = max(0, Int((min(a.0, b.0) - r - 1).rounded(.down)))
        let maxX = min(bmp.width - 1, Int((max(a.0, b.0) + r + 1).rounded(.up)))
        let minY = max(0, Int((min(a.1, b.1) - r - 1).rounded(.down)))
        let maxY = min(bmp.height - 1, Int((max(a.1, b.1) + r + 1).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return }
        let dx = b.0 - a.0, dy = b.1 - a.1
        let len2 = dx * dx + dy * dy
        for y in minY...maxY {
            let py = Double(y) + 0.5
            for x in minX...maxX {
                let px = Double(x) + 0.5
                var t = len2 > 0 ? ((px - a.0) * dx + (py - a.1) * dy) / len2 : 0
                t = min(1, max(0, t))
                let d = hypot(px - (a.0 + t * dx), py - (a.1 + t * dy))
                let coverage = min(1, max(0, r + 0.5 - d))
                guard coverage > 0 else { continue }
                let value = UInt8((255 * (1 - coverage)).rounded())
                if value < bmp[x, y] { bmp[x, y] = value }
            }
        }
    }

    #if canImport(CoreGraphics) && canImport(ImageIO)
    func renderCoreGraphics(_ strokes: [InkStroke], lineHeight: Double?) -> Data? {
        let visible = strokes.filter { !$0.points.isEmpty && !$0.brush.isHighlighter }
        guard let L = layout(for: visible, lineHeight: lineHeight),
              let ctx = CGContext(data: nil, width: L.width, height: L.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: L.width, height: L.height))
        // CoreGraphics has its origin bottom-left; flip so page y grows downwards.
        ctx.translateBy(x: 0, y: CGFloat(L.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(true)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setFillColor(gray: 0, alpha: 1)
        let pad = CGFloat(padding)
        for s in visible {
            let w = CGFloat(penWidth(s, scale: L.scale))
            let pts = s.points.map {
                CGPoint(x: CGFloat(($0.x - L.originX) * L.scale) + pad, y: CGFloat(($0.y - L.originY) * L.scale) + pad)
            }
            if pts.count == 1 {
                ctx.fillEllipse(in: CGRect(x: pts[0].x - w / 2, y: pts[0].y - w / 2, width: w, height: w))
                continue
            }
            ctx.setLineWidth(w)
            ctx.beginPath()
            ctx.addLines(between: pts)
            ctx.strokePath()
        }
        guard let image = ctx.makeImage() else { return nil }
        return AppleImageEncoding.png(image)
    }
    #endif
}

#if canImport(CoreGraphics) && canImport(ImageIO)
/// PNG encoding through ImageIO (shared by ink and PDF rendering).
enum AppleImageEncoding {
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
#endif

/// A minimal PNG writer: 8-bit grayscale, zlib with stored (uncompressed) deflate blocks.
/// Files are bigger than a real compressor's but valid everywhere.
public enum PNGEncoder {
    public static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func encode(_ bmp: GrayBitmap) -> Data {
        var ihdr: [UInt8] = []
        ihdr += be32(UInt32(bmp.width)) + be32(UInt32(bmp.height))
        ihdr += [8, 0, 0, 0, 0] // bit depth 8, grayscale, deflate, no filter, no interlace
        var raw: [UInt8] = []
        raw.reserveCapacity((bmp.width + 1) * bmp.height)
        for y in 0..<bmp.height {
            raw.append(0) // filter: none
            raw += bmp.pixels[(y * bmp.width)..<((y + 1) * bmp.width)]
        }
        var out = signature
        out += chunk("IHDR", ihdr)
        out += chunk("IDAT", zlibStored(raw))
        out += chunk("IEND", [])
        return Data(out)
    }

    static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        return be32(UInt32(data.count)) + typeBytes + data + be32(crc32(typeBytes + data))
    }

    static func zlibStored(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var i = 0
        repeat {
            let n = min(65535, data.count - i)
            let final: UInt8 = i + n >= data.count ? 1 : 0
            out.append(final) // BFINAL + BTYPE=00 (stored)
            out += [UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            out += data[i..<(i + n)]
            i += n
        } while i < data.count
        return out + be32(adler32(data))
    }

    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    public static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for chunk in stride(from: 0, to: bytes.count, by: 5552) {
            for x in bytes[chunk..<min(chunk + 5552, bytes.count)] { a += UInt32(x); b += a }
            a %= 65521; b %= 65521
        }
        return (b << 16) | a
    }
}
