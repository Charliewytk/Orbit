import Foundation

/// Plain-English module titles for module codes ("BEE1022" → "Introduction to Statistics").
///
/// Resolution order:
/// 1. `overrides` (the student's own modules, written the way they say them),
/// 2. the ELE course name registered at sync time, stripped of code and year,
/// 3. the code itself.
///
/// Thread-safe: the registry can be filled from any actor and read from views.
public enum ModuleNames {
    /// Hand-written titles. These win over ELE's names.
    public static let overrides: [String: String] = [
        "BEE1032": "History of Economic Thought",
        "BEE1022": "Introduction to Statistics",
        "BEE1024": "Mathematics for Economists",
        "BEE1036": "Economics 1",
    ]

    /// A short SF Symbol per module, so rows and chips carry an icon.
    public static let symbols: [String: String] = [
        "BEE1032": "books.vertical.fill",
        "BEE1022": "chart.bar.xaxis",
        "BEE1024": "function",
        "BEE1036": "chart.line.uptrend.xyaxis",
    ]

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var names: [String: String] = [:]
    }

    private static let registry = Registry()

    /// Remembers ELE's full course name for a code ("History of Economic Thought (BEE1032_A_1_202627)").
    public static func register(code: String, courseName: String) {
        let code = normalise(code)
        let title = clean(courseName, code: code)
        guard !code.isEmpty, !title.isEmpty, title.uppercased() != code else { return }
        registry.lock.lock()
        registry.names[code] = title
        registry.lock.unlock()
    }

    /// Registers many at once (code → course name).
    public static func register(_ names: [String: String]) {
        for (code, name) in names { register(code: code, courseName: name) }
    }

    /// Clears registered names (tests).
    public static func resetRegistry() {
        registry.lock.lock()
        registry.names = [:]
        registry.lock.unlock()
    }

    /// The English title for a code; the code itself when nothing is known.
    public static func title(for code: String?) -> String {
        guard let raw = code?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return "" }
        let code = normalise(raw)
        if let o = overrides[code] { return o }
        registry.lock.lock()
        let registered = registry.names[code]
        registry.lock.unlock()
        return registered ?? raw
    }

    /// The title, or nil when only the code is known.
    public static func knownTitle(for code: String?) -> String? {
        let t = title(for: code)
        guard !t.isEmpty, t != code?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return t
    }

    /// An SF Symbol for the module (a book for anything unknown).
    public static func symbol(for code: String?) -> String {
        guard let code else { return "book.closed.fill" }
        if let s = symbols[normalise(code)] { return s }
        let t = title(for: code).lowercased()
        if t.contains("stat") { return "chart.bar.xaxis" }
        if t.contains("math") || t.contains("quantitative") { return "function" }
        if t.contains("history") { return "books.vertical.fill" }
        if t.contains("account") || t.contains("finance") { return "sterlingsign.circle.fill" }
        if t.contains("analytics") || t.contains("data") { return "chart.pie.fill" }
        if t.contains("econom") { return "chart.line.uptrend.xyaxis" }
        return "book.closed.fill"
    }

    /// Replaces every module code in a sentence with its title
    /// ("Revise BEE1022 week 2" → "Revise Introduction to Statistics week 2").
    public static func humanise(_ text: String) -> String {
        guard let regex = codeRegex, text.count >= 7 else { return text }
        let ns = text as NSString
        var out = text
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let code = ns.substring(with: m.range(at: 1))
            guard let title = knownTitle(for: code), let r = Range(m.range(at: 1), in: out) else { continue }
            out.replaceSubrange(r, with: title)
        }
        return out
    }

    // MARK: Helpers

    /// Compiled once (humanise runs in list rows).
    private static let codeRegex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])([A-Z]{3}[0-9]{4}|[A-Z]{4}[0-9]{3})(?![0-9])")

    /// "bee1032_a_1_202627" → "BEE1032".
    static func normalise(_ code: String) -> String {
        let upper = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let short = ELEWebParser.moduleCode(shortName: upper) { return short }
        return upper
    }

    /// ELE full name → readable title: drops a trailing "(CODE_…)", the code, the year, separators.
    static func clean(_ fullName: String, code: String) -> String {
        var s = UniRegex.replace("\\s*\\([A-Z]{3,4}\\d{3,4}[^)]*\\)\\s*$", in: fullName, with: "", caseInsensitive: false)
        s = UniRegex.replace("\\b" + NSRegularExpression.escapedPattern(for: code) + "[A-Z0-9_]*", in: s, with: "",
                             caseInsensitive: true)
        return ModuleCode.name(from: s, code: nil)
    }
}
