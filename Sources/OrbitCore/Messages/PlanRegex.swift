import Foundation

/// Thin NSRegularExpression wrapper used by the message parsers (works on Linux too).
struct PlanRegex: @unchecked Sendable {
    struct Match {
        let range: Range<String.Index>
        let groups: [String?]
        func group(_ i: Int) -> String? { i < groups.count ? groups[i] : nil }
    }

    let regex: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = true) {
        // Patterns are compile-time constants, so a failure here is a programming error.
        regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    func matches(in s: String) -> [Match] {
        let ns = NSRange(s.startIndex..., in: s)
        return regex.matches(in: s, range: ns).compactMap { r in
            guard let range = Range(r.range, in: s) else { return nil }
            let groups: [String?] = (0..<r.numberOfRanges).map { i in
                Range(r.range(at: i), in: s).map { String(s[$0]) }
            }
            return Match(range: range, groups: groups)
        }
    }

    func firstMatch(in s: String) -> Match? { matches(in: s).first }
    func contains(_ s: String) -> Bool { regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
}
