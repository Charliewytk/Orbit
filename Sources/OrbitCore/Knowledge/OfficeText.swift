import Foundation

/// One slide's text.
public struct SlideText: Codable, Hashable, Sendable {
    public var number: Int
    public var title: String
    /// Body paragraphs (bullets, tables, text boxes), title excluded.
    public var lines: [String]
    /// Speaker notes.
    public var notes: String

    public init(number: Int, title: String, lines: [String] = [], notes: String = "") {
        self.number = number; self.title = title; self.lines = lines; self.notes = notes
    }

    public var body: String { lines.joined(separator: "\n") }
}

/// A deck (PowerPoint or a PDF of slides) as text.
public struct SlideDeckText: Codable, Hashable, Sendable {
    public var slides: [SlideText]
    public init(slides: [SlideText]) { self.slides = slides }

    /// "# Slide 3: Sampling distributions\n• …\nNotes: …" per slide, the format the
    /// knowledge base indexes (the heading carries the slide number into citations).
    public var text: String {
        slides.map { s in
            var out = "# Slide \(s.number)" + (s.title.isEmpty ? "" : ": \(s.title)")
            if !s.lines.isEmpty { out += "\n" + s.body }
            if !s.notes.isEmpty { out += "\nNotes: " + s.notes }
            return out
        }.joined(separator: "\n\n")
    }

    /// Reads text in the `text` format back into slides. Text without slide headings
    /// (a PDF, a handout) is split on form feeds, or kept as one slide.
    public static func parse(_ text: String) -> SlideDeckText {
        let lines = text.components(separatedBy: .newlines)
        var slides: [SlideText] = []
        var current: SlideText?
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let m = UniRegex.first("^#\\s*(?:slide|page)\\s*(\\d+)\\s*(?::\\s*(.*))?$", in: line), let n = m[1].flatMap(Int.init) {
                if let c = current { slides.append(c) }
                current = SlideText(number: n, title: (m[2] ?? "").trimmingCharacters(in: .whitespaces))
                continue
            }
            guard !line.isEmpty else { continue }
            if current == nil { current = SlideText(number: 1, title: "") }
            if line.hasPrefix("Notes: ") {
                current?.notes += (current!.notes.isEmpty ? "" : " ") + String(line.dropFirst(7))
            } else {
                current?.lines.append(line)
            }
        }
        if let c = current { slides.append(c) }
        if slides.count == 1, slides[0].title.isEmpty, text.contains("\u{0C}") {
            let pages = text.components(separatedBy: "\u{0C}")
            slides = pages.enumerated().compactMap { i, p in
                let ls = p.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard let first = ls.first else { return nil }
                return SlideText(number: i + 1, title: first, lines: Array(ls.dropFirst()))
            }
        }
        return SlideDeckText(slides: slides)
    }

    /// PDF pages (one string per page) as slides: the first short line is the title.
    public static func fromPages(_ pages: [String]) -> SlideDeckText {
        SlideDeckText(slides: pages.enumerated().compactMap { i, p in
            let ls = p.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !ls.isEmpty else { return nil }
            let titleIndex = ls.firstIndex { $0.count <= 90 } ?? 0
            var rest = ls
            let title = rest.remove(at: titleIndex)
            return SlideText(number: i + 1, title: title, lines: rest)
        })
    }
}

/// Text out of PowerPoint XML. The Mac app unzips `ppt/slides/slideN.xml` (and
/// `ppt/notesSlides/notesSlideN.xml`) with /usr/bin/unzip; this part is pure.
public enum PPTXText {
    /// Slide XML files in slide order ("slide10.xml" after "slide9.xml").
    public static func orderedSlidePaths(_ paths: [String], folder: String = "ppt/slides/", prefix: String = "slide") -> [String] {
        paths.filter { $0.hasPrefix(folder) && !$0.dropFirst(folder.count).contains("/") && $0.hasSuffix(".xml")
            && $0.dropFirst(folder.count).hasPrefix(prefix) }
            .sorted { number(in: $0) < number(in: $1) }
    }

    static func number(in path: String) -> Int {
        UniRegex.first("(\\d+)\\.xml$", in: path)?[1].flatMap(Int.init) ?? Int.max
    }

    /// Decks from slide XML in order, with optional notes XML (same order; nil where a slide has none).
    public static func extract(slideXMLs: [String], notesXMLs: [String?] = []) -> SlideDeckText {
        var slides: [SlideText] = []
        for (i, xml) in slideXMLs.enumerated() {
            let shapes = self.shapes(in: xml)
            var title = ""
            var lines: [String] = []
            for shape in shapes {
                let paragraphs = self.paragraphs(in: shape.xml)
                if title.isEmpty, shape.placeholder == "title" || shape.placeholder == "ctrTitle" {
                    title = paragraphs.joined(separator: " ")
                } else if shape.placeholder != "sldNum" && shape.placeholder != "dt" && shape.placeholder != "ftr" {
                    lines += paragraphs
                }
            }
            if title.isEmpty, let first = lines.first, first.count <= 90 { title = first; lines.removeFirst() }
            var notes = ""
            if i < notesXMLs.count, let n = notesXMLs[i] { notes = notesText(n) }
            slides.append(SlideText(number: i + 1, title: title, lines: lines, notes: notes))
        }
        return SlideDeckText(slides: slides)
    }

