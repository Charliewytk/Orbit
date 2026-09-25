import Foundation

/// Turns HTML (email bodies, OneNote pages) into readable plain text.
///
/// Drops scripts, styles, `<head>` and comments, keeps line breaks for block
/// elements (`<br>`, `<p>`, `<div>`, `<li>`, headings, table rows), and decodes
/// common entities. It isn't a full HTML parser; it's tuned for the messy
/// markup email clients and Office produce.
public enum HTMLToText {
    public static func convert(_ html: String) -> String {
        let chars = Array(html)
        var out = ""
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "<" {
                if matches(chars, at: i, "<!--") {
                    i = index(of: "-->", in: chars, from: i + 4).map { $0 + 3 } ?? chars.count
                    continue
                }
                guard let tag = readTag(chars, at: i) else {
                    out.append(c); i += 1; continue
                }
                i = tag.end
                if skippedElements.contains(tag.name) && !tag.isClosing && !tag.selfClosing {
                    // Skip everything up to the matching close tag.
                    i = index(of: "</\(tag.name)", in: chars, from: i, caseInsensitive: true)
                        .flatMap { index(of: ">", in: chars, from: $0) }.map { $0 + 1 } ?? chars.count
                    continue
                }
                switch tag.name {
                case "br": out.append("\n")
                case "li": if !tag.isClosing { out.append("\n• ") }
                case "td", "th": out.append(" ")
                default: if blockElements.contains(tag.name) { out.append("\n") }
                }
            } else if c == "&", let (text, next) = readEntity(chars, at: i) {
                out.append(text); i = next
            } else {
                out.append(c.isWhitespace ? " " : c); i += 1
            }
        }
        return tidy(out)
    }

    /// Decodes HTML entities only (no tag handling). Handy for Gmail snippets.
    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "&", let (text, next) = readEntity(chars, at: i) {
                out.append(text); i = next
            } else {
                out.append(chars[i]); i += 1
            }
        }
        return out
    }

    // MARK: - Internals

    private static let skippedElements: Set<String> = ["script", "style", "head", "title", "noscript", "template"]
    private static let blockElements: Set<String> = [
        "p", "div", "ul", "ol", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6", "hr",
        "blockquote", "pre", "section", "article", "header", "footer", "dl", "dt", "dd", "address",
    ]

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·", "pound": "£", "euro": "€",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "times": "×", "shy": "",
        "zwnj": "", "zwj": "", "laquo": "«", "raquo": "»", "eacute": "é", "egrave": "è",
        "aacute": "á", "agrave": "à", "ouml": "ö", "uuml": "ü", "auml": "ä", "szlig": "ß",
        "ccedil": "ç", "iexcl": "¡", "iquest": "¿", "frac12": "½", "cent": "¢", "sect": "§",
    ]

    private struct Tag { var name: String; var isClosing: Bool; var selfClosing: Bool; var end: Int }

    /// Reads `<name ...>` starting at `i`. Returns nil if this `<` isn't a tag (e.g. "a < b").
    private static func readTag(_ c: [Character], at i: Int) -> Tag? {
        var j = i + 1
        var closing = false
        if j < c.count, c[j] == "/" { closing = true; j += 1 }
        if j < c.count, c[j] == "!" || c[j] == "?" {
            // <!DOCTYPE …>, <?xml …?>
            guard let end = index(of: ">", in: c, from: j) else { return nil }
            return Tag(name: "!", isClosing: false, selfClosing: true, end: end + 1)
        }
        guard j < c.count, c[j].isLetter else { return nil }
        var name = ""
        while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == ":" || c[j] == "-" {
            name.append(c[j]); j += 1
        }
        // Find the closing '>', ignoring any inside quoted attribute values.
        var quote: Character?
        while j < c.count {
            let ch = c[j]
            if let q = quote { if ch == q { quote = nil } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if ch == ">" { break }
            j += 1
        }
        let selfClosing = j > 0 && j < c.count && c[j - 1] == "/"
        return Tag(name: name.lowercased(), isClosing: closing, selfClosing: selfClosing, end: min(j + 1, c.count))
    }

    private static func readEntity(_ c: [Character], at i: Int) -> (String, Int)? {
        var j = i + 1
        var name = ""
        while j < c.count, j - i <= 10, c[j] != ";" {
            guard c[j].isLetter || c[j].isNumber || c[j] == "#" else { return nil }
            name.append(c[j]); j += 1
        }
        guard j < c.count, c[j] == ";", !name.isEmpty else { return nil }
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" { value = UInt32(digits.dropFirst(), radix: 16) }
            else { value = UInt32(digits) }
            guard let v = value, let scalar = Unicode.Scalar(v) else { return nil }
            return (v == 160 ? " " : String(Character(scalar)), j + 1)
        }
        guard let text = namedEntities[name] ?? namedEntities[name.lowercased()] else { return nil }
        return (text, j + 1)
    }

    /// Collapses runs of spaces, trims lines, and keeps at most one blank line in a row.
    private static func tidy(_ s: String) -> String {
        var lines: [String] = []
        var lastBlank = true
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            if line.isEmpty {
                if !lastBlank { lines.append("") }
                lastBlank = true
            } else {
                lines.append(line); lastBlank = false
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func matches(_ c: [Character], at i: Int, _ s: String) -> Bool {
        var j = i
        for ch in s {
            guard j < c.count, c[j] == ch else { return false }
            j += 1
        }
        return true
    }

    private static func index(of s: String, in c: [Character], from start: Int, caseInsensitive: Bool = false) -> Int? {
        let needle = Array(caseInsensitive ? s.lowercased() : s)
        guard !needle.isEmpty, c.count >= needle.count else { return nil }
        var i = start
        while i <= c.count - needle.count {
            var ok = true
            for k in 0..<needle.count {
                let same = caseInsensitive ? c[i + k].lowercased() == String(needle[k]) : c[i + k] == needle[k]
                if !same { ok = false; break }
            }
            if ok { return i }
            i += 1
        }
        return nil
    }
}
