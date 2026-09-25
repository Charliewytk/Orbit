import Foundation

// MARK: - Profile

/// What Orbit has learned about the student's handwriting, from pages where
/// they typed up part of their handwritten notes (a free answer key).
public struct PersonalHandwritingProfile: Codable, Hashable, Sendable {
    /// OCR misreading → correct word → times seen. Keys are normalised (lower-case).
    public var corrections: [String: [String: Int]]
    /// Times an OCR word was confirmed correct by the typed text. Blocks bad corrections.
    public var confirmations: [String: Int]
    /// Module terms, names and acronyms, in their typed spelling.
    public var vocabulary: Set<String>
    /// The student's shorthand → full word → times seen ("w/" → "with").
    public var abbreviations: [String: [String: Int]]
    /// A correction needs this many sightings before it's applied (unless high-confidence).
    public var minCount: Int
    public var pagesLearned: Int
    public var updated: Date?

    public init(corrections: [String: [String: Int]] = [:], confirmations: [String: Int] = [:],
                vocabulary: Set<String> = [], abbreviations: [String: [String: Int]] = [:],
                minCount: Int = 2, pagesLearned: Int = 0, updated: Date? = nil) {
        self.corrections = corrections; self.confirmations = confirmations; self.vocabulary = vocabulary
        self.abbreviations = abbreviations; self.minCount = minCount; self.pagesLearned = pagesLearned
        self.updated = updated
    }

    public mutating func recordCorrection(ocr: String, correct: String, count: Int = 1) {
        corrections[TextNormalizer.key(ocr), default: [:]][correct, default: 0] += count
    }

    public mutating func recordAbbreviation(_ short: String, meaning: String, count: Int = 1) {
        abbreviations[TextNormalizer.key(short), default: [:]][meaning.lowercased(), default: 0] += count
    }

    public mutating func recordConfirmation(_ word: String, count: Int = 1) {
        confirmations[TextNormalizer.key(word), default: 0] += count
    }

    /// Adds another profile's counts (e.g. from another Mac).
    public mutating func merge(_ other: PersonalHandwritingProfile) {
        for (k, v) in other.corrections { for (t, n) in v { corrections[k, default: [:]][t, default: 0] += n } }
        for (k, v) in other.abbreviations { for (t, n) in v { abbreviations[k, default: [:]][t, default: 0] += n } }
        for (k, n) in other.confirmations { confirmations[k, default: 0] += n }
        vocabulary.formUnion(other.vocabulary)
        pagesLearned += other.pagesLearned
    }

    /// Words for `AppleVisionOCR.customWords` and the vision-model prompt.
    public var customWords: [String] { vocabulary.sorted() }

