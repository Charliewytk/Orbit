import AppKit
import CoreText
import Foundation

/// Renders Orbit's simple Markdown (#, ##, _italic_, - bullets, paragraphs) to an A4 PDF with Core Text.
enum PracticePDF {
    static let page = CGRect(x: 0, y: 0, width: 595, height: 842)

    static func attributed(_ markdown: String, answerSpace: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 11.5)
        func para(_ spacingBefore: CGFloat, _ after: CGFloat) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = spacingBefore
            p.paragraphSpacing = after
            p.lineSpacing = 2
            return p
        }
        var firstQuestion = true
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            var text = line
            var attrs: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.black, .paragraphStyle: para(0, 4)]
            if line.hasPrefix("# ") {
                text = String(line.dropFirst(2))
                attrs[.font] = NSFont.boldSystemFont(ofSize: 18)
                attrs[.paragraphStyle] = para(0, 10)
            } else if line.hasPrefix("## ") {
                text = String(line.dropFirst(3))
                attrs[.font] = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
                // Room to write under each question (for Notability / pen).
                attrs[.paragraphStyle] = para(answerSpace && !firstQuestion ? 150 : 12, 6)
                if text.hasPrefix("Question") { firstQuestion = false }
            } else if line.hasPrefix("_"), line.hasSuffix("_"), line.count > 2 {
                text = String(line.dropFirst().dropLast())
                attrs[.font] = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 9.5), toHaveTrait: .italicFontMask)
                attrs[.foregroundColor] = NSColor.darkGray
            } else if line.hasPrefix("- ") {
                text = "•  " + line.dropFirst(2)
            } else if line.isEmpty {
                continue
            }
            out.append(NSAttributedString(string: text + "\n", attributes: attrs))
        }
        return out
    }

    static func render(_ markdown: String, answerSpace: Bool = false) -> Data {
        let text = attributed(markdown, answerSpace: answerSpace)
        let data = NSMutableData()
        var box = page
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        var start = 0
        let length = text.length
        var pageNumber = 1
        repeat {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: page.insetBy(dx: 56, dy: 64), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let footer = NSAttributedString(string: "Orbit · page \(pageNumber)",
                                            attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.gray])
            ctx.textPosition = CGPoint(x: 56, y: 30)
            CTLineDraw(CTLineCreateWithAttributedString(footer as CFAttributedString), ctx)
            ctx.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            start += visible.length
            pageNumber += 1
        } while start < length && pageNumber < 200
        ctx.closePDF()
        return data as Data
    }
}
