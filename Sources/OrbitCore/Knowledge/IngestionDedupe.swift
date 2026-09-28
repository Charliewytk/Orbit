import Foundation

// MARK: - Global ingestion dedupe
//
// "The AI must never see the same thing twice." Every document that enters the knowledge
// store (ELE files and pages, Drive / Notability PDFs, the same PDF in several folders,
// Notability re-exports, typed notes, email attachments, Ed posts…) is registered here first.
//
//   1. Normalise the text (case, accents, punctuation, whitespace) → SHA-256.
//      Same hash as a known document → duplicate: only a source reference is added.
//   2. Otherwise 5-word shingles → 64-value MinHash. Estimated Jaccard ≥ 0.9 with a known
//      document → the same document (a re-export, a re-OCR, a slightly edited copy):
//      the newer text *replaces* the old one's chunks under the same canonical id.
//   3. A source whose text changed keeps its canonical id and replaces its old chunks.
//
// One canonical document, many `IngestionSource`s.

/// Where a piece of content came from.
public enum IngestionSourceKind: String, Codable, Sendable, CaseIterable {
    case ele, drive, notability, typedNote, note, emailAttachment, ed, reading, feedback, activity, other

    /// A best guess from a knowledge document id ("ele-cm-12", "note:file:…", "ed-…").
    public static func infer(fromDocumentID id: String) -> IngestionSourceKind {
        let l = id.lowercased()
        if l.hasPrefix("note:typed:") || l.hasPrefix("typed:") { return .typedNote }
        if l.hasPrefix("note:file:") || l.hasPrefix("file:") || l.hasPrefix("notability") { return .notability }
        if l.hasPrefix("note:") { return .note }
        if l.hasPrefix("drive") { return .drive }
        if l.hasPrefix("ele") { return .ele }
        if l.hasPrefix("ed-") || l.hasPrefix("ed:") { return .ed }
        if l.hasPrefix("mail") || l.hasPrefix("email") || l.hasPrefix("attachment") { return .emailAttachment }
        if l.hasPrefix("talis") || l.hasPrefix("reading") { return .reading }
        if l.hasPrefix("feedback") { return .feedback }
        if l.hasPrefix("activity") { return .activity }
        return .other
    }
}

public struct IngestionSource: Codable, Hashable, Sendable {
    public var kind: IngestionSourceKind
    /// Stable id within that source (file path, Drive file id, ELE cmid, message id + attachment…).
    public var id: String
    public var key: String { kind.rawValue + "|" + id }

    public init(kind: IngestionSourceKind, id: String) { self.kind = kind; self.id = id }

    public static func document(_ id: String) -> IngestionSource { IngestionSource(kind: .infer(fromDocumentID: id), id: id) }
}

/// Normalised-text hash + MinHash signature of one document.
public struct TextFingerprint: Codable, Hashable, Sendable {
    public var hash: String
    public var minHash: [UInt64]
    /// Number of distinct shingles (0 for empty text). Short texts are only deduped exactly.
    public var shingles: Int

    public static let permutations = 64
    public static let shingleSize = 5

    public init(text: String) {
        let norm = Self.normalize(text)
        hash = SHA256Digest.hexString(SHA256Digest.hash(norm))
        let set = Self.shingleSet(norm)
        shingles = set.count
        minHash = Self.signature(set)
    }