    /// Shorthand seen at least `minCount` times, with its most common meaning.
    public func learnedAbbreviations(minCount: Int? = nil) -> [String: String] {
        var out: [String: String] = [:]
        for (short, meanings) in abbreviations {
            if let best = meanings.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), best.value >= (minCount ?? self.minCount) {
                out[short] = best.key
            }
        }
        return out
    }

    /// The correction to use for an OCR word, if it's trustworthy: seen ≥ `minCount`
    /// times (and more often than the word was confirmed as right), or seen once with no
    /// contradiction when the target is a known vocabulary term that looks very similar.
    public func correction(for word: String) -> String? {
        let key = TextNormalizer.key(word)
        guard !key.isEmpty, let options = corrections[key],
              let best = options.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return nil }
        let confirmed = confirmations[key] ?? 0
        if best.value >= minCount && best.value > confirmed { return best.key }
        let vocab = Set(vocabulary.map { $0.lowercased() })
        if confirmed == 0, vocab.contains(best.key.lowercased()),
           TextNormalizer.similarity(key, TextNormalizer.key(best.key)) >= 0.75 {
            return best.key
        }
        return nil
    }

    public struct Replacement: Hashable, Sendable {
        public var from: String
        public var to: String
    }

    /// Fixes known misreadings in OCR text. "[?word]" markers whose word gets
    /// corrected lose their marker. With `expandAbbreviations`, learned shorthand is spelled out.
    public func apply(to text: String, expandAbbreviations: Bool = false) -> String {
        applyWithReport(to: text, expandAbbreviations: expandAbbreviations).text
    }

    public func applyWithReport(to text: String, expandAbbreviations: Bool = false) -> (text: String, replacements: [Replacement]) {
        let abbreviations = expandAbbreviations ? learnedAbbreviations() : [:]
        var replacements: [Replacement] = []
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var words = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            var i = 0
            while i < words.count {
                // Two OCR tokens that should be one word ("govern ment").
                if i + 1 < words.count {
                    let a = WordParts(words[i]), b = WordParts(words[i + 1])
                    if !a.core.isEmpty, !b.core.isEmpty, a.suffix.isEmpty, b.prefix.isEmpty,
                       let fix = correction(for: a.core + " " + b.core) {
                        replacements.append(Replacement(from: a.core + " " + b.core, to: fix))
                        words[i] = a.prefix + matchCase(fix, like: a.core) + b.suffix
                        words.remove(at: i + 1)
                        i += 1; continue
                    }
                }
                let w = WordParts(words[i])
                if !w.core.isEmpty {
                    if let fix = correction(for: w.core) {
                        replacements.append(Replacement(from: w.core, to: fix))
                        words[i] = w.prefix + matchCase(fix, like: w.core) + w.suffix
                    } else if let full = abbreviations[TextNormalizer.key(w.core)] {
                        replacements.append(Replacement(from: w.core, to: full))
                        words[i] = w.prefix + matchCase(full, like: w.core) + w.suffix
                    } else if w.uncertain {
                        words[i] = w.prefix + "[?" + w.core + "]" + w.suffix
                    }
                }
                i += 1
            }
            return words.joined(separator: " ")
        }
        return (lines.joined(separator: "\n"), replacements)
    }

    /// Keeps the vocabulary's own casing; otherwise copies capitalisation from the original.
    func matchCase(_ replacement: String, like original: String) -> String {
        if let v = vocabulary.first(where: { $0.lowercased() == replacement.lowercased() }),
           v.contains(where: \.isUppercase) { return v }
        if replacement.contains(where: \.isUppercase) { return replacement }
        if original.count > 1, original == original.uppercased(), original.contains(where: \.isLetter) {
            return replacement.uppercased()
        }
        if let f = original.first, f.isUppercase { return replacement.prefix(1).uppercased() + replacement.dropFirst() }
        return replacement
    }

    /// A word split into leading punctuation, the word, and trailing punctuation.
    /// Understands "[?word]" uncertainty markers.
    struct WordParts {
        var prefix = "", core = "", suffix = ""
        var uncertain = false

        init(_ raw: String) {
            var s = Substring(raw)
            let lead: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "*"]
            let trail: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "\"", "'", "”", "’", "*"]
            if s.hasPrefix("[?"), let close = s.firstIndex(of: "]") {
                uncertain = true
                core = String(s[s.index(s.startIndex, offsetBy: 2)..<close])
                suffix = String(s[s.index(after: close)...])
                return
            }
            while let c = s.first, lead.contains(c) { prefix.append(c); s = s.dropFirst() }
            var tail = ""
            while let c = s.last, trail.contains(c) { tail = String(c) + tail; s = s.dropLast() }
            core = String(s); suffix = tail
        }
    }
}

// MARK: - Text normalisation

public enum TextNormalizer {
    static let edgePunctuation = CharacterSet(charactersIn: ".,;:!?()[]{}\"'“”‘’*•#_`~<>")

    /// Lower-cased with edge punctuation removed ("Market," → "market"). Keeps "/" and "&" ("w/", "b/c").
    public static func key(_ word: String) -> String {
        var w = word
        if w.hasPrefix("[?"), w.hasSuffix("]") { w = String(w.dropFirst(2).dropLast()) }
        return w.lowercased().trimmingCharacters(in: edgePunctuation.union(.whitespaces))
    }

