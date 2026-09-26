import XCTest
@testable import OrbitCore

final class IngestionDedupeTests: XCTestCase {
    /// ~300 words of distinct-ish text (deterministic).
    static func essay(_ seed: Int, words: Int = 300) -> String {
        let vocab = ["utility", "marginal", "demand", "supply", "elasticity", "equilibrium", "price", "quantity", "consumer",
                     "producer", "surplus", "cost", "revenue", "profit", "market", "firm", "labour", "capital", "output",
                     "growth", "inflation", "interest", "rate", "money", "trade", "tariff", "welfare", "tax", "budget",
                     "income", "saving", "investment", "Smith", "Ricardo", "Keynes", "Marx", "value", "rent", "wage"]
        var x = UInt64(seed &+ 12345)
        return (0..<words).map { _ -> String in
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return vocab[Int((x >> 33) % UInt64(vocab.count))]
        }.joined(separator: " ")
    }

    func doc(_ id: String, _ text: String, title: String = "Doc", week: Int? = 1) -> CourseDocument {
        CourseDocument(id: id, moduleCode: "BEE1020", week: week, kind: .lectureNotes, title: title, text: text,
                       modified: Date(timeIntervalSince1970: 1_790_000_000))
    }

    // MARK: Fingerprints

    func testNormalizationIgnoresCaseAccentsPunctuationAndSpacing() {
        let a = TextFingerprint(text: "Adam Smith’s  “Wealth of Nations” — café,\n\n1776!")
        let b = TextFingerprint(text: "adam smith s wealth of nations cafe 1776")
        XCTAssertEqual(a.hash, b.hash)
        XCTAssertEqual(a.similarity(to: b), 1)
    }

    func testSimilarityHighForSmallEditsLowForDifferentText() {
        let base = Self.essay(1)
        var words = base.split(separator: " ").map(String.init)
        words[150] = "OCRmistake"
        let edited = TextFingerprint(text: words.joined(separator: " "))
        XCTAssertGreaterThanOrEqual(TextFingerprint(text: base).similarity(to: edited), 0.9)
        XCTAssertLessThan(TextFingerprint(text: base).similarity(to: TextFingerprint(text: Self.essay(2))), 0.5)
    }

    // MARK: Ledger

    func testSameContentFromTwoSourcesIsOneCanonical() {
        var ledger = IngestionLedger()
        let text = Self.essay(3)
        let first = ledger.register(source: IngestionSource(kind: .ele, id: "cm-1"), text: text, proposedID: "ele-cm-1")
        XCTAssertEqual(first.decision, .ingest(canonicalID: "ele-cm-1"))
        let second = ledger.register(source: IngestionSource(kind: .emailAttachment, id: "msg-9/slides.pdf"),
                                     text: text.uppercased(), proposedID: "mail-9")
        XCTAssertEqual(second.decision, .duplicate(canonicalID: "ele-cm-1"))
        XCTAssertEqual(ledger.canonicals.count, 1)
        XCTAssertEqual(Set(ledger.sources(of: "ele-cm-1").map(\.kind)), [.ele, .emailAttachment])
        // Registering again is a no-op.
        let again = ledger.register(source: IngestionSource(kind: .ele, id: "cm-1"), text: text, proposedID: "ele-cm-1")
        XCTAssertEqual(again.decision, .unchanged(canonicalID: "ele-cm-1"))
    }

    func testReExportWithSmallChangesReplacesInsteadOfAdding() {
        var ledger = IngestionLedger()
        let text = Self.essay(4)
        ledger.register(source: IngestionSource(kind: .notability, id: "HoE/Hoe week 1.pdf"), text: text, proposedID: "a")
        let reexport = text + " marginal"
        let r = ledger.register(source: IngestionSource(kind: .drive, id: "driveFile123"), text: reexport, proposedID: "b")
        XCTAssertEqual(r.decision, .replace(canonicalID: "a"))
        XCTAssertEqual(ledger.canonicals.count, 1)
        XCTAssertEqual(ledger.canonical("a")?.fingerprint.hash, TextFingerprint(text: reexport).hash)
    }

    func testShortTextsAreOnlyMergedWhenIdentical() {
        var ledger = IngestionLedger()
        ledger.register(source: .document("activity-1"), text: "Lecture cancelled today", proposedID: "activity-1")
        let r = ledger.register(source: .document("activity-2"), text: "Lecture cancelled tomorrow", proposedID: "activity-2")
        XCTAssertEqual(r.decision, .ingest(canonicalID: "activity-2"))
    }

    func testRemovingOneSourceKeepsSharedDocument() {
        var ledger = IngestionLedger()
        let text = Self.essay(5)
        ledger.register(source: .document("x"), text: text, proposedID: "x")
        ledger.register(source: .document("y"), text: text, proposedID: "y")
        XCTAssertNil(ledger.remove(source: .document("x")))
        XCTAssertNotNil(ledger.canonical("x"))
        XCTAssertEqual(ledger.remove(source: .document("y")), "x")
        XCTAssertTrue(ledger.canonicals.isEmpty)
    }

