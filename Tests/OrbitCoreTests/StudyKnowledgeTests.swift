import XCTest
@testable import OrbitCore

final class OpenCodeModelTests: XCTestCase {
    let providersJSON = """
    {"providers":[
      {"id":"opencode","name":"OpenCode","models":{
        "big-pickle":{"id":"big-pickle","name":"Big Pickle","cost":{"input":0,"output":0}},
        "muse-spark-1-3":{"id":"muse-spark-1-3","name":"Muse Spark 1.3","cost":{"input":1,"output":2},"variants":{"high":{},"xhigh":{}}},
        "muse-spark-1.3.1":{"id":"muse-spark-1.3.1","name":"Muse Spark 1.3.1","cost":{"input":1,"output":2}}
      }},
      {"id":"other","models":{"muse-spark-11.3":{"name":"Muse Spark 11.3"}}}
    ],"default":{"opencode":"big-pickle"}}
    """

    func testParsesOptionsWithVariants() throws {
        let opts = try OpenCodeProvider.modelOptions(from: Data(providersJSON.utf8))
        XCTAssertEqual(opts.count, 4)
        XCTAssertEqual(opts.first { $0.ref.modelID == "muse-spark-1-3" }?.variants, ["high", "xhigh"])
    }

    func testResolvesMuseSparkLoosely() throws {
        let opts = try OpenCodeProvider.modelOptions(from: Data(providersJSON.utf8))
        XCTAssertEqual(OpenCodeModelResolver.resolve(saved: "", options: opts)?.string, "opencode/muse-spark-1-3")
        XCTAssertEqual(OpenCodeModelResolver.resolve(saved: "opencode/big-pickle", options: opts)?.string, "opencode/big-pickle")
        // Saved model gone from the server → preferred model.
        XCTAssertEqual(OpenCodeModelResolver.resolve(saved: "x/gone", options: opts)?.string, "opencode/muse-spark-1-3")
        // Server unreachable → the saved string.
        XCTAssertEqual(OpenCodeModelResolver.resolve(saved: "x/gone", options: [])?.string, "x/gone")
        XCTAssertNil(OpenCodeModelResolver.resolve(saved: nil, options: []))
    }

    func testVariant() {
        let m = OpenCodeModelOption(ref: .init(providerID: "a", modelID: "b"), name: "b", variants: ["high", "XHigh"])
        XCTAssertEqual(OpenCodeModelResolver.variant(saved: nil, option: m), "XHigh")
        XCTAssertEqual(OpenCodeModelResolver.variant(saved: "high", option: m), "high")
        XCTAssertNil(OpenCodeModelResolver.variant(saved: "low", option: m))
        XCTAssertEqual(OpenCodeModelResolver.variant(saved: "", option: nil), "xhigh")
        XCTAssertNil(OpenCodeModelResolver.variant(saved: "none", option: nil))
    }

    func testPromptBodyCarriesVariant() throws {
        let body = OpenCodeProvider.PromptBody(model: .init(providerID: "p", modelID: "m"), variant: "xhigh", system: nil,
                                               tools: [:], parts: [.text("hi")])
        let json = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        XCTAssertTrue(json.contains("\"variant\":\"xhigh\""))
    }
}

