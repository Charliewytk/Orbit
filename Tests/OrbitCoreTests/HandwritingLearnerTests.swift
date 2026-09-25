import XCTest
@testable import OrbitCore

final class HandwritingLearnerTests: XCTestCase {
    /// What Apple Vision might read from the handwriting (with typical slips), and what the student typed below.
    let regionA = "Externalites are costs or benefits to third partys"
    let regionB = "Govt can use Pigouvian tax w/ rate = marginal external cost"
    let regionC = "Eg pollution from factories nearby"
    let typed = """
    Externalities are costs or benefits to third parties
    Government can use a Pigouvian tax with rate equal to marginal external cost
    """

    func testAlignsTypedLinesToTheirHandwritingWindow() {
        let learner = HandwritingLearner()
        let alignments = learner.align(typed: typed, handwriting: [regionA, regionB, regionC])
        XCTAssertEqual(alignments.count, 2)
        XCTAssertEqual(alignments[0].regions, [0])
        XCTAssertEqual(alignments[1].regions, [1])
        XCTAssertGreaterThan(alignments[0].coverage, 0.9)
        let subs = alignments[0].pairs.filter { $0.kind == .substitution }.map { "\($0.ocr)→\($0.typed)" }
        XCTAssertEqual(subs, ["Externalites→Externalities", "partys→parties"])
    }

    func testHarvestsCorrectionsAndAbbreviations() {
        var profile = PersonalHandwritingProfile()
        let report = HandwritingLearner().learn(regions: [.init(id: "a", ocrText: regionA), .init(id: "b", ocrText: regionB)],
                                                typed: typed, into: &profile)
        let harvested = Set(report.substitutions.map { "\($0.kind.rawValue):\($0.ocr)→\($0.correct)" })
        XCTAssertEqual(harvested, [
            "misreading:externalites→externalities",
            "misreading:partys→parties",
            "abbreviation:govt→government",
            "abbreviation:w/→with",
        ])
        XCTAssertEqual(profile.corrections["partys"], ["parties": 1])
        XCTAssertEqual(profile.abbreviations["w/"], ["with": 1])
        XCTAssertTrue(profile.vocabulary.contains("Pigouvian"))
        XCTAssertTrue(profile.vocabulary.contains("externalities"))
        XCTAssertEqual(profile.confirmations["costs"], 1)
        XCTAssertEqual(profile.pagesLearned, 1)
    }

    func testAppliesOnlyRepeatedOrHighConfidenceCorrections() {
        var profile = PersonalHandwritingProfile()
        let learner = HandwritingLearner()
        learner.learn(handwriting: regionA + "\n" + regionB, typed: typed, into: &profile)

        // Seen once: "partys" isn't trusted yet, but "externalites" → a known vocabulary term that looks alike is.
        XCTAssertEqual(profile.apply(to: "Externalites hit third partys."), "Externalities hit third partys.")

        learner.learn(handwriting: "Firms ignore partys affected by w/ pollution", typed: "Firms ignore parties affected by pollution",
                      into: &profile)
        XCTAssertEqual(profile.corrections["partys"]?["parties"], 2)
        XCTAssertEqual(profile.apply(to: "third [?partys], w/ tax"), "third parties, w/ tax", "fixed word loses its doubt marker")
        XCTAssertEqual(profile.apply(to: "[?partys] and [?blah]"), "parties and [?blah]")

        profile.recordAbbreviation("w/", meaning: "with")
        XCTAssertEqual(profile.learnedAbbreviations()["w/"], "with")
        XCTAssertEqual(profile.apply(to: "Govt acts w/ care", expandAbbreviations: true), "Govt acts with care")
    }

    func testConfirmationsBlockBadCorrections() {
        var profile = PersonalHandwritingProfile()
        profile.recordCorrection(ocr: "rose", correct: "rise", count: 2)
        profile.recordConfirmation("rose", count: 3)
        XCTAssertEqual(profile.apply(to: "prices rose"), "prices rose")
    }

