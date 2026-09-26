import Foundation
import Observation
import OrbitCore

/// The shared study layer across all four modules: long-term memory (knowledge store,
/// summaries, student profile), the concept web, practice sets, reading plan,
/// teach-it-back and the Explore partner. Started from `OrbitBrain.start()`.
@MainActor
@Observable
final class StudyHub {
    static let shared = StudyHub()
    static let log = "study"

    @ObservationIgnored weak var brain: OrbitBrain?
    @ObservationIgnored private var loaded = false

    var profile = StudentProfile()
    var graph = ConceptGraph()
    var ledger = PracticeLedger()
    var library = ReadingLibrary()
    var teachBack = TeachBackLog()
    @ObservationIgnored var summaries = KnowledgeSummaries()
    var practiceSets: [PracticeSet] = []
    var status = ""
    var working = false
    @ObservationIgnored private var state = HubState()

    struct HubState: Codable {
        var lastAILinkWeek: String?
        var practiceSets: [PracticeSet] = []
        var teachBack = TeachBackLog()
    }

    private init() {}

    var store: KnowledgeStore? { brain?.local.knowledgeStore }

    func start(brain: OrbitBrain) {
        self.brain = brain
        loadIfNeeded()
        FeatureHub.shared.studyMaterialProvider = { [weak self] in self?.flashcardMaterials() ?? [] }
    }

    func loadIfNeeded() {
        guard !loaded, let store else { return }
        loaded = true
        profile = store.load(StudentProfile.self, .profile) ?? StudentProfile()
        graph = ConceptGraph(learned: store.load(ConceptGraph.Learned.self, .concepts) ?? .init())
        ledger = store.load(PracticeLedger.self, .practiceLedger) ?? PracticeLedger()
        library = store.load(ReadingLibrary.self, .readingLibrary) ?? ReadingLibrary()
        summaries = store.load(KnowledgeSummaries.self, .summaries) ?? KnowledgeSummaries()
        if let s = brain?.local.load(HubState.self, "study-state.json") {
            state = s
            practiceSets = s.practiceSets
            teachBack = s.teachBack
        }
    }

    func save() {
        guard let store else { return }
        try? store.save(profile, .profile)
        try? store.save(graph.learned, .concepts)
        try? store.save(ledger, .practiceLedger)
        try? store.save(library, .readingLibrary)
        try? store.save(summaries, .summaries)
        state.practiceSets = Array(practiceSets.prefix(60))
        state.teachBack = teachBack
        brain?.local.save(state, "study-state.json")
    }

    var knowledge: CourseKnowledgeBase { brain?.academic.knowledge ?? CourseKnowledgeBase() }
    var router: LLMRouter? { brain?.router }

    // MARK: Context for every AI call

    /// Called by the router (off the main actor) for chat/reasoning requests.
    nonisolated func knowledgeContext(for request: LLMRequest) async -> String? {
        let query = KnowledgeContext.query(for: request)
        return await MainActor.run { self.contextText(query: query) }
    }

    func contextText(query: String, budget: Int = 4000) -> String {
        loadIfNeeded()
        guard let brain else { return "" }
        brain.academicLoadIfNeeded()
        return KnowledgeContext.build(query: query, knowledge: brain.academic.knowledge, profile: profile,
                                      summaries: summaries, graph: graph, budget: budget)
    }

    // MARK: Memory

    func recordGrade(moduleCode: String, title: String, mark: Double, date: Date) {
        loadIfNeeded()
        guard !profile.grades.contains(where: { $0.moduleCode == moduleCode && $0.title == title && $0.mark == mark }) else { return }
        profile.recordGrade(moduleCode: moduleCode, title: title, mark: mark, date: date)
        save()
    }

    // MARK: After each ELE sync

    /// Everything else ELE offers → knowledge store; new-in-ELE events; reading lists; summaries; concept links.
    func afterELESync(_ snap: ELEWebSnapshot, previous: ELEWebSnapshot?) async {
        loadIfNeeded()
        guard let brain else { return }
        for doc in ELECoverage.inlineDocuments(snap: snap, kb: brain.academic.knowledge) { brain.academic.knowledge.upsert(doc) }
        let extra = brain.academic.knowledge.recordActivity(ELECoverage.extraChanges(from: previous, to: snap))
        if !extra.isEmpty { brain.announceActivity(extra) }
        library.merge(ele: snap.contents.values.flatMap(\.readings))
        await refreshReadingLists(snap)
        await learnLinks()
        await summarise(limit: 6)
        brain.saveAcademic()
        save()
    }