final class KnowledgeStoreTests: XCTestCase {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("orbit-ks-\(UUID().uuidString)")
    }

    func kb() -> CourseKnowledgeBase {
        var kb = CourseKnowledgeBase()
        kb.upsert(CourseDocument(id: "d1", moduleCode: "STAT", week: 3, kind: .slides, title: "Regression",
                                 text: "Ordinary least squares regression estimates the slope coefficient from covariance over variance."))
        kb.upsert(CourseDocument(id: "d2", moduleCode: "MATH", week: 3, kind: .slides, title: "Lagrange",
                                 text: "Constrained optimisation with a Lagrange multiplier: maximise utility subject to a budget constraint."))
        return kb
    }

    func testRoundTripAndIncremental() throws {
        let store = KnowledgeStore(directory: tempDir())
        var k = kb()
        XCTAssertFalse(k.upsert(k.document(id: "d1")!), "unchanged text is skipped")
        try store.save(k, .courseKnowledge)
        var p = StudentProfile()
        p.recordGrade(moduleCode: "STAT", title: "Quiz 1", mark: 78)
        try store.save(p, .profile)
        XCTAssertEqual(store.load(CourseKnowledgeBase.self, .courseKnowledge)?.documents.count, 2)
        XCTAssertEqual(store.load(StudentProfile.self, .profile)?.grades.first?.mark, 78)
        k = store.load(CourseKnowledgeBase.self, .courseKnowledge)!
        XCTAssertEqual(k.search("least squares slope").first?.document.id, "d1")
    }

    func testMigrateLegacy() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = dir.appendingPathComponent("course-knowledge.json")
        try Data("{}".utf8).write(to: legacy)
        let store = KnowledgeStore(directory: dir.appendingPathComponent("Knowledge"))
        XCTAssertTrue(store.migrateLegacy(legacy, to: .courseKnowledge))
        XCTAssertFalse(store.migrateLegacy(legacy, to: .courseKnowledge))
    }

    func testSummariesPendingAndStale() {
        var k = kb()
        k.upsert(CourseDocument(id: "long", moduleCode: "STAT", week: 1, kind: .slides, title: "Long", text: String(repeating: "variance ", count: 80)))
        var s = KnowledgeSummaries()
        XCTAssertEqual(s.pending(in: k).map(\.id), ["long"])
        s.set("- variance", for: k.document(id: "long")!)
        XCTAssertTrue(s.pending(in: k).isEmpty)
        k.upsert(CourseDocument(id: "long", moduleCode: "STAT", week: 1, kind: .slides, title: "Long", text: String(repeating: "mean ", count: 100)))
        XCTAssertEqual(s.pending(in: k).map(\.id), ["long"])
    }

    func testProfileStrengthsAndWeaknesses() {
        var p = StudentProfile()
        for _ in 0..<4 { p.recordAttempt(topic: "Elasticity", correct: true) }
        for _ in 0..<3 { p.recordAttempt(topic: "Lagrange", correct: false) }
        XCTAssertEqual(p.strengths.map(\.topic), ["Elasticity"])
        XCTAssertEqual(p.weakTopics.map(\.topic), ["Lagrange"])
        p.remember("Prefers worked examples"); p.remember("prefers worked examples")
        XCTAssertEqual(p.notes.count, 1)
        XCTAssertTrue(p.promptSummary().contains("Needs work on: Lagrange"))
    }

    func testContextBuildAndRouterInjection() async throws {
        let k = kb()
        let ctx = KnowledgeContext.build(query: "how does regression work", knowledge: k, profile: StudentProfile(), graph: ConceptGraph())
        XCTAssertTrue(ctx.contains("Regression"))
        XCTAssertTrue(ctx.contains("Cross-module links"))

        let seen = SeenBox()
        let router = LLMRouter(providers: [MockLLMProvider { req in
            seen.set(req.messages.map(\.text).joined(separator: "\n")); return "ok"
        }])
        await router.setContextProvider { _ in "CTX-HERE" }
        _ = try await router.complete(system: "sys", user: "hi", purpose: .chat)
        XCTAssertTrue(seen.value.contains(KnowledgeContext.marker + "\nCTX-HERE"))
        _ = try await router.complete(LLMRequest(messages: [.user("x")], purpose: .bulk))
        XCTAssertFalse(seen.value.contains("CTX-HERE"))
    }
}

final class SeenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v = ""
    var value: String { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ s: String) { lock.lock(); v = s; lock.unlock() }
}

final class ConceptGraphTests: XCTestCase {
    func testSeedAndWeb() {
        let g = ConceptGraph()
        let web = g.web(forTopics: ["Simple linear regression and OLS"])
        XCTAssertTrue(web.focus.contains { $0.id == "regression" })
        XCTAssertTrue(web.crossModule.contains { $0.touches("demand") || $0.touches("galton") })
        XCTAssertEqual(EconStrand.classify(name: "Introduction to Statistics"), .statistics)
        XCTAssertEqual(EconStrand.classify(name: "History of Economics"), .history)
        XCTAssertEqual(EconStrand.classify(name: "Mathematics for Economists"), .maths)
        XCTAssertEqual(EconStrand.classify(name: "Economics 1"), .economics)
    }

