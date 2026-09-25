import Foundation

/// A piece of a OneNote page, in page coordinates (CSS px, 96 dpi).
public struct OneNoteBlock: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Typed text from an outline. Lists become "- ", headings "# ", tables "a | b".
        case text
        case image
        /// An embedded file (`<object>`), e.g. a PDF printout.
        case attachment
        /// A marker for pen strokes the HTML mentions (the strokes themselves come from InkML).
        case ink
    }

    public var kind: Kind
    public var text: String
    /// Position of the containing outline or element, if the page uses absolute layout.
    public var top: Double?
    public var left: Double?
    public var width: Double?
    public var height: Double?
    /// Graph `data-id`, stable across edits (needs `includeIDs=true`).
    public var dataID: String?
    public var elementID: String?
    /// Image/attachment resource URL.
    public var src: String?
    public var fullResolutionSrc: String?
    public var mimeType: String?
    /// Position in the HTML, used to break ties and order unpositioned blocks.
    public var order: Int

    public init(kind: Kind, text: String = "", top: Double? = nil, left: Double? = nil, width: Double? = nil,
                height: Double? = nil, dataID: String? = nil, elementID: String? = nil, src: String? = nil,
                fullResolutionSrc: String? = nil, mimeType: String? = nil, order: Int = 0) {
        self.kind = kind; self.text = text; self.top = top; self.left = left; self.width = width
        self.height = height; self.dataID = dataID; self.elementID = elementID; self.src = src
        self.fullResolutionSrc = fullResolutionSrc; self.mimeType = mimeType; self.order = order
    }
}

/// A parsed OneNote page.
public struct OneNotePageDocument: Codable, Hashable, Sendable {
    public var title: String
    public var created: Date?
    public var blocks: [OneNoteBlock]

    public init(title: String, created: Date? = nil, blocks: [OneNoteBlock] = []) {
        self.title = title; self.created = created; self.blocks = blocks
    }

    public var textBlocks: [OneNoteBlock] { blocks.filter { $0.kind == .text } }
    /// All typed text in page order.
    public var typedText: String { textBlocks.map(\.text).joined(separator: "\n\n") }
}

/// Turns OneNote page HTML (as served by Graph) into ordered blocks.
///
/// OneNote HTML is regular: each outline is a `<div style="position:absolute;left:…;top:…">`
/// holding `<p>`, `<ul>/<ol>/<li>`, `<h1…6>`, `<table>`, `<img>` and `<object>`.
public enum OneNoteHTMLParser {
    public static func parse(_ html: String) -> OneNotePageDocument {
        var builder = Builder()
        for token in OneNoteHTMLTokenizer.tokens(html) { builder.consume(token) }
        builder.flushText()
        let title = builder.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return OneNotePageDocument(title: title, created: builder.created, blocks: builder.blocks)
    }

    // MARK: Styles

    /// Parses `left`, `top`, `width`, `height` from an inline style (px or pt).
    public static func position(fromStyle style: String) -> (left: Double?, top: Double?, width: Double?, height: Double?) {
        var values: [String: Double] = [:]
        for decl in style.split(separator: ";") {
            let kv = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard kv.count == 2, ["left", "top", "width", "height"].contains(kv[0]) else { continue }
            if let v = cssLength(kv[1]) { values[kv[0]] = v }
        }
        return (values["left"], values["top"], values["width"], values["height"])
    }