    struct Shape { var placeholder: String?; var xml: String }

    /// Shapes (`p:sp`) and tables/graphic frames in document order. Falls back to the whole XML.
    static func shapes(in xml: String) -> [Shape] {
        let blocks = UniRegex.matches("<p:(sp|graphicFrame)\\b[^>]*>(.*?)</p:\\1>", in: xml, caseInsensitive: false, dotAll: true)
        guard !blocks.isEmpty else { return [Shape(placeholder: nil, xml: xml)] }
        return blocks.map { b in
            let inner = b[2] ?? ""
            let ph = UniRegex.first("<p:ph\\b[^>]*\\btype=\"([A-Za-z]+)\"", in: inner, caseInsensitive: false)?[1]
            return Shape(placeholder: ph, xml: inner)
        }
    }

    /// Each `<a:p>` paragraph's runs joined; `<a:br/>` becomes a space. Empty paragraphs dropped.
    static func paragraphs(in xml: String) -> [String] {
        UniRegex.matches("<a:p\\b[^>]*>(.*?)</a:p>", in: xml, caseInsensitive: false, dotAll: true).compactMap { p in
            let body = UniRegex.replace("<a:br\\s*/>", in: p[1] ?? "", with: "<a:t> </a:t>", caseInsensitive: false)
            let runs = UniRegex.matches("<a:t(?:\\s[^>]*)?>(.*?)</a:t>", in: body, caseInsensitive: false, dotAll: true)
                .map { XMLText.decode($0[1] ?? "") }
            let text = runs.joined().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
    }

    /// Speaker notes: the body placeholder of a notes slide (not the slide image or number).
    static func notesText(_ xml: String) -> String {
        let body = shapes(in: xml).filter { $0.placeholder == "body" }
        let source = body.isEmpty ? shapes(in: xml).filter { $0.placeholder == nil } : body
        return source.flatMap { paragraphs(in: $0.xml) }.joined(separator: " ")
    }
}

/// Text out of Excel XML: shared strings and inline strings, row by row.
public enum XLSXText {
    public static func sharedStrings(_ xml: String) -> [String] {
        UniRegex.matches("<si\\b[^>]*>(.*?)</si>", in: xml, caseInsensitive: false, dotAll: true).map { si in
            UniRegex.matches("<t(?:\\s[^>]*)?>(.*?)</t>", in: si[1] ?? "", caseInsensitive: false, dotAll: true)
                .map { XMLText.decode($0[1] ?? "") }.joined()
        }
    }

    /// One line per row, cells separated by " | ".
    public static func sheetText(_ xml: String, shared: [String]) -> String {
        UniRegex.matches("<row\\b[^>]*>(.*?)</row>", in: xml, caseInsensitive: false, dotAll: true).compactMap { row in
            let cells = UniRegex.matches("<c\\b((?:[^>/]|/(?!>))*)>(.*?)</c>", in: row[1] ?? "", caseInsensitive: false, dotAll: true)
                .compactMap { c -> String? in
                    let attrs = c[1] ?? "", inner = c[2] ?? ""
                    if attrs.contains("t=\"s\""), let v = UniRegex.first("<v>(\\d+)</v>", in: inner)?[1].flatMap(Int.init) {
                        return v < shared.count ? shared[v] : nil
                    }
                    if attrs.contains("t=\"inlineStr\"") {
                        return UniRegex.matches("<t(?:\\s[^>]*)?>(.*?)</t>", in: inner, caseInsensitive: false, dotAll: true)
                            .map { XMLText.decode($0[1] ?? "") }.joined()
                    }
                    return UniRegex.first("<v>(.*?)</v>", in: inner, dotAll: true)?[1].map(XMLText.decode)
                }
                .filter { !$0.isEmpty }
            return cells.isEmpty ? nil : cells.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    public static func extract(sharedStringsXML: String?, sheetXMLs: [String]) -> String {
        let shared = sharedStringsXML.map(sharedStrings) ?? []
        return sheetXMLs.enumerated().map { i, xml in
            "# Sheet \(i + 1)\n" + sheetText(xml, shared: shared)
        }.joined(separator: "\n\n")
    }
}

enum XMLText {
    static func decode(_ s: String) -> String { UniHTML.decodeEntities(s) }
}