    func testLearnsAndPersists() {
        var g = ConceptGraph()
        let added = g.addProposed(ConceptGraph.parseProposed("""
        ```json
        {"links":[{"from":"Index numbers","to":"Adam Smith and the invisible hand","relation":"prices as signals"},
                  {"from":"Utility theory of Bentham","to":"Consumer choice","relation":"utilitarian roots","fromModule":"history"}]}
        ```
        """))
        XCTAssertEqual(added, 2)
        let n = g.learnCoOccurrence(from: ["regression and elasticity", "a regression gives the elasticity"])
        XCTAssertGreaterThanOrEqual(n, 0)
        let reloaded = ConceptGraph(learned: g.learned)
        XCTAssertEqual(reloaded.links.count, g.links.count)
        XCTAssertTrue(reloaded.concepts.values.contains { $0.strand == .history && $0.name.contains("Bentham") })
    }
}

final class PracticeTests: XCTestCase {
    let sheet = """
    Problem Set 2
    Question 1. The demand for apples is Q = 100 - 2P and supply is Q = 20 + 2P. Find the equilibrium price and quantity.
    Question 2. Alice has utility U = xy and income 60. Prices are 2 and 3. Use a Lagrangian to find her demands (a) x (b) y.
    Question 3. In 2019 the price elasticity of demand was 0.5. Explain what this means for revenue when price rises by 10%.
    """

    func testExtractAndTwist() {
        let qs = QuestionExtractor.extract(sheet)
        XCTAssertEqual(qs.count, 3)
        let t = QuestionTwister.twist(QuestionExtractor.stripLabel(qs[0]), seed: 7)
        XCTAssertNotEqual(t.text, QuestionExtractor.stripLabel(qs[0]))
        XCTAssertFalse(t.text.lowercased().contains("apples"))
        let y = QuestionTwister.twist(qs[2], seed: 3)
        XCTAssertTrue(y.text.contains("2019"), "years stay")
        let reverted = QuestionTwister.replaceWord(t.changes.last!.components(separatedBy: " → ")[1], with: "apples", in: t.text)
        XCTAssertEqual(QuestionFingerprint.hash(reverted), QuestionFingerprint.hash(qs[0]), "numbers don't change the fingerprint")
    }

    func testDedupAgainstDone() {
        var ledger = PracticeLedger()
        ledger.record("Find the equilibrium when demand is Q = 50 - P and supply Q = 10 + P for apples in the market.", moduleCode: "ECON", done: true)
        XCTAssertTrue(ledger.isDuplicate("Find the equilibrium when demand is Q = 80 - 3P and supply Q = 12 + P for apples in the market."))
        XCTAssertFalse(ledger.isDuplicate("Explain the prisoner's dilemma with a payoff matrix."))
    }