    /// Fetches each module's Talis reading list (once a day per list).
    func refreshReadingLists(_ snap: ELEWebSnapshot) async {
        let talis = TalisReadingList()
        for link in ELECoverage.readingListLinks(snap) where TalisReadingList.isTalisURL(link.url) {
            if let last = library.fetchedLists[link.url], Date().timeIntervalSince(last) < 86400 { continue }
            guard let url = URL(string: link.url) else { continue }
            do {
                let entries = try await talis.fetch(listURL: url, moduleCode: link.moduleCode)
                library.merge(talis: entries)
                library.fetchedLists[link.url] = Date()
                let text = entries.map { "\($0.importance.rawValue.capitalized): \($0.item.title)\($0.authors.map { " — \($0)" } ?? "")" }
                    .joined(separator: "\n")
                if !text.isEmpty {
                    brain?.academic.knowledge.upsert(CourseDocument(id: "talis-\(MD5.hex(link.url).prefix(10))", moduleCode: link.moduleCode,
                                                                    week: nil, kind: .readingList, title: "\(link.moduleCode) reading list",
                                                                    url: link.url, text: text))
                }
                OrbitLog.log(Self.log, "reading list \(link.moduleCode): \(entries.count) item(s)")
            } catch {
                OrbitLog.log(Self.log, "reading list \(link.moduleCode) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Co-occurrence links every sync; AI links once a week for this week's topics.
    func learnLinks() async {
        guard let brain else { return }
        let texts = brain.academic.knowledge.documents(moduleCode: nil).filter { $0.kind != .elePage }.prefix(500).map { String($0.text.prefix(4000)) }
        let base = graph
        let docTexts = Array(texts)
        graph = await Task.detached(priority: .utility) { () -> ConceptGraph in
            var copy = base
            copy.learnCoOccurrence(from: docTexts)
            return copy
        }.value

        let week = brain.academic.knowledge.whatsHappening().currentWeek.map { "\($0.term)-\($0.week)" } ?? ""
        guard !week.isEmpty, state.lastAILinkWeek != week, let router else { return }
        let topics = currentTopics().map(\.topic)
        guard !topics.isEmpty else { return }
        let excerpts = topics.prefix(6).compactMap { brain.academic.knowledge.search($0, limit: 1).first?.text }
        if let reply = try? await router.complete(ConceptGraph.linkRequest(topics: topics, excerpts: excerpts)) {
            let n = graph.addProposed(ConceptGraph.parseProposed(reply))
            state.lastAILinkWeek = week
            OrbitLog.log(Self.log, "AI added \(n) concept link(s)")
        }
    }

    /// Short summaries of new/changed documents (local model first).
    func summarise(limit: Int) async {
        guard let brain, let router else { return }
        for doc in summaries.pending(in: brain.academic.knowledge, limit: limit) {
            guard let text = try? await router.complete(KnowledgeSummaries.request(for: doc)) else { break }
            summaries.set(text, for: doc)
        }
        summaries.prune(keeping: Set(brain.academic.knowledge.documents.keys))
    }

    // MARK: Topics

    struct WeekTopic: Hashable { var moduleCode: String; var topic: String }

    /// This week's (or next week's) lecture topics per module.
    func currentTopics(next: Bool = false) -> [WeekTopic] {
        guard let brain else { return [] }
        let h = brain.academic.knowledge.whatsHappening()
        let weeks = next ? h.comingWeek : (h.thisWeek.contains { !$0.isEmpty } ? h.thisWeek : h.comingWeek)
        return weeks.flatMap { o -> [WeekTopic] in
            let items = ([o.title].compactMap { $0 } + o.lectures.prefix(3)).map { cleanTopic($0) }.filter { !$0.isEmpty }
            return Array(Set(items)).sorted().map { WeekTopic(moduleCode: o.moduleCode, topic: $0) }
        }
    }

    private func cleanTopic(_ s: String) -> String {
        s.replacingOccurrences(of: "^\\s*week\\s*\\d+\\s*(?:w\\s*/\\s*c[^:–-]*)?[:–-]?\\s*", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    func moduleName(_ code: String) -> String { knowledge.modules[code]?.name ?? code }
    var moduleCodes: [String] { knowledge.modules.keys.sorted() }

    // MARK: Web

    func web() -> ConceptGraph.Web { graph.web(forTopics: currentTopics().map(\.topic), limit: 14) }

    func hints(for topic: WeekTopic) -> [CrossModuleHint] {
        CrossModule.hints(for: topic.topic, moduleCode: topic.moduleCode, kb: knowledge, graph: graph)
    }

    // MARK: Flashcards from the shared layer

    func flashcardMaterials() -> [StudyMaterial] {
        teachBack.results.prefix(20).compactMap { r in
            let cards = r.flashcards.map { "Q: \($0.front)\nA: \($0.back)" }
            let lines = r.gaps.map { "Gap: \($0)" } + r.misconceptions.map { "Misconception: \($0)" } + r.missingLinks.map { "Link: \($0)" } + cards
            guard !lines.isEmpty else { return nil }
            return StudyMaterial(id: "teachback:\(r.id)", moduleCode: r.moduleCode, title: "Teach-back: \(r.topic)",
                                 text: lines.joined(separator: "\n"), kind: .notes)
        }
    }
}