    static func cssLength(_ s: String) -> Double? {
        let unitless = s.trimmingCharacters(in: .whitespaces)
        for (suffix, factor) in [("px", 1.0), ("pt", 4.0 / 3.0), ("in", 96.0), ("cm", 96 / 2.54), ("mm", 96 / 25.4)]
        where unitless.hasSuffix(suffix) {
            return Double(unitless.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)).map { $0 * factor }
        }
        return Double(unitless)
    }

    // MARK: Building blocks

    struct Container {
        var tag: String
        var top: Double?, left: Double?, width: Double?, height: Double?
        var dataID: String?
    }

    struct Builder {
        var title = ""
        var created: Date?
        var blocks: [OneNoteBlock] = []
        var inHead = false, inTitle = false
        var skipDepth = 0
        /// Open elements, with the positioned outlines among them.
        var stack: [String] = []
        var containers: [(depth: Int, container: Container)] = []
        var lines: [String] = []
        var line = ""
        var linePrefix = ""
        var listStack: [(ordered: Bool, counter: Int)] = []
        var cellIndex = 0
        var cellDepth = 0
        var textDataID: String?
        var order = 0

        var container: Container? { containers.last?.container }

        mutating func consume(_ token: OneNoteHTMLTokenizer.Token) {
            switch token {
            case .text(let raw):
                if skipDepth > 0 { return }
                if inTitle { title += raw; return }
                if inHead { return }
                appendText(raw)
            case .open(let name, let attrs, let selfClosing):
                open(name, attrs, selfClosing: selfClosing)
            case .close(let name):
                close(name)
            }
        }

        mutating func open(_ name: String, _ attrs: [String: String], selfClosing: Bool) {
            if skipDepth > 0 { if !selfClosing && (name == "script" || name == "style") { skipDepth += 1 }; return }
            switch name {
            case "head": inHead = true; return
            case "body": inHead = false; return
            case "title": inTitle = true; return
            case "meta":
                if attrs["name"]?.lowercased() == "created", let c = attrs["content"] { created = OneNoteHTMLParser.date(c) }
                return
            case "script", "style": if !selfClosing { skipDepth = 1 }; return
            case "br": blockBreak(); return
            case "img": emitImage(attrs); return
            case "object": emitAttachment(attrs); if !selfClosing { stack.append(name) }; return
            default: break
            }
            if inHead { return }
            if Self.isInkMarker(name, attrs) { emitInk(attrs) }

            let pos = attrs["style"].map(OneNoteHTMLParser.position(fromStyle:))
            let positioned = pos.map { $0.top != nil || $0.left != nil } ?? false
            if positioned && name != "p" && name != "span" && name != "li" {
                flushText()
                containers.append((stack.count, Container(tag: name, top: pos?.top, left: pos?.left,
                                                          width: pos?.width, height: pos?.height,
                                                          dataID: attrs["data-id"])))
            }
            if textDataID == nil, let id = attrs["data-id"] { textDataID = id }
            switch name {
            case "p", "div", "blockquote", "pre":
                blockBreak()
                if name == "p", cellDepth == 0, let tag = attrs["data-tag"]?.lowercased(), tag.hasPrefix("to-do") {
                    linePrefix = tag.contains("completed") ? "☑ " : "☐ "
                }
            case "tr", "table":
                breakLine()
                if name == "tr" { cellIndex = 0 }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                breakLine()
                linePrefix = String(repeating: "#", count: Int(String(name.last!)) ?? 1) + " "
            case "ul": breakLine(); listStack.append((false, 0))
            case "ol": breakLine(); listStack.append((true, 0))
            case "li":
                breakLine()
                let indent = String(repeating: "  ", count: max(0, listStack.count - 1))
                if listStack.isEmpty { linePrefix = "- " } else {
                    listStack[listStack.count - 1].counter += 1
                    let l = listStack[listStack.count - 1]
                    linePrefix = indent + (l.ordered ? "\(l.counter). " : "- ")
                }
            case "td", "th":
                if cellIndex > 0 {
                    while line.hasSuffix(" ") { line.removeLast() }
                    line += " | "
                }
                cellIndex += 1
                cellDepth += 1
            default: break
            }
            if !selfClosing { stack.append(name) }
        }

        mutating func close(_ name: String) {
            if skipDepth > 0 { if name == "script" || name == "style" { skipDepth -= 1 }; return }
            switch name {
            case "head": inHead = false; return
            case "title": inTitle = false; return
            default: break
            }
            switch name {
            case "td", "th": cellDepth = max(0, cellDepth - 1)
            case "p", "div", "blockquote", "pre": blockBreak()
            case "li", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6": breakLine()
            case "ul", "ol": breakLine(); if !listStack.isEmpty { listStack.removeLast() }
            default: break
            }
            // Pop to the matching open element (tolerates unclosed tags).
            guard let idx = stack.lastIndex(of: name) else { return }
            stack.removeSubrange(idx...)
            if let c = containers.last, c.depth >= stack.count {
                flushText()
                containers.removeAll { $0.depth >= stack.count }
            }
        }

        mutating func appendText(_ raw: String) {
            // HTML whitespace collapses; entities are already decoded.
            var collapsed = ""
            var lastSpace = line.isEmpty || line.hasSuffix(" ")
            for ch in raw {
                if ch.isWhitespace && ch != "\u{00A0}" {
                    if !lastSpace { collapsed.append(" "); lastSpace = true }
                } else {
                    collapsed.append(ch == "\u{00A0}" ? " " : ch); lastSpace = false
                }
            }
            if collapsed.trimmingCharacters(in: .whitespaces).isEmpty && line.isEmpty { return }
            if line.isEmpty { line = linePrefix; linePrefix = "" }
            line += collapsed
        }

        /// Paragraph breaks inside a table cell become spaces so the row stays on one line.
        mutating func blockBreak() {
            if cellDepth > 0 {
                if !line.isEmpty && !line.hasSuffix(" ") { line += " " }
            } else if !line.isEmpty {
                breakLine()
            }
            // An empty line keeps its pending prefix, so "<li><p>x</p></li>" still gets its bullet.
        }

        mutating func breakLine() {
            // Keep leading spaces: they're list indentation from `linePrefix`.
            var t = line
            while t.last?.isWhitespace == true { t.removeLast() }
            let bare = t.trimmingCharacters(in: .whitespaces)
            if !bare.isEmpty && bare != "|" { lines.append(t) }
            line = ""; linePrefix = ""
        }

        mutating func flushText() {
            breakLine()
            let text = lines.joined(separator: "\n")
            lines = []
            defer { textDataID = nil }
            guard !text.isEmpty else { return }
            let c = container
            blocks.append(OneNoteBlock(kind: .text, text: text, top: c?.top, left: c?.left, width: c?.width,
                                       height: c?.height, dataID: c?.dataID ?? textDataID, order: nextOrder()))
        }

        mutating func nextOrder() -> Int { order += 1; return order }

        mutating func emitImage(_ attrs: [String: String]) {
            flushText()
            let own = attrs["style"].map(OneNoteHTMLParser.position(fromStyle:))
            let c = container
            blocks.append(OneNoteBlock(
                kind: Self.isInkMarker("img", attrs) ? .ink : .image,
                text: attrs["alt"] ?? "",
                top: own?.top ?? c?.top, left: own?.left ?? c?.left,
                width: attrs["width"].flatMap(Double.init) ?? own?.width,
                height: attrs["height"].flatMap(Double.init) ?? own?.height,
                dataID: attrs["data-id"], elementID: attrs["id"], src: attrs["src"],
                fullResolutionSrc: attrs["data-fullres-src"],
                mimeType: attrs["data-src-type"] ?? attrs["data-fullres-src-type"], order: nextOrder()))
        }

        mutating func emitAttachment(_ attrs: [String: String]) {
            flushText()
            let own = attrs["style"].map(OneNoteHTMLParser.position(fromStyle:))
            let c = container
            blocks.append(OneNoteBlock(
                kind: .attachment, text: attrs["data-attachment"] ?? "",
                top: own?.top ?? c?.top, left: own?.left ?? c?.left,
                dataID: attrs["data-id"], elementID: attrs["id"], src: attrs["data"],
                mimeType: attrs["type"], order: nextOrder()))
        }

        mutating func emitInk(_ attrs: [String: String]) {
            let own = attrs["style"].map(OneNoteHTMLParser.position(fromStyle:))
            blocks.append(OneNoteBlock(kind: .ink, top: own?.top ?? container?.top, left: own?.left ?? container?.left,
                                       width: own?.width, height: own?.height, dataID: attrs["data-id"],
                                       elementID: attrs["id"], order: nextOrder()))
        }

        /// Elements that stand in for pen strokes (ids like "ink:{…}" or `data-ink*` attributes).
        static func isInkMarker(_ name: String, _ attrs: [String: String]) -> Bool {
            if attrs.keys.contains(where: { $0.hasPrefix("data-ink") }) { return true }
            if let id = attrs["id"]?.lowercased(), id.hasPrefix("ink") { return true }
            if let type = attrs["type"]?.lowercased(), type.contains("inkml") { return true }
            return false
        }
    }

    static func date(_ s: String) -> Date? {
        if let d = ISO8601.parse(s) { return d }
        // "2024-10-14T10:05:00.0000000+01:00": trim the 7-digit fraction ISO8601DateFormatter rejects.
        if let dot = s.firstIndex(of: "."), let zone = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            return ISO8601.parse(String(s[..<dot]) + String(s[zone...]))
        }
        return nil
    }
}