    func testBuildSetSkipsDoneAndRendersMarkdown() {
        var ledger = PracticeLedger()
        let qs = QuestionExtractor.extract(sheet)
        ledger.record(qs[1], moduleCode: "ECON", done: true)
        let src = PracticeSource(title: "Problem Set 2", moduleCode: "ECON", week: 2, kind: .problemSet, text: sheet)
        let set = PracticeGenerator.build(PracticeRequest(kind: .examStyle, moduleCode: "ECON", moduleName: "Economics 1",
                                                          topics: ["demand"], count: 5, seed: 42),
                                          sources: [src], ledger: ledger, graph: ConceptGraph())
        XCTAssertEqual(set.questions.count, 2)
        XCTAssertFalse(set.questions.contains { $0.text.contains("Lagrangian") })
        XCTAssertTrue(set.questions.allSatisfy { $0.marks != nil })
        let md = set.markdown()
        XCTAssertTrue(md.contains("## Question 1"))
        XCTAssertTrue(md.contains("Time allowed"))
        XCTAssertTrue(set.solutionsMarkdown().contains("Worked solutions"))

        var s2 = set
        PracticeGenerator.apply(aiReply: #"{"questions":[{"text":"New Q1","solution":"Step 1…"},{"text":"New Q2","solution":"S2"}]}"#, to: &s2, ledger: ledger)
        XCTAssertEqual(s2.questions[0].solution, "Step 1…")
        XCTAssertEqual(s2.questions[0].text, "New Q1")
    }

    func testPaths() {
        let u = PracticePaths.directory(documents: URL(fileURLWithPath: "/Docs"), moduleCode: "BEE1025", moduleName: "Stats")
        XCTAssertEqual(u.path, "/Docs/Orbit Notes/Practice/BEE1025 Stats")
    }

    func testDriveHelpers() {
        XCTAssertEqual(GoogleDriveUploader.folderQuery(name: "O'rbit", parent: nil),
                       "mimeType='application/vnd.google-apps.folder' and name='O\\'rbit' and trashed=false and 'root' in parents")
        let body = GoogleDriveUploader.multipartBody(name: "a.pdf", parent: "p1", mime: "application/pdf", data: Data("PDF".utf8), boundary: "B")
        let s = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(s.hasPrefix("--B\r\n"))
        XCTAssertTrue(s.contains("\"parents\":[\"p1\"]"))
        XCTAssertTrue(s.hasSuffix("--B--\r\n"))
        XCTAssertTrue(OAuthConfig.googleScopes.contains("https://www.googleapis.com/auth/drive.file"))
    }
}

final class ReadingLibraryTests: XCTestCase {
    func testPlanFitsSlotAndPrioritisesEssential() {
        var lib = ReadingLibrary()
        lib.merge([
            .init(id: "e1", moduleCode: "ECON", title: "Varian ch. 5 (pp. 1-10)", importance: .essential, week: 2),
            .init(id: "r1", moduleCode: "ECON", title: "Recommended article", importance: .recommended, week: 2),
            .init(id: "old", moduleCode: "ECON", title: "Old", importance: .essential, week: 2, read: true),
        ])
        let plan = DailyReadingPlan.make(library: lib, currentWeek: 2, start: Date(timeIntervalSince1970: 1_790_000_000), dayCount: 5)
        XCTAssertEqual(plan.days.count, 5)
        XCTAssertEqual(plan.days[0].items.first?.entryID, "e1")
        XCTAssertTrue(plan.days.allSatisfy { $0.minutes <= 20 })
        XCTAssertFalse(plan.days.flatMap(\.items).contains { $0.entryID == "old" })
        lib.setRead("e1", true)
        lib.merge([.init(id: "e1", moduleCode: "ECON", title: "Varian ch. 5 (pp. 1-10)", importance: .recommended)])
        XCTAssertTrue(lib.entries["e1"]!.read)
        XCTAssertEqual(lib.entries["e1"]!.importance, .essential)
    }

    func testReadingAround() {
        let s = ReadingAroundCatalog.suggestions(for: ConceptGraph(), topics: ["Comparative advantage and Ricardo"])
        XCTAssertTrue(s.contains { $0.id == "ricardo-ch7" })
    }
}

final class CoachingAndCoverageTests: XCTestCase {
    func testTeachBack() {
        var p = StudentProfile()
        for _ in 0..<2 { p.recordAttempt(topic: "Hypothesis testing", moduleCode: "STAT", correct: false) }
        let topics = TeachBack.pickTopics(profile: p, thisWeek: [("ECON", "Elasticity")], done: TeachBackLog())
        XCTAssertEqual(topics.map(\.topic), ["Hypothesis testing", "Elasticity"])
        let r = TeachBack.parse(#"{"score":55,"gaps":["p-values"],"misconceptions":["p is P(H0 true)"],"flashcards":[{"front":"p-value?","back":"P(data|H0)"}]}"#,
                                topic: topics[0], explanation: "…")
        XCTAssertEqual(r?.score, 55)
        TeachBack.apply(r!, to: &p)
        XCTAssertTrue(p.notes.first!.contains("Misconception"))
    }