    /// 1 − edit distance / longer length.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let m = max(a.count, b.count)
        return m == 0 ? 1 : 1 - Double(levenshtein(a, b)) / Double(m)
    }

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }

    /// "govt" → "government", "w/" → "with", "b/c" → "because", "ppl" → "people":
    /// same first letter, shorter, and its letters appear in order in the long word.
    public static func isAbbreviation(_ short: String, of long: String) -> Bool {
        let s = short.lowercased(), l = long.lowercased()
        if s == "&" || s == "+" { return l == "and" }
        let sl = s.filter(\.isLetter), ll = l.filter(\.isLetter)
        guard let f = sl.first, f == ll.first, sl.count < ll.count,
              s.contains("/") || Double(sl.count) <= 0.75 * Double(ll.count) else { return false }
        // "tax" → "taxes" is a different form of the word, not shorthand.
        if ll.hasPrefix(sl), ["s", "es", "d", "ed", "ing", "er", "ers", "ly"].contains(String(ll.dropFirst(sl.count))) {
            return false
        }
        var it = ll.makeIterator()
        outer: for c in sl {
            while let n = it.next() { if n == c { continue outer } }
            return false
        }
        return true
    }
}

// MARK: - Alignment

/// A token of OCR or typed text, remembering where it came from.
public struct AlignToken: Hashable, Sendable {
    public var text: String
    public var key: String
    /// Which handwriting region (index into the regions passed in) and line it came from.
    public var region: Int
    public var line: Int
}

public struct AlignedPair: Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case match, substitution
        /// Two OCR tokens for one typed word ("govern ment" / "government").
        case merge
        /// One OCR token for two typed words ("alot" / "a lot").
        case split
        case handwritingOnly, typedOnly
    }
    public var kind: Kind
    public var ocr: String
    public var typed: String
    /// Indices into the handwriting token stream.
    public var ocrTokens: [Int]
}

/// Where one typed line was found in the handwriting.
public struct TypedAlignment: Hashable, Sendable {
    public var typedLine: String
    public var typedLineIndex: Int
    /// Token range in the handwriting stream.
    public var handwritingRange: Range<Int>
    public var pairs: [AlignedPair]
    public var score: Double
    /// Share of the typed line's words found (exactly or approximately) in the handwriting.
    public var coverage: Double
    /// Indices of the handwriting regions this line summarises.
    public var regions: [Int]
}

public struct HarvestedSubstitution: Hashable, Sendable {
    public enum Kind: String, Sendable { case misreading, abbreviation }
    public var ocr: String
    public var correct: String
    public var kind: Kind
}

/// Learns the student's handwriting by aligning OCR of the handwriting with the
/// typed notes below it. The typed notes cover only some of the handwriting, so each
/// typed line is aligned locally (Smith–Waterman on normalised words) to its best-matching window.
public struct HandwritingLearner: Sendable {
    public var matchScore = 3.0
    public var similarScore = 1.0
    public var mismatchPenalty = -1.5
    /// Skipping handwritten words is cheap: the typed text is a summary.
    public var handwritingGapPenalty = -0.4
    public var typedGapPenalty = -1.0
    /// Minimum string similarity for a pair to count as the same word misread.
    public var minSimilarity = 0.5
    /// A typed line must find at least this share of its words to count as aligned.
    public var minCoverage = 0.5
    /// Regions with at least this share of tokens aligned become training samples.
    public var sampleCoverage = 0.8

    public init() {}

    // MARK: Tokens