    func testMergedAndSplitWords() {
        var profile = PersonalHandwritingProfile()
        let learner = HandwritingLearner()
        for _ in 0..<2 {
            learner.learn(handwriting: "the govern ment spends alot on health", typed: "the government spends a lot on health",
                          into: &profile)
        }
        XCTAssertEqual(profile.corrections["govern ment"], ["government": 2])
        XCTAssertEqual(profile.corrections["alot"], ["a lot": 2])
        XCTAssertEqual(profile.apply(to: "The govern ment spends alot."), "The government spends a lot.")
    }

    func testUnrelatedTypedTextDoesNotAlign() {
        let alignments = HandwritingLearner().align(handwriting: regionA, typed: "Revise for the maths exam on Friday")
        XCTAssertTrue(alignments.isEmpty)
    }

    func testExportsTrainingSamplesForWellCoveredRegions() throws {
        var profile = PersonalHandwritingProfile()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let report = HandwritingLearner().learn(
            regions: [.init(id: "a", ocrText: regionA, image: png), .init(id: "b", ocrText: regionB, image: png),
                      .init(id: "c", ocrText: regionC, image: png)],
            typed: typed, pageID: "p1", into: &profile)
        XCTAssertEqual(report.samples.map(\.regionID), ["a", "b"])
        // Misreadings are fixed; the shorthand stays because that's what the image shows.
        XCTAssertEqual(report.samples[0].text, "Externalities are costs or benefits to third parties")
        XCTAssertEqual(report.samples[1].text, regionB)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-hw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = try HandwritingDataset.write(report.samples, to: dir)
        try HandwritingDataset.write(report.samples, to: dir) // idempotent
        let lines = try String(contentsOf: manifest, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(first["image"] as? String, "images/p1-a.png")
        XCTAssertEqual(first["text"] as? String, "Externalities are costs or benefits to third parties")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("images/p1-a.png").path))
    }

    func testLineLevelSamplesWhenLineImagesMatch() {
        var profile = PersonalHandwritingProfile()
        let region = HandwritingLearner.Region(id: "r", ocrText: "Externalites are costs\nor benefits to third partys",
                                               lineImages: [Data([1]), Data([2])])
        let report = HandwritingLearner().learn(regions: [region], typed: "Externalities are costs or benefits to third parties",
                                                pageID: "p", into: &profile)
        XCTAssertEqual(report.samples.map(\.text), ["Externalities are costs", "or benefits to third parties"])
        XCTAssertEqual(report.samples.map(\.id), ["p-r-l1", "p-r-l2"])
    }

    func testProfileIsCodableAndMerges() throws {
        var a = PersonalHandwritingProfile(vocabulary: ["BEM2031"])
        a.recordCorrection(ocr: "tacks", correct: "tax")
        let data = try JSONEncoder().encode(a)
        var b = try JSONDecoder().decode(PersonalHandwritingProfile.self, from: data)
        XCTAssertEqual(a, b)
        b.merge(a)
        XCTAssertEqual(b.corrections["tacks"]?["tax"], 2)
        XCTAssertEqual(b.apply(to: "Pigouvian tacks"), "Pigouvian tax")
    }

    func testAbbreviationDetection() {
        XCTAssertTrue(TextNormalizer.isAbbreviation("govt", of: "government"))
        XCTAssertTrue(TextNormalizer.isAbbreviation("b/c", of: "because"))
        XCTAssertTrue(TextNormalizer.isAbbreviation("ppl", of: "people"))
        XCTAssertTrue(TextNormalizer.isAbbreviation("&", of: "and"))
        XCTAssertFalse(TextNormalizer.isAbbreviation("tax", of: "taxes"))
        XCTAssertFalse(TextNormalizer.isAbbreviation("cost", of: "price"))
        XCTAssertEqual(TextNormalizer.levenshtein("partys", "parties"), 2)
    }
}
