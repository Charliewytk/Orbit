import Foundation

/// Small regex helper shared by the Uni parsers (NSRegularExpression works on Linux too).
enum UniRegex {
    private static let cache = NSCache<NSString, NSRegularExpression>()

    static func regex(_ pattern: String, caseInsensitive: Bool = true, dotAll: Bool = false) -> NSRegularExpression {
        let key = "\(caseInsensitive ? 1 : 0)\(dotAll ? 1 : 0)\(pattern)" as NSString
        if let r = cache.object(forKey: key) { return r }
        var opts: NSRegularExpression.Options = []
        if caseInsensitive { opts.insert(.caseInsensitive) }
        if dotAll { opts.insert(.dotMatchesLineSeparators) }
        // Patterns are compile-time constants, so a failure is a programming error.
        let r = try! NSRegularExpression(pattern: pattern, options: opts)
        cache.setObject(r, forKey: key)
        return r
    }

    /// Capture groups of every match (index 0 is the whole match; nil for groups that didn't take part).
    static func matches(_ pattern: String, in s: String, caseInsensitive: Bool = true, dotAll: Bool = false) -> [[String?]] {
        let ns = s as NSString
        return regex(pattern, caseInsensitive: caseInsensitive, dotAll: dotAll)
            .matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
                (0..<m.numberOfRanges).map { i in
                    let r = m.range(at: i)
                    return r.location == NSNotFound ? nil : ns.substring(with: r)
                }
            }
    }

    static func first(_ pattern: String, in s: String, caseInsensitive: Bool = true, dotAll: Bool = false) -> [String?]? {
        matches(pattern, in: s, caseInsensitive: caseInsensitive, dotAll: dotAll).first
    }

    static func replace(_ pattern: String, in s: String, with template: String,
                        caseInsensitive: Bool = true, dotAll: Bool = false) -> String {
        regex(pattern, caseInsensitive: caseInsensitive, dotAll: dotAll)
            .stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}

/// Turns the HTML Moodle returns (assignment intros, forum posts, Talis pages) into plain text.
public enum UniHTML {
    public static func text(_ html: String) -> String {
        var s = html
        s = UniRegex.replace("<(script|style)[^>]*>.*?</\\1>", in: s, with: " ", dotAll: true)
        s = UniRegex.replace("<br\\s*/?>", in: s, with: "\n")
        s = UniRegex.replace("</(p|div|li|h[1-6]|tr|ul|ol|table|blockquote)>", in: s, with: "\n")
        s = UniRegex.replace("<li[^>]*>", in: s, with: "• ")
        s = UniRegex.replace("<[^>]+>", in: s, with: "", dotAll: true)
        s = decodeEntities(s)
        let lines = s.components(separatedBy: "\n").map {
            UniRegex.replace("[ \\t\\u00A0]+", in: $0, with: " ").trimmingCharacters(in: .whitespaces)
        }
        // Collapse runs of blank lines.
        var out: [String] = []
        for l in lines where !(l.isEmpty && (out.last?.isEmpty ?? true)) { out.append(l) }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–",
        "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "hellip": "…", "pound": "£",
    ]

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var decoded: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    decoded = named[name]
                }
                if let decoded { out += decoded; i = s.index(after: semi); continue }
            }
            out.append(s[i]); i = s.index(after: i)
        }
        return out
    }
}

/// Exeter module codes such as "BEM2031" (three letters, four digits).
public enum ModuleCode {
    /// First module code in `text`, e.g. "BEM2031 - Business Analytics 2026/7" → "BEM2031".
    /// Also accepts four-letter/three-digit postgraduate codes ("BEMM461").
    public static func find(in text: String) -> String? {
        for pattern in ["(?<![A-Z])[A-Z]{3}[0-9]{4}(?![0-9])", "(?<![A-Z])[A-Z]{4}[0-9]{3}(?![0-9])"] {
            if let m = UniRegex.first(pattern, in: text, caseInsensitive: false), let code = m[0] { return code }
        }
        return nil
    }