    static let listMarker = try! NSRegularExpression(pattern: #"^(\d+[.)]|[-•*#]+|☐|☑)$"#)

    public static func tokens(_ text: String, region: Int = 0) -> [AlignToken] {
        var out: [AlignToken] = []
        for (li, line) in text.components(separatedBy: .newlines).enumerated() {
            for raw in line.split(whereSeparator: \.isWhitespace) {
                let s = String(raw)
                if listMarker.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { continue }
                let key = TextNormalizer.key(s)
                if key.isEmpty { continue }
                out.append(AlignToken(text: s, key: key, region: region, line: li))
            }
        }
        return out
    }

    // MARK: Aligning

    /// Aligns each typed line against the handwriting OCR text of one or more regions.
    public func align(typed: String, handwriting regions: [String]) -> [TypedAlignment] {
        let hw = regions.enumerated().flatMap { Self.tokens($0.element, region: $0.offset) }
        let typedLines = typed.components(separatedBy: .newlines)
        var out: [TypedAlignment] = []
        for (i, line) in typedLines.enumerated() {
            let t = Self.tokens(line)
            guard !t.isEmpty, !hw.isEmpty, let a = alignLine(t, hw) else { continue }
            let found = a.pairs.filter { $0.kind != .typedOnly && $0.kind != .handwritingOnly }
            let coverage = Double(found.reduce(0) { $0 + ($1.kind == .split ? 2 : 1) }) / Double(t.count)
            let exact = a.pairs.filter { $0.kind == .match }.count
            guard coverage >= minCoverage, exact >= min(2, t.count) else { continue }
            let regionIdx = Array(Set(a.pairs.flatMap(\.ocrTokens).map { hw[$0].region })).sorted()
            out.append(TypedAlignment(typedLine: line, typedLineIndex: i, handwritingRange: a.range,
                                      pairs: a.pairs, score: a.score, coverage: coverage, regions: regionIdx))
        }
        return out
    }

    /// Convenience for one block of handwriting.
    public func align(handwriting: String, typed: String) -> [TypedAlignment] {
        align(typed: typed, handwriting: [handwriting])
    }

    func pairScore(_ a: String, _ b: String) -> Double {
        if a == b { return matchScore }
        if TextNormalizer.similarity(a, b) >= minSimilarity || TextNormalizer.isAbbreviation(a, of: b) { return similarScore }
        return mismatchPenalty
    }

    /// Smith–Waterman with extra moves for merged and split words.
    func alignLine(_ t: [AlignToken], _ h: [AlignToken]) -> (pairs: [AlignedPair], range: Range<Int>, score: Double)? {
        let n = h.count, m = t.count
        enum Move: UInt8 { case stop, diag, up, left, merge, split }
        var H = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        var P = [[Move]](repeating: [Move](repeating: .stop, count: m + 1), count: n + 1)
        var best = (score: 0.0, i: 0, j: 0)
        for i in 1...n {
            for j in 1...m {
                var cell = (0.0, Move.stop)
                func consider(_ s: Double, _ mv: Move) { if s > cell.0 { cell = (s, mv) } }
                consider(H[i - 1][j - 1] + pairScore(h[i - 1].key, t[j - 1].key), .diag)
                consider(H[i - 1][j] + handwritingGapPenalty, .up)
                consider(H[i][j - 1] + typedGapPenalty, .left)
                if i >= 2, h[i - 2].key + h[i - 1].key == t[j - 1].key {
                    consider(H[i - 2][j - 1] + matchScore - 0.5, .merge)
                }
                if j >= 2, t[j - 2].key + t[j - 1].key == h[i - 1].key {
                    consider(H[i - 1][j - 2] + matchScore - 0.5, .split)
                }
                H[i][j] = cell.0; P[i][j] = cell.1
                if cell.0 > best.score { best = (cell.0, i, j) }
            }
        }
        guard best.score > 0 else { return nil }
        var pairs: [AlignedPair] = []
        var i = best.i, j = best.j
        while i > 0, j > 0, P[i][j] != .stop {
            switch P[i][j] {
            case .diag:
                let a = h[i - 1], b = t[j - 1]
                pairs.append(AlignedPair(kind: a.key == b.key ? .match : .substitution, ocr: a.text, typed: b.text, ocrTokens: [i - 1]))
                i -= 1; j -= 1
            case .up:
                pairs.append(AlignedPair(kind: .handwritingOnly, ocr: h[i - 1].text, typed: "", ocrTokens: [i - 1])); i -= 1
            case .left:
                pairs.append(AlignedPair(kind: .typedOnly, ocr: "", typed: t[j - 1].text, ocrTokens: [])); j -= 1
            case .merge:
                pairs.append(AlignedPair(kind: .merge, ocr: h[i - 2].text + " " + h[i - 1].text, typed: t[j - 1].text,
                                         ocrTokens: [i - 2, i - 1]))
                i -= 2; j -= 1
            case .split:
                pairs.append(AlignedPair(kind: .split, ocr: h[i - 1].text, typed: t[j - 2].text + " " + t[j - 1].text,
                                         ocrTokens: [i - 1]))
                i -= 1; j -= 2
            case .stop:
                break
            }
        }
        pairs.reverse()
        // Trim unmatched handwriting at the ends of the window.
        while let f = pairs.first, f.kind == .handwritingOnly { pairs.removeFirst() }
        while let l = pairs.last, l.kind == .handwritingOnly { pairs.removeLast() }
        let idx = pairs.flatMap(\.ocrTokens)
        guard let lo = idx.min(), let hi = idx.max() else { return nil }
        return (pairs, lo..<(hi + 1), best.score)
    }

    // MARK: Harvesting

    /// The (OCR → typed) substitutions worth learning from a set of alignments.
    public func harvest(_ alignments: [TypedAlignment]) -> [HarvestedSubstitution] {
        var out: [HarvestedSubstitution] = []
        for a in alignments {
            for p in a.pairs where p.kind == .substitution || p.kind == .merge || p.kind == .split {
                let ocr = p.kind == .merge
                    ? p.ocr.split(separator: " ").map { TextNormalizer.key(String($0)) }.joined(separator: " ")
                    : TextNormalizer.key(p.ocr)
                let typedWord = p.kind == .split
                    ? p.typed.split(separator: " ").map { TextNormalizer.key(String($0)) }.joined(separator: " ")
                    : TextNormalizer.key(p.typed)
                guard !ocr.isEmpty, !typedWord.isEmpty, ocr != typedWord else { continue }
                let correct = Self.typedSpelling(p.typed)
                if TextNormalizer.isAbbreviation(ocr, of: typedWord) {
                    out.append(HarvestedSubstitution(ocr: ocr, correct: correct.lowercased(), kind: .abbreviation))
                } else if p.kind != .substitution
                            || TextNormalizer.similarity(ocr.replacingOccurrences(of: " ", with: ""), typedWord) >= minSimilarity {
                    out.append(HarvestedSubstitution(ocr: ocr, correct: correct, kind: .misreading))
                }
            }
        }
        return out
    }

    /// Typed word without edge punctuation, keeping case only for proper nouns and acronyms.
    static func typedSpelling(_ typed: String) -> String {
        let words = typed.split(separator: " ").map { w -> String in
            let parts = PersonalHandwritingProfile.WordParts(String(w))
            let core = parts.core
            let isProper = core.dropFirst().contains(where: \.isUppercase) || core.contains(where: \.isNumber)
            return isProper ? core : core.lowercased()
        }
        return words.joined(separator: " ")
    }

    /// Likely vocabulary in typed notes: capitalised words mid-sentence, acronyms, codes, long terms.
    public static func vocabulary(in typed: String) -> Set<String> {
        var out: Set<String> = []
        for line in typed.components(separatedBy: .newlines) {
            let words = line.split(whereSeparator: \.isWhitespace).map { PersonalHandwritingProfile.WordParts(String($0)).core }
            for (i, w) in words.enumerated() where w.count >= 2 && w.contains(where: \.isLetter) {
                let letters = w.filter(\.isLetter)
                let acronym = letters.count >= 2 && letters == letters.uppercased()
                let code = w.contains(where: \.isNumber)
                let midCapital = i > 0 && w.first!.isUppercase && !(words[i - 1].last.map { ".:!?".contains($0) } ?? false)
                let long = w.count >= 9 && !w.contains("/")
                // Keep the typed casing only where it means something (names, acronyms, codes).
                if acronym || code || midCapital { out.insert(w) } else if long { out.insert(w.lowercased()) }
            }
        }
        return out
    }

    // MARK: Learning

    /// One handwriting region to learn from.
    public struct Region: Sendable {
        public var id: String
        public var ocrText: String
        /// PNG of the whole region, for the training set.
        public var image: Data?
        /// PNGs of each written line; used instead of `image` when their count matches the OCR lines.
        public var lineImages: [Data]?

        public init(id: String, ocrText: String, image: Data? = nil, lineImages: [Data]? = nil) {
            self.id = id; self.ocrText = ocrText; self.image = image; self.lineImages = lineImages
        }
    }

    public struct Report: Sendable {
        public var alignments: [TypedAlignment]
        public var substitutions: [HarvestedSubstitution]
        public var vocabularyAdded: Set<String>
        /// Aligned (image, text) pairs for optional TrOCR fine-tuning.
        public var samples: [HandwritingSample]
    }

    /// Learns from one page: updates `profile` and returns what was found.
    @discardableResult
    public func learn(regions: [Region], typed: String, pageID: String? = nil,
                      into profile: inout PersonalHandwritingProfile, now: Date = Date()) -> Report {
        let alignments = align(typed: typed, handwriting: regions.map(\.ocrText))
        let subs = harvest(alignments)
        for s in subs {
            switch s.kind {
            case .misreading: profile.recordCorrection(ocr: s.ocr, correct: s.correct)
            case .abbreviation: profile.recordAbbreviation(s.ocr, meaning: s.correct)
            }
        }
        for a in alignments { for p in a.pairs where p.kind == .match { profile.recordConfirmation(p.ocr) } }
        let vocab = Self.vocabulary(in: typed).subtracting(profile.vocabulary)
        profile.vocabulary.formUnion(vocab)
        profile.pagesLearned += 1
        profile.updated = now
        let samples = trainingSamples(regions: regions, alignments: alignments, pageID: pageID)
        return Report(alignments: alignments, substitutions: subs, vocabularyAdded: vocab, samples: samples)
    }

    /// Convenience for a single block of handwriting OCR text.
    @discardableResult
    public func learn(handwriting: String, typed: String, into profile: inout PersonalHandwritingProfile) -> Report {
        learn(regions: [Region(id: "page", ocrText: handwriting)], typed: typed, into: &profile)
    }

    /// Regions (or lines) mostly covered by the typed text, labelled with the OCR text
    /// with misreadings fixed. Abbreviations stay as written, since that's what the image shows.
    func trainingSamples(regions: [Region], alignments: [TypedAlignment], pageID: String?) -> [HandwritingSample] {
        let hw = regions.enumerated().flatMap { Self.tokens($0.element.ocrText, region: $0.offset) }
        var fixed: [Int: String] = [:]
        var covered = Set<Int>()
        for a in alignments {
            for p in a.pairs {
                guard p.kind != .handwritingOnly, p.kind != .typedOnly else { continue }
                covered.formUnion(p.ocrTokens)
                let ocrKey = TextNormalizer.key(p.ocr.replacingOccurrences(of: " ", with: ""))
                let typedKey = TextNormalizer.key(p.typed.replacingOccurrences(of: " ", with: ""))
                guard p.kind != .match, !TextNormalizer.isAbbreviation(ocrKey, of: typedKey) else { continue }
                if p.kind == .substitution, TextNormalizer.similarity(ocrKey, typedKey) < minSimilarity { continue }
                let parts = PersonalHandwritingProfile.WordParts(hw[p.ocrTokens[0]].text)
                fixed[p.ocrTokens[0]] = parts.prefix + PersonalHandwritingProfile.WordParts(p.typed).core
                    + PersonalHandwritingProfile.WordParts(hw[p.ocrTokens.last!].text).suffix
                for extra in p.ocrTokens.dropFirst() { fixed[extra] = "" }
            }
        }
        var samples: [HandwritingSample] = []
        for (ri, region) in regions.enumerated() {
            let idx = hw.indices.filter { hw[$0].region == ri }
            guard !idx.isEmpty else { continue }
            let coverage = Double(idx.filter(covered.contains).count) / Double(idx.count)
            guard coverage >= sampleCoverage else { continue }
            var lines: [Int: [String]] = [:]
            for i in idx {
                let word = fixed[i] ?? PersonalHandwritingProfile.WordParts(hw[i].text).plain
                if !word.isEmpty { lines[hw[i].line, default: []].append(word) }
            }
            let lineTexts = lines.keys.sorted().map { lines[$0]!.joined(separator: " ") }
            if let lineImages = region.lineImages, lineImages.count == lineTexts.count {
                for (n, (img, text)) in zip(lineImages, lineTexts).enumerated() {
                    samples.append(HandwritingSample(id: "\(pageID ?? "page")-\(region.id)-l\(n + 1)", text: text,
                                                     pageID: pageID, regionID: region.id, coverage: coverage, image: img))
                }
            } else if let image = region.image {
                samples.append(HandwritingSample(id: "\(pageID ?? "page")-\(region.id)", text: lineTexts.joined(separator: "\n"),
                                                 pageID: pageID, regionID: region.id, coverage: coverage, image: image))
            }
        }
        return samples
    }
}

extension PersonalHandwritingProfile.WordParts {
    /// The word with any "[?…]" marker removed.
    var plain: String { prefix + core + suffix }
}

// MARK: - Training data

/// An (image, text) pair of the student's own handwriting.
public struct HandwritingSample: Codable, Hashable, Sendable {
    public var id: String
    public var text: String
    public var pageID: String?
    public var regionID: String?
    public var coverage: Double
    /// PNG bytes. Not written into the manifest (it stores a file path instead).
    public var image: Data?