// MARK: - Metadata

/// Finds module codes and week numbers in notebook, section and page titles.
public enum NoteMetadataDetector {
    static let moduleRegex = try! NSRegularExpression(pattern: "(?<![A-Za-z])([A-Za-z]{3})[ -]?([0-9]{4})(?![0-9])")
    static let weekRegex = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9])(?:week|wk|w)[ ._-]?0?([0-9]{1,2})(?![0-9])", options: [.caseInsensitive])

    /// Exeter module code such as "BEM2031" from the first string that has one.
    public static func moduleCode(in strings: [String?]) -> String? {
        for s in strings.compactMap({ $0 }) {
            let r = NSRange(s.startIndex..., in: s)
            guard let m = moduleRegex.firstMatch(in: s, range: r),
                  let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s) else { continue }
            return (s[a] + s[b]).uppercased()
        }
        return nil
    }

    /// Week number from "Week 5", "Wk5", "W5", "week-05".
    public static func week(in strings: [String?]) -> Int? {
        for s in strings.compactMap({ $0 }) {
            let r = NSRange(s.startIndex..., in: s)
            guard let m = weekRegex.firstMatch(in: s, range: r), let g = Range(m.range(at: 1), in: s),
                  let n = Int(s[g]), (0...60).contains(n) else { continue }
            return n
        }
        return nil
    }
}