    /// The readable module name: code, separators and academic year stripped.
    /// "BEM2031 - Business Analytics 2026/7" → "Business Analytics".
    public static func name(from fullName: String, code: String?) -> String {
        var s = fullName
        if let code { s = s.replacingOccurrences(of: code, with: "") }
        s = UniRegex.replace("\\(?\\b(19|20)\\d{2}\\s*[/-]\\s*\\d{1,4}\\)?", in: s, with: "")
        s = UniRegex.replace("\\((19|20)\\d{2}\\)", in: s, with: "")
        s = UniRegex.replace("\\s{2,}", in: s, with: " ")
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:|_·,").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? fullName.trimmingCharacters(in: .whitespaces) : trimmed
    }
}

/// Heuristics that read assessment details out of free text (titles and briefs).
public enum AssessmentParsing {
    private static let number = "(\\d{1,3}(?:\\.\\d+)?)"

    /// Weight as a percentage of the module, e.g. "(40%)", "worth 30%", "Weighting: 50%",
    /// "50% of the module mark". Returns nil if nothing plausible is found.
    public static func weightPercent(in text: String) -> Double? {
        let patterns = [
            "\\(\\s*\(number)\\s*%\\s*\\)",
            "worth\\s+(?:about\\s+)?\(number)\\s*%",
            "weight(?:ing|ed)?(?:\\s+(?:at|of))?\\s*[:=\\-–]?\\s*\(number)\\s*%",
            "\(number)\\s*%\\s*(?:of\\s+(?:the\\s+)?(?:overall\\s+|final\\s+|total\\s+)?(?:module|overall|final|total|course))",
            "\(number)\\s*%\\s*weight(?:ing|ed)?",
        ]
        for p in patterns {
            for m in UniRegex.matches(p, in: text) {
                if let v = m[1].flatMap(Double.init), v > 0, v <= 100 { return v }
            }
        }
        return nil
    }

    /// Weight from a title alone: the patterns above, or a single bare "40%".
    public static func weightFromTitle(_ title: String) -> Double? {
        if let w = weightPercent(in: title) { return w }
        let all = UniRegex.matches("\(number)\\s*%", in: title).compactMap { $0[1].flatMap(Double.init) }
        return all.count == 1 && all[0] > 0 && all[0] <= 100 ? all[0] : nil
    }

    /// Word count or limit, e.g. "2,000 words", "2000-word essay", "word limit: 2500",
    /// "1500–2000 words" (takes the upper figure).
    public static func wordCount(in text: String) -> Int? {
        let n = "(\\d{1,2},\\d{3}|\\d{3,5})"
        let patterns = [
            "\(n)\\s*(?:-|–|to)\\s*\(n)\\s*[- ]?words?\\b",
            "\(n)\\s*[- ]?words?\\b",
            "word\\s*(?:count|limit|length)(?:\\s+of)?\\s*(?:is\\s*)?[:=\\-–]?\\s*(?:max(?:imum)?\\.?\\s*)?\(n)",
        ]
        for (i, p) in patterns.enumerated() {
            for m in UniRegex.matches(p, in: text) {
                let raw = i == 0 ? m[2] : m[1]
                if let v = raw.flatMap({ Int($0.replacingOccurrences(of: ",", with: "")) }), (100...20000).contains(v) { return v }
            }
        }
        return nil
    }

    /// Kind of assessment guessed from title keywords (brief text is a weaker signal).
    public static func kind(title: String, brief: String = "") -> AssessmentKind {
        if let k = kindFromKeywords(title) { return k }
        return kindFromKeywords(String(brief.prefix(400))) ?? .coursework
    }

    static func kindFromKeywords(_ text: String) -> AssessmentKind? {
        let t = " " + text.lowercased() + " "
        func has(_ words: [String]) -> Bool {
            words.contains { UniRegex.first("\\b\($0)", in: t) != nil }
        }
        if has(["exam", "examination"]) { return .exam }
        if has(["quiz", "mcq", "multiple[- ]choice", "class test", "online test", "test\\b"]) { return .quiz }
        if has(["presentation", "poster", "pitch", "viva"]) { return .presentation }
        if has(["essay", "dissertation", "literature review", "critical review", "reflective", "reflection"]) { return .essay }
        if has(["report", "case study", "project"]) { return .report }
        if has(["group"]) { return .groupwork }
        return nil
    }

    /// True for practice work that doesn't count ("formative", "practice", "mock").
    public static func isFormative(_ text: String) -> Bool {
        UniRegex.first("\\b(formative|practice|mock|non-assessed|ungraded)\\b", in: text) != nil
    }
}