    func testChangedSourceSharedWithAnotherForks() {
        var ledger = IngestionLedger()
        let text = Self.essay(6)
        ledger.register(source: .document("x"), text: text, proposedID: "x")
        ledger.register(source: .document("y"), text: text, proposedID: "y")
        let r = ledger.register(source: .document("y"), text: Self.essay(7), proposedID: "y")
        XCTAssertEqual(r.decision, .ingest(canonicalID: "y"))
        XCTAssertEqual(ledger.canonicals.count, 2)
        XCTAssertEqual(ledger.sources(of: "x"), [.document("x")])
    }

    // MARK: Knowledge base integration

    func testKnowledgeBaseStoresDuplicateOnceAndResolvesAlias() {
        var kb = CourseKnowledgeBase()
        let text = Self.essay(8)
        XCTAssertTrue(kb.upsert(doc("note:file:History of Economics/Hoe week 1.pdf", text, title: "Hoe week 1")))
        XCTAssertFalse(kb.upsert(doc("note:file:Backup copy/Hoe week 1.pdf", text, title: "Hoe week 1 copy")))
        XCTAssertEqual(kb.documents(moduleCode: nil).count, 1)
        XCTAssertEqual(kb.document(id: "note:file:Backup copy/Hoe week 1.pdf")?.id, "note:file:History of Economics/Hoe week 1.pdf")
        XCTAssertEqual(kb.sources(ofDocument: "note:file:History of Economics/Hoe week 1.pdf").count, 2)
        let hits = kb.search("Ricardo rent wage", limit: 20)
        XCTAssertEqual(Set(hits.map(\.document.id)).count, 1)
    }

    func testUpdatedVersionReplacesOldChunks() {
        var kb = CourseKnowledgeBase()
        kb.upsert(doc("ele-cm-5", Self.essay(9) + " zanzibarquokka"))
        XCTAssertFalse(kb.search("zanzibarquokka", limit: 5).isEmpty)
        kb.upsert(doc("ele-cm-5", Self.essay(10) + " platypusharmonic"))
        XCTAssertTrue(kb.search("zanzibarquokka", limit: 5).isEmpty)
        XCTAssertFalse(kb.search("platypusharmonic", limit: 5).isEmpty)
        XCTAssertEqual(kb.documents(moduleCode: nil).count, 1)
    }

    func testExplicitSourceForDriveAndTypedNotes() {
        var kb = CourseKnowledgeBase()
        let text = Self.essay(11)
        let a = kb.ingest(doc("drive-abc", text), source: IngestionSource(kind: .drive, id: "abc"))
        let b = kb.ingest(doc("drive-def", text), source: IngestionSource(kind: .drive, id: "def"))
        XCTAssertEqual(a, .ingest(canonicalID: "drive-abc"))
        XCTAssertEqual(b, .duplicate(canonicalID: "drive-abc"))
        kb.remove(source: IngestionSource(kind: .drive, id: "abc"))
        XCTAssertNotNil(kb.document(id: "drive-abc"))
        kb.remove(source: IngestionSource(kind: .drive, id: "def"))
        XCTAssertNil(kb.document(id: "drive-abc"))
    }

    func testLedgerPersistsAndLegacyStoresAreBackfilled() throws {
        var kb = CourseKnowledgeBase()
        let text = Self.essay(12)
        kb.upsert(doc("a", text))
        kb.upsert(doc("b", text))
        let data = try JSONEncoder().encode(kb)
        let back = try JSONDecoder().decode(CourseKnowledgeBase.self, from: data)
        XCTAssertEqual(back.ingestion, kb.ingestion)

        // A file from before the ledger, holding two copies: decoding keeps one.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["ingestion"] = nil
        var docs = try XCTUnwrap(json["documents"] as? [String: Any])
        var copy = try XCTUnwrap(docs["a"] as? [String: Any])
        copy["id"] = "b"
        docs["b"] = copy
        json["documents"] = docs
        let legacy = try JSONDecoder().decode(CourseKnowledgeBase.self,
                                              from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.documents(moduleCode: nil).count, 1)
        XCTAssertEqual(legacy.document(id: "b")?.id, "a")
    }

    func testSourceKindInference() {
        XCTAssertEqual(IngestionSourceKind.infer(fromDocumentID: "note:typed:Stats/Week 1.rtfd"), .typedNote)
        XCTAssertEqual(IngestionSourceKind.infer(fromDocumentID: "note:file:HoE/Hoe week 1.pdf"), .notability)
        XCTAssertEqual(IngestionSourceKind.infer(fromDocumentID: "ele-cm-12"), .ele)
        XCTAssertEqual(IngestionSourceKind.infer(fromDocumentID: "ed-123"), .ed)
    }
}