    public init(id: String, text: String, pageID: String? = nil, regionID: String? = nil,
                coverage: Double = 1, image: Data? = nil) {
        self.id = id; self.text = text; self.pageID = pageID; self.regionID = regionID
        self.coverage = coverage; self.image = image
    }
}

/// Writes samples as `images/<id>.png` plus `manifest.jsonl` lines
/// `{"image": "images/<id>.png", "text": "…", "page_id": …, "region_id": …}`,
/// the format `Tools/handwriting/finetune_trocr.py` reads. Re-running replaces samples with the same id.
public enum HandwritingDataset {
    struct Entry: Codable {
        let id: String
        let image: String
        let text: String
        let page_id: String?
        let region_id: String?
        let coverage: Double
    }

    @discardableResult
    public static func write(_ samples: [HandwritingSample], to directory: URL) throws -> URL {
        let fm = FileManager.default
        let images = directory.appendingPathComponent("images", isDirectory: true)
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("manifest.jsonl")
        var entries: [String: Entry] = [:]
        var order: [String] = []
        if let old = try? String(contentsOf: manifest, encoding: .utf8) {
            for line in old.split(separator: "\n") {
                guard let e = try? JSONDecoder().decode(Entry.self, from: Data(line.utf8)) else { continue }
                if entries[e.id] == nil { order.append(e.id) }
                entries[e.id] = e
            }
        }
        for s in samples {
            guard let png = s.image else { continue }
            let safe = s.id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
            let rel = "images/\(String(safe)).png"
            try png.write(to: directory.appendingPathComponent(rel))
            if entries[s.id] == nil { order.append(s.id) }
            entries[s.id] = Entry(id: s.id, image: rel, text: s.text, page_id: s.pageID, region_id: s.regionID,
                                  coverage: s.coverage)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = try order.compactMap { entries[$0] }.map { String(decoding: try enc.encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: manifest, atomically: true, encoding: .utf8)
        return manifest
    }
}
