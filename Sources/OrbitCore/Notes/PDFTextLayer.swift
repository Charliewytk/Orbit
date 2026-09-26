import Foundation
#if canImport(PDFKit) && canImport(CoreGraphics) && canImport(ImageIO)
import PDFKit
import CoreGraphics
#endif

/// How one PDF page should be read.
///
/// Notability / GoodNotes exports keep typed text boxes (and sometimes text an app
/// already recognised) as a real text layer. That text is exact, so it's used as is;
/// the OCR pipeline (Apple Vision → local vision model) only runs on what the text
/// layer doesn't cover: pages with no text at all, or ink drawn outside the text.
public enum PDFPageReadPlan: String, Codable, Hashable, Sendable {
    /// The text layer covers the page: no OCR.
    case textOnly
    /// No usable text: OCR the whole page.
    case ocrPage
    /// Keep the text layer and OCR the rest of the page (text areas blanked out).
    case textPlusOCR

    public var usesOCR: Bool { self != .textOnly }
}

public enum PDFTextLayerPolicy {
    /// Words (2+ letters) needed before a text layer counts as real content.
    public static let minimumWords = 4
    /// Share of dark pixels outside the text lines above which the page has ink worth reading.
    public static let inkThreshold = 0.004

    /// The page's text when it's meaningful: not just a page number, a template
    /// header ("Week 1 Monday, 21 September 2026") or stray glyphs.
    public static func meaningfulText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        // Private-use / replacement glyphs mean a broken font mapping: the text can't be trusted.
        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        let junk = scalars.filter { $0 == "\u{FFFD}" || (0xE000...0xF8FF).contains($0.value) }.count
        if !scalars.isEmpty, Double(junk) / Double(scalars.count) > 0.2 { return nil }
        let content = text.components(separatedBy: .newlines).filter { !isBoilerplate($0) }
        let words = content.joined(separator: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 2 && $0.contains(where: \.isLetter) }
        return words.count >= minimumWords ? text : nil
    }

    /// Page numbers and date/week header lines that templates print on every page.
    static func isBoilerplate(_ line: String) -> Bool {
        let l = line.lowercased()
        if l.range(of: #"^(page\s*)?\d+(\s*(/|of)\s*\d+)?$"#, options: .regularExpression) != nil { return true }
        if l.range(of: #"^week\s*\d{1,2}\b"#, options: .regularExpression) != nil,
           l.range(of: #"(mon|tue|wed|thu|fri|sat|sun)[a-z]*,?\s+\d{1,2}\s+[a-z]+\s+20\d\d"#, options: .regularExpression) != nil
            || l.split(separator: " ").count <= 2 { return true }
        if l.range(of: #"^(mon|tue|wed|thu|fri|sat|sun)[a-z]*,?\s+\d{1,2}\s+[a-z]+(\s+20\d\d)?$"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// `inkOutsideText`: share of dark pixels on the page once the text lines are blanked
    /// out (nil when unknown, e.g. the page couldn't be rendered).
    public static func plan(text: String?, inkOutsideText: Double?) -> PDFPageReadPlan {
        guard meaningfulText(text) != nil else { return .ocrPage }
        guard let ink = inkOutsideText else { return .textPlusOCR }
        return ink >= inkThreshold ? .textPlusOCR : .textOnly
    }
}

/// One page, read: its text layer (when meaningful) and a PNG for OCR (when needed).
public struct PDFPageRead: Sendable {
    public var index: Int
    public var text: String?
    public var plan: PDFPageReadPlan
    /// What the OCR should read: the whole page, or the page with its text blanked out.
    public var ocrImage: Data?

    public init(index: Int, text: String?, plan: PDFPageReadPlan, ocrImage: Data?) {
        self.index = index; self.text = text; self.plan = plan; self.ocrImage = ocrImage
    }
}

#if canImport(PDFKit) && canImport(CoreGraphics) && canImport(ImageIO)
extension PDFPageImageSource {
    /// Text line rectangles on a page, in page space.
    func textLineRects(page index: Int) -> [CGRect] {
        guard let page = document.page(at: index), let s = page.string, !s.isEmpty,
              let all = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
        return all.selectionsByLine().map { $0.bounds(for: page) }.filter { $0.width > 1 && $0.height > 1 }
    }

    /// Reads a page the cheap way first: the text layer when it's meaningful, and a
    /// render for OCR only of what the text layer leaves out.
    public func read(page index: Int, scale: CGFloat = 2) -> PDFPageRead {
        let text = PDFTextLayerPolicy.meaningfulText(document.page(at: index)?.string)
        guard text != nil else {
            return PDFPageRead(index: index, text: nil, plan: .ocrPage, ocrImage: renderPage(index, scale: scale))
        }
        guard let masked = renderPage(index, scale: scale, blanking: textLineRects(page: index)) else {
            return PDFPageRead(index: index, text: text, plan: .textOnly, ocrImage: nil)
        }
        let plan = PDFTextLayerPolicy.plan(text: text, inkOutsideText: masked.ink)
        return PDFPageRead(index: index, text: text, plan: plan, ocrImage: plan.usesOCR ? masked.png : nil)
    }

    /// A PNG of the page with `blanking` rectangles (page space) painted white, and the
    /// share of dark pixels left. Rotated pages aren't masked (the ink share is still measured).
    func renderPage(_ index: Int, scale: CGFloat, blanking: [CGRect]) -> (png: Data, ink: Double)? {
        guard let page = document.page(at: index) else { return nil }
        let box = page.bounds(for: .mediaBox)
        let w = Int((box.width * scale).rounded(.up)), h = Int((box.height * scale).rounded(.up))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        if page.rotation % 360 == 0 {
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            for r in blanking {
                // Page space → context space (the media box origin maps to 0,0); a little padding for descenders.
                ctx.fill(r.offsetBy(dx: -box.minX, dy: -box.minY).insetBy(dx: -2, dy: -2))
            }
        }
        guard let image = ctx.makeImage(), let png = AppleImageEncoding.png(image) else { return nil }
        return (png, Self.inkShare(ctx: ctx, width: w, height: h))
    }

    /// Share of sampled pixels darker than light grey.
    static func inkShare(ctx: CGContext, width: Int, height: Int) -> Double {
        guard let data = ctx.data else { return 0 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
        let step = 3
        var dark = 0, total = 0
        var y = 0
        while y < height {
            var x = 0
            let row = y * ctx.bytesPerRow
            while x < width {
                let p = row + x * 4
                let lum = (Int(bytes[p]) * 299 + Int(bytes[p + 1]) * 587 + Int(bytes[p + 2]) * 114) / 1000
                if lum < 180 { dark += 1 }
                total += 1
                x += step
            }
            y += step
        }
        return total == 0 ? 0 : Double(dark) / Double(total)
    }
}
#endif