    func testThinkingPartnerNeverDrafts() {
        let s = ThinkingPartner.systemPrompt(mode: .draftCheck, topic: "Smith vs Marx", crossLinks: ["a"], sources: ["b"], criteria: "Argument 40%")
        XCTAssertTrue(s.contains("NEVER write essay prose"))
        XCTAssertTrue(s.contains("Argument 40%"))
        XCTAssertTrue(ThinkingPartner.looksLikeDraftedProse("Introduction: blah\n\nConclusion: blah"))
        XCTAssertFalse(ThinkingPartner.looksLikeDraftedProse("What do you mean by value? Which evidence?"))
    }

    func testCrossModuleHints() {
        var kb = CourseKnowledgeBase()
        var snap = ELEWebSnapshot()
        snap.modules = [ELEWebCourse(id: 1, fullName: "Mathematics for Economists", shortName: "BEE1026_A_1_202627", viewURL: "u"),
                        ELEWebCourse(id: 2, fullName: "Economics 1", shortName: "BEE1027_A_1_202627", viewURL: "u")]
        kb.update(from: snap)
        kb.upsert(CourseDocument(id: "m", moduleCode: snap.modules[0].moduleCode, week: 3, kind: .slides, title: "Lecture 5",
                                 text: "Constrained optimisation using the Lagrange multiplier method."))
        let hints = CrossModule.hints(for: "Consumer choice: utility maximisation with a budget constraint", moduleCode: snap.modules[1].moduleCode,
                                      kb: kb, graph: ConceptGraph())
        XCTAssertTrue(hints.contains { $0.week == 3 && $0.line.contains("wk3") }, "\(hints)")
    }

    func testCoverageAndExtraChanges() {
        let items = [ELEWebItem(cmid: 1, name: "Book", kind: .book, url: "https://ele/mod/book/view.php?id=1"),
                     ELEWebItem(cmid: 2, name: "Quiz", kind: .quiz, url: "https://ele/mod/quiz/view.php?id=2"),
                     ELEWebItem(cmid: 3, name: "Reading list", kind: .url, role: .readingList, url: "https://exeter.rl.talis.com/lists/abc.html", text: "Module reading")]
        var old = ELEWebSnapshot()
        old.contents["ECON"] = ELEWebCourseContent(courseID: 9, moduleCode: "ECON", sections: [ELEWebSection(title: "Week 1", kind: .week, week: 1, items: items)])
        var new = old
        var renamed = items
        renamed[1].name = "Quiz 1 (practice)"
        new.contents["ECON"] = ELEWebCourseContent(courseID: 9, moduleCode: "ECON", sections: [
            ELEWebSection(title: "Week 1", kind: .week, week: 1, items: Array(renamed.prefix(2))),
            ELEWebSection(title: "Week 2", kind: .week, week: 2, items: [ELEWebItem(cmid: 4, name: "Slides", kind: .resource)]),
        ])
        let kb = CourseKnowledgeBase()
        let targets = ELECoverage.targets(kb: kb, snap: new)
        XCTAssertTrue(targets.contains { $0.itemKind == .book })
        XCTAssertEqual(ELECoverage.fetchURL(for: targets.first { $0.itemKind == .book }!)?.absoluteString,
                       "https://ele.exeter.ac.uk/mod/book/tool/print/index.php?id=1")
        XCTAssertEqual(ELECoverage.readingListLinks(old).first?.url, "https://exeter.rl.talis.com/lists/abc.html")
        XCTAssertEqual(ELECoverage.inlineDocuments(snap: old, kb: kb).first?.kind, .readingList)
        let changes = ELECoverage.extraChanges(from: old, to: new)
        XCTAssertTrue(changes.contains { $0.title.hasPrefix("Renamed") })
        XCTAssertTrue(changes.contains { $0.title.hasPrefix("Removed") })
        XCTAssertTrue(changes.contains { $0.title == "New section: Week 2" })
    }
}