    /// Lower-case, accents folded, everything but letters/digits → single spaces.
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_GB"))
        var out = ""
        out.reserveCapacity(folded.utf8.count)
        var space = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                space = false
            } else if !space {
                out.append(" ")
                space = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    static func shingleSet(_ normalized: String) -> Set<UInt64> {
        let words = normalized.split(separator: " ")
        guard !words.isEmpty else { return [] }
        let k = min(shingleSize, words.count)
        var out = Set<UInt64>()
        for i in 0...(words.count - k) {
            out.insert(fnv1a(words[i..<(i + k)].joined(separator: " ")))
        }
        return out
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    /// splitmix64: a cheap, well-mixed family of hash permutations.
    static func mix(_ x: UInt64, _ seed: UInt64) -> UInt64 {
        var z = x &+ seed &* 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    static func signature(_ set: Set<UInt64>) -> [UInt64] {
        guard !set.isEmpty else { return [] }
        return (0..<permutations).map { p in
            let seed = UInt64(p + 1)
            return set.reduce(UInt64.max) { min($0, mix($1, seed)) }
        }
    }

    /// Estimated Jaccard similarity of the two shingle sets (0…1).
    public func similarity(to other: TextFingerprint) -> Double {
        if hash == other.hash { return 1 }
        guard minHash.count == other.minHash.count, !minHash.isEmpty else { return 0 }
        let same = zip(minHash, other.minHash).filter { $0 == $1 }.count
        return Double(same) / Double(minHash.count)
    }

    public var isEmpty: Bool { shingles == 0 }
}

/// What to do with an incoming document.
public enum IngestDecision: Hashable, Sendable {
    /// New content: index it under `canonicalID`.
    case ingest(canonicalID: String)
    /// Near-identical to (or a new version of) a known document: replace that document's
    /// chunks with the new text, under the existing `canonicalID`.
    case replace(canonicalID: String)
    /// Already known (same text from another source, or unchanged): do nothing but remember the source.
    case duplicate(canonicalID: String)
    case unchanged(canonicalID: String)
    /// Empty text: nothing to ingest.
    case empty

    public var canonicalID: String? {
        switch self {
        case .ingest(let id), .replace(let id), .duplicate(let id), .unchanged(let id): id
        case .empty: nil
        }
    }

    /// True when the caller must (re)index text.
    public var needsIndexing: Bool {
        switch self {
        case .ingest, .replace: true
        default: false
        }
    }
}

/// Every canonical document ever ingested, its fingerprint and every source it came from.
public struct IngestionLedger: Codable, Hashable, Sendable {
    public struct Canonical: Codable, Hashable, Sendable {
        public var id: String
        public var fingerprint: TextFingerprint
        public var sources: [IngestionSource]
        public var updated: Date
    }

    public private(set) var canonicals: [String: Canonical] = [:]
    /// Source key → canonical id.
    public private(set) var bySource: [String: String] = [:]
    /// Normalised hash → canonical id.
    public private(set) var byHash: [String: String] = [:]

    /// Estimated Jaccard at or above which two texts are the same document.
    public var threshold: Double = 0.9
    /// Texts with fewer shingles than this are only deduped by exact hash
    /// (a one-line announcement shouldn't swallow another one-liner).
    public var minShinglesForNearDup = 20

    public init(threshold: Double = 0.9) { self.threshold = threshold }

    enum CodingKeys: String, CodingKey { case canonicals, bySource, byHash, threshold, minShinglesForNearDup }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canonicals = (try? c.decodeIfPresent([String: Canonical].self, forKey: .canonicals)) ?? [:]
        bySource = (try? c.decodeIfPresent([String: String].self, forKey: .bySource)) ?? [:]
        byHash = (try? c.decodeIfPresent([String: String].self, forKey: .byHash)) ?? [:]
        threshold = (try? c.decodeIfPresent(Double.self, forKey: .threshold)) ?? 0.9
        minShinglesForNearDup = (try? c.decodeIfPresent(Int.self, forKey: .minShinglesForNearDup)) ?? 20
    }

    public func canonicalID(for source: IngestionSource) -> String? { bySource[source.key] }
    public func canonical(_ id: String) -> Canonical? { canonicals[id] }
    public func sources(of canonicalID: String) -> [IngestionSource] { canonicals[canonicalID]?.sources ?? [] }

    /// Registers `text` from `source`. `proposedID` becomes the canonical id if the content is new.
    /// Returns the decision plus any canonical ids that are now orphaned (their chunks must go).
    @discardableResult
    public mutating func register(source: IngestionSource, text: String, proposedID: String,
                                  date: Date = Date()) -> (decision: IngestDecision, obsolete: [String]) {
        let fp = TextFingerprint(text: text)
        let previousID = bySource[source.key]
        guard !fp.isEmpty else {
            // The source is now empty: detach it.
            let dropped = previousID.flatMap { detach(source, from: $0) }.map { [$0] } ?? []
            return (.empty, dropped)
        }

        // Same source, same text.
        if let previousID, let c = canonicals[previousID], c.fingerprint.hash == fp.hash {
            return (.unchanged(canonicalID: previousID), [])
        }

        // Identical text already known (e.g. the same PDF in two folders, an email attachment of an ELE file).
        if let existing = byHash[fp.hash], canonicals[existing] != nil {
            var obsolete: [String] = []
            if let previousID, previousID != existing, let d = detach(source, from: previousID) { obsolete.append(d) }
            attach(source, to: existing)
            return (.duplicate(canonicalID: existing), obsolete)
        }

        // Near-identical: the source's own previous version first, then anything else.
        let target: String? = {
            if let previousID, canonicals[previousID] != nil { return previousID }
            guard fp.shingles >= minShinglesForNearDup else { return nil }
            return nearest(to: fp)
        }()

        if let target, var c = canonicals[target] {
            // A changed source whose new text now matches some *other* document better: move it there.
            if target == previousID, fp.shingles >= minShinglesForNearDup, let other = nearest(to: fp, excluding: target) {
                var obsolete: [String] = []
                if let d = detach(source, from: target) { obsolete.append(d) }
                return (replaceText(of: other, with: fp, adding: source, date: date), obsolete)
            }
            if target == previousID && c.sources.count > 1 {
                // Another source still holds the old text: this source forks into its own document.
                _ = detach(source, from: target)
                return (insert(fp, source: source, id: uniqueID(proposedID), date: date), [])
            }
            byHash[c.fingerprint.hash] = nil
            c.fingerprint = fp
            c.updated = date
            if !c.sources.contains(source) { c.sources.append(source) }
            canonicals[target] = c
            byHash[fp.hash] = target
            bySource[source.key] = target
            return (.replace(canonicalID: target), [])
        }

        return (insert(fp, source: source, id: uniqueID(proposedID), date: date), [])
    }

    /// Forgets a source (file deleted, email removed). Returns the canonical id to delete when
    /// no other source holds that document any more.
    @discardableResult
    public mutating func remove(source: IngestionSource) -> String? {
        guard let id = bySource[source.key] else { return nil }
        return detach(source, from: id)
    }

    /// Drops a canonical document entirely (with all its sources).
    public mutating func removeCanonical(_ id: String) {
        guard let c = canonicals.removeValue(forKey: id) else { return }
        if byHash[c.fingerprint.hash] == id { byHash[c.fingerprint.hash] = nil }
        for s in c.sources where bySource[s.key] == id { bySource[s.key] = nil }
    }

    // MARK: Private

    private mutating func insert(_ fp: TextFingerprint, source: IngestionSource, id: String, date: Date) -> IngestDecision {
        canonicals[id] = Canonical(id: id, fingerprint: fp, sources: [source], updated: date)
        byHash[fp.hash] = id
        bySource[source.key] = id
        return .ingest(canonicalID: id)
    }

    private mutating func replaceText(of id: String, with fp: TextFingerprint, adding source: IngestionSource, date: Date) -> IngestDecision {
        guard var c = canonicals[id] else { return .empty }
        if byHash[c.fingerprint.hash] == id { byHash[c.fingerprint.hash] = nil }
        c.fingerprint = fp
        c.updated = date
        if !c.sources.contains(source) { c.sources.append(source) }
        canonicals[id] = c
        byHash[fp.hash] = id
        bySource[source.key] = id
        return .replace(canonicalID: id)
    }

    private mutating func attach(_ source: IngestionSource, to id: String) {
        bySource[source.key] = id
        if canonicals[id]?.sources.contains(source) == false { canonicals[id]?.sources.append(source) }
    }

    /// Returns `id` if the canonical was removed because this was its last source.
    private mutating func detach(_ source: IngestionSource, from id: String) -> String? {
        if bySource[source.key] == id { bySource[source.key] = nil }
        guard var c = canonicals[id] else { return nil }
        c.sources.removeAll { $0 == source }
        if c.sources.isEmpty {
            removeCanonical(id)
            return id
        }
        canonicals[id] = c
        return nil
    }

    private func nearest(to fp: TextFingerprint, excluding: String? = nil) -> String? {
        var best: (String, Double)?
        for (id, c) in canonicals where id != excluding && c.fingerprint.shingles >= minShinglesForNearDup {
            let s = fp.similarity(to: c.fingerprint)
            if s >= threshold, s > (best?.1 ?? 0) || (s == best?.1 && id < best!.0) { best = (id, s) }
        }
        return best?.0
    }

    private func uniqueID(_ proposed: String) -> String {
        guard canonicals[proposed] != nil else { return proposed }
        var n = 2
        while canonicals["\(proposed)#\(n)"] != nil { n += 1 }
        return "\(proposed)#\(n)"
    }
}
