import AppKit
import Foundation
import OrbitCore

// Practice sets (generate → PDFs → Notability / Drive / AirDrop), teach-it-back and Explore.
extension StudyHub {
    // MARK: Practice

    struct PracticeFiles: Hashable {
        var questions: URL
        var solutions: URL
    }

    /// ~/Documents/Orbit Notes (or the typed-notes root chosen in Settings).
    var notesRoot: URL {
        if let custom = MacPrefs.string(MacPrefs.typedNotesRoot) { return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath) }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("Orbit Notes", isDirectory: true)
    }

    func practiceDirectory(_ set: PracticeSet) -> URL {
        let name = "\(set.moduleCode) \(set.moduleName)".components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        return notesRoot.appendingPathComponent("Practice", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    func files(for set: PracticeSet) -> PracticeFiles {
        let dir = practiceDirectory(set)
        return PracticeFiles(questions: dir.appendingPathComponent(set.fileStem + ".pdf"),
                             solutions: dir.appendingPathComponent(set.fileStem + " — solutions.pdf"))
    }

    var notabilityFolder: URL {
        if let custom = MacPrefs.string(MacPrefs.notabilityFolder) { return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath) }
        return notesRoot.appendingPathComponent("For Notability", isDirectory: true)
    }

    static func flag(_ key: String, default value: Bool) -> Bool {
        MacPrefs.defaults.object(forKey: key) == nil ? value : MacPrefs.defaults.bool(forKey: key)
    }

    /// Builds a set from ELE problem sheets / past papers / readings, twists it, has the AI write
    /// worked solutions, and saves both PDFs.
    @discardableResult
    func generatePractice(kind: PracticeSetKind, moduleCode: String, difficulty: PracticeDifficulty?, count: Int = 6) async -> PracticeSet? {
        loadIfNeeded()
        guard let brain, !working else { return nil }
        working = true
        defer { working = false; status = "" }
        brain.academicLoadIfNeeded()
        let kb = brain.academic.knowledge
        status = "Finding questions…"
        let topics: [String]
        let weeks: Set<Int>?
        let h = kb.whatsHappening()
        switch kind {
        case .homework:
            topics = currentTopics().filter { $0.moduleCode == moduleCode }.map(\.topic)
            weeks = h.currentWeek.map { Set(1...max(1, $0.week)) }
        case .getAhead:
            topics = currentTopics(next: true).filter { $0.moduleCode == moduleCode }.map(\.topic)
            weeks = h.nextWeek.map { [$0.week] }
        case .examStyle:
            topics = kb.modules[moduleCode]?.weeks.map(\.title) ?? []
            weeks = nil
        }
        let sources = PracticeSource.from(kb, moduleCode: moduleCode, weeks: weeks)
        var set = PracticeGenerator.build(PracticeRequest(kind: kind, moduleCode: moduleCode, moduleName: moduleName(moduleCode),
                                                          topics: topics, difficulty: difficulty, count: count),
                                          sources: sources, ledger: ledger, graph: graph)
        for hint in topics.prefix(3).flatMap({ CrossModule.hints(for: $0, moduleCode: moduleCode, kb: kb, graph: graph, limit: 2) }) {
            if !set.crossLinks.contains(hint.line) { set.crossLinks.append(hint.line) }
        }
        if let router {
            status = "Writing twists and worked solutions…"
            let context = contextText(query: (topics + set.questions.map(\.text)).joined(separator: "\n").prefix(1500).description, budget: 6000)
            if let reply = try? await router.complete(PracticeGenerator.aiRequest(for: set, context: context, count: count)) {
                PracticeGenerator.apply(aiReply: reply, to: &set, ledger: ledger)
            }
        }
        guard !set.questions.isEmpty else {
            status = ""
            brain.app?.show("No new questions found for \(moduleCode) yet — sync ELE or try another set type.")
            return nil
        }
        PracticeGenerator.record(set, in: &ledger)
        practiceSets.insert(set, at: 0)
        save()
        status = "Saving PDFs…"
        await writeAndDeliver(set)
        return set
    }

    func writeAndDeliver(_ set: PracticeSet) async {
        let f = files(for: set)
        do {
            try FileManager.default.createDirectory(at: f.questions.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PracticePDF.render(set.markdown(), answerSpace: true).write(to: f.questions, options: .atomic)
            try PracticePDF.render(set.solutionsMarkdown()).write(to: f.solutions, options: .atomic)
        } catch {
            brain?.app?.show("Couldn't save the PDFs: \(error.localizedDescription)")
            return
        }
        if Self.flag(MacPrefs.notabilityAutoExport, default: false) { exportForNotability([f.questions, f.solutions]) }
        if Self.flag(MacPrefs.practiceDriveUpload, default: true) {
            await uploadToDrive([f.questions, f.solutions], moduleCode: set.moduleCode)
        }
        brain?.app?.show("Saved \(set.title)")
    }

    func markDone(_ set: PracticeSet, confident: Bool) {
        PracticeGenerator.record(set, in: &ledger, done: true)
        for q in set.questions { profile.recordAttempt(topic: q.topic ?? set.topics.first ?? set.moduleCode, moduleCode: set.moduleCode, correct: confident) }
        save()
    }

    // MARK: Delivery

    /// Opens in Notability if installed, otherwise the default PDF app.
    func openInNotability(_ url: URL) {
        let ws = NSWorkspace.shared
        if let app = ws.urlForApplication(withBundleIdentifier: "com.gingerlabs.Notability") {
            ws.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else {
            ws.open(url)
        }
    }

    /// Copies into the "For Notability" folder (point it at iCloud/Drive so the iPad can import).
    func exportForNotability(_ urls: [URL]) {
        let dir = notabilityFolder
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for u in urls {
            let target = dir.appendingPathComponent(u.lastPathComponent)
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: u, to: target)
        }
    }

    func airDrop(_ urls: [URL]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }

    /// Uploads to Google Drive "Orbit/Practice/<Module>" (drive.file scope).
    func uploadToDrive(_ urls: [URL], moduleCode: String) async {
        guard let brain, brain.accounts.googleConnected, let session = brain.accounts.google else { return }
        let uploader = GoogleDriveUploader(tokens: session)
        for u in urls {
            guard let data = try? Data(contentsOf: u) else { continue }
            do {
                try await uploader.upload(data: data, name: u.lastPathComponent, folderPath: GoogleDriveUploader.practiceFolder(moduleCode: moduleCode))
            } catch {
                if GoogleDriveUploader.isScopeError(error) {
                    brain.app?.show("Reconnect Google in Settings to allow Drive uploads.")
                } else {
                    OrbitLog.log(Self.log, "Drive upload failed: \(error.localizedDescription)")
                }
                return
            }
        }
    }

    // MARK: Reading

    func readingPlan() -> DailyReadingPlan {
        let week = knowledge.whatsHappening().currentWeek?.week
        return DailyReadingPlan.make(library: library, currentWeek: week, start: Date())
    }

    func readingAround() -> [ReadingAroundItem] {
        let read = Set(library.entries.values.filter(\.read).map(\.id).filter { $0.hasPrefix("around-") }.map { String($0.dropFirst(7)) })
        return ReadingAroundCatalog.suggestions(for: graph, topics: currentTopics().map(\.topic), read: read, limit: 6)
    }

    func addAround(_ item: ReadingAroundItem) { library.merge([ReadingAroundCatalog.entry(item)]); save() }

    func setRead(_ id: String, _ read: Bool) {
        if id.hasPrefix("around-"), library.entries[id] == nil,
           let item = ReadingAroundCatalog.items.first(where: { "around-\($0.id)" == id }) {
            library.merge([ReadingAroundCatalog.entry(item)])
        }
        library.setRead(id, read)
        save()
    }

    // MARK: Teach it back

    func teachBackTopics() -> [TeachBackTopic] {
        loadIfNeeded()
        return TeachBack.pickTopics(profile: profile, thisWeek: currentTopics().map { ($0.moduleCode, $0.topic) }, done: teachBack)
    }

    func grade(topic: TeachBackTopic, explanation: String) async -> TeachBackResult? {
        guard let router, !working else { return nil }
        working = true
        defer { working = false }
        let hints = CrossModule.hints(for: topic.topic, moduleCode: topic.moduleCode, kb: knowledge, graph: graph).map(\.line)
        let web = graph.web(forText: topic.topic)
        let links = web.crossModule.map { "\(graph.name($0.from)) ↔ \(graph.name($0.to)): \($0.relation)" }
        let context = contextText(query: topic.topic, budget: 6000)
        guard let reply = try? await router.complete(TeachBack.request(topic: topic, explanation: explanation, context: context,
                                                                         crossLinks: links + hints)),
              let result = TeachBack.parse(reply, topic: topic, explanation: explanation) else { return nil }
        teachBack.add(result)
        TeachBack.apply(result, to: &profile)
        save()
        return result
    }

    // MARK: Explore

    struct ExploreTurn: Identifiable, Hashable {
        var id = UUID()
        var fromStudent: Bool
        var text: String
    }

    func explore(topic: String, moduleCode: String?, mode: ExploreMode, history: [ExploreTurn], draft: String?) async -> String {
        guard let router else { return "The AI isn't available right now." }
        let kb = knowledge
        let hints = CrossModule.hints(for: topic, moduleCode: moduleCode, kb: kb, graph: graph).map(\.line)
        let web = graph.web(forText: topic)
        let links = web.crossModule.prefix(5).map { "\(graph.name($0.from)) ↔ \(graph.name($0.to)): \($0.relation)" }
        let sources = kb.search(topic, moduleCode: moduleCode, limit: 5).map(\.citation)
            + ReadingAroundCatalog.suggestions(for: graph, topics: [topic], limit: 3).map { "\($0.title) — \($0.by)" }
            + library.items(moduleCode: moduleCode).prefix(4).map(\.title)
        var criteria: String?
        if mode == .draftCheck {
            criteria = kb.search("marking criteria assessment " + topic, moduleCode: moduleCode, kinds: [.assessmentBrief, .elePage], limit: 3)
                .map(\.text).joined(separator: "\n")
        }
        var messages: [LLMMessage] = [.system(ThinkingPartner.systemPrompt(mode: mode, topic: topic, crossLinks: links + hints,
                                                                           sources: sources, criteria: criteria))]
        for t in history { messages.append(t.fromStudent ? .user(t.text) : .assistant(t.text)) }
        if let draft, !draft.isEmpty { messages.append(.user("My draft:\n\n\(draft.prefix(12000))")) }
        do {
            let reply = try await router.complete(LLMRequest(messages: messages, purpose: .chat, temperature: 0.6))
            return ThinkingPartner.looksLikeDraftedProse(reply) && mode == .explore ? ThinkingPartner.fallbackQuestion : reply
        } catch {
            return "The AI isn't available right now."
        }
    }
}