// MARK: - Tokenizer

/// A forgiving HTML tokenizer: tags with attributes, text with entities decoded.
/// Comments, doctype and processing instructions are dropped.
enum OneNoteHTMLTokenizer {
    enum Token: Equatable {
        case open(String, [String: String], selfClosing: Bool)
        case close(String)
        case text(String)
    }

    static func tokens(_ html: String) -> [Token] {
        let s = Array(html.unicodeScalars)
        var out: [Token] = []
        var i = 0
        var text = String.UnicodeScalarView()
        func flush() {
            if !text.isEmpty { out.append(.text(decodeEntities(String(text)))); text = .init() }
        }
        while i < s.count {
            guard s[i] == "<" else { text.append(s[i]); i += 1; continue }
            // Comment
            if i + 3 < s.count, s[i + 1] == "!", s[i + 2] == "-", s[i + 3] == "-" {
                flush()
                var j = i + 4
                while j + 2 < s.count, !(s[j] == "-" && s[j + 1] == "-" && s[j + 2] == ">") { j += 1 }
                i = min(s.count, j + 3); continue
            }
            // Doctype / processing instruction / CDATA
            if i + 1 < s.count, s[i + 1] == "!" || s[i + 1] == "?" {
                flush()
                var j = i + 1
                while j < s.count, s[j] != ">" { j += 1 }
                i = j + 1; continue
            }
            let isClose = i + 1 < s.count && s[i + 1] == "/"
            var j = i + (isClose ? 2 : 1)
            guard j < s.count, s[j].properties.isAlphabetic else { text.append(s[i]); i += 1; continue }
            flush()
            var name = ""
            while j < s.count, !s[j].properties.isWhitespace, s[j] != ">", s[j] != "/" {
                name.unicodeScalars.append(s[j]); j += 1
            }
            var attrs: [String: String] = [:]
            var selfClosing = false
            while j < s.count, s[j] != ">" {
                if s[j].properties.isWhitespace { j += 1; continue }
                if s[j] == "/" { selfClosing = true; j += 1; continue }
                var key = ""
                while j < s.count, !s[j].properties.isWhitespace, s[j] != "=", s[j] != ">", s[j] != "/" {
                    key.unicodeScalars.append(s[j]); j += 1
                }
                while j < s.count, s[j].properties.isWhitespace { j += 1 }
                var value = ""
                if j < s.count, s[j] == "=" {
                    j += 1
                    while j < s.count, s[j].properties.isWhitespace { j += 1 }
                    if j < s.count, s[j] == "\"" || s[j] == "'" {
                        let q = s[j]; j += 1
                        while j < s.count, s[j] != q { value.unicodeScalars.append(s[j]); j += 1 }
                        j += 1
                    } else {
                        while j < s.count, !s[j].properties.isWhitespace, s[j] != ">" { value.unicodeScalars.append(s[j]); j += 1 }
                    }
                }
                if !key.isEmpty { attrs[key.lowercased()] = decodeEntities(value) }
                if key.isEmpty { j += 1 }
            }
            i = j + 1
            let lower = name.lowercased()
            if isClose { out.append(.close(lower)) } else {
                let void: Set<String> = ["br", "img", "meta", "link", "hr", "input", "col", "area", "base", "source"]
                out.append(.open(lower, attrs, selfClosing: selfClosing || void.contains(lower)))
            }
        }
        flush()
        return out
    }

    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "ndash": "–",
        "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•",
        "pound": "£", "euro": "€", "copy": "©", "times": "×", "divide": "÷", "minus": "−", "deg": "°",
        "plusmn": "±", "le": "≤", "ge": "≥", "ne": "≠", "rarr": "→", "larr": "←", "middot": "·",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let body = s[s.index(after: i)..<semi]
                var replacement: String?
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
                } else if body.hasPrefix("#") {
                    replacement = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
                } else {
                    replacement = named[String(body)]
                }
                if let replacement { out += replacement; i = s.index(after: semi); continue }
            }
            out.append(s[i]); i = s.index(after: i)
        }
        return out
    }
}
