import Foundation
import SwiftData
import OrbitCore

extension FeatureHub {
    // MARK: Material

    /// Slides/handouts from the course knowledge base, plus the student's own notes.
    func studyMaterials() -> [StudyMaterial] {
        var out: [StudyMaterial] = []
        if let brain {
            for doc in brain.academic.knowledge.documents.values {
                let kind: StudyMaterial.Kind
                switch doc.kind {
                case .slides: kind = .slides
                case .handout: kind = .handout
                default: continue
                }
                out.append(StudyMaterial(id: "doc:" + doc.id, moduleCode: doc.moduleCode, week: doc.week, title: doc.title,
                                         text: doc.text, kind: kind))
            }
            for note in brain.local.allNotes() where note.hasTyped || !note.allText.isEmpty {
                out.append(StudyMaterial(note: note))
            }
        }
        out += studyMaterialProvider?() ?? []
        // Newest weeks first so this week's lectures get cards before old ones.
        return out.sorted { ($0.week ?? 0, $0.id) > ($1.week ?? 0, $1.id) }
    }

    // MARK: Generation

    /// Every 6 hours, a few pieces of new material are turned into cards (local AI only).
    func generateFlashcardsIfDue(now: Date) async {
        guard FeatureSettings.bool(FeatureSettings.flashcardGenerationEnabled, default: true) else { return }
        if let last = state.lastFlashcardRun, now.timeIntervalSince(last) < 6 * 3600 { return }
        state.lastFlashcardRun = now
        await generateFlashcards(maxMaterials: 4)
    }

    /// Makes cards from material that hasn't been processed (or changed). Notes that
    /// already got cards when they synced are marked processed without a second pass.
    func generateFlashcards(maxMaterials: Int = 8) async {
        guard !generatingFlashcards, let context, let router else { return }
        generatingFlashcards = true
        defer { generatingFlashcards = false }
        var existing = context.all(StoredFlashcard.self).map(\.value)
        let withCards = Set(existing.compactMap(\.noteID))
        var pending = FlashcardGenerator.pending(studyMaterials(), processed: state.processedMaterials)
        // Notes get cards on sync (Brain+Notes); don't make a second set for the same note.
        for m in pending where m.kind == .notes && withCards.contains(String(m.id.dropFirst("note:".count))) {
            state.processedMaterials[m.id] = m.fingerprint
        }
        pending.removeAll { state.processedMaterials[$0.id] == $0.fingerprint }
        guard !pending.isEmpty else { flashcardStatus = "Up to date"; return }
        var made = 0
        for material in pending.prefix(maxMaterials) {
            flashcardStatus = "Making cards from “\(material.title)”…"
            do {
                let cards = try await FlashcardGenerator.cards(from: material, existing: existing, router: router,
                                                               count: material.kind == .slides ? 10 : 6)
                for card in cards where context.record(StoredFlashcard.self, id: card.id.uuidString) == nil {
                    context.insert(StoredFlashcard(card: card))
                    state.cardMeta[card.id.uuidString] = FlashcardMeta(cardID: card.id, week: material.week, sourceID: material.id,
                                                                       sourceKind: material.kind, createdAt: Date())
                    existing.append(card)
                    made += 1
                }
                state.processedMaterials[material.id] = material.fingerprint
            } catch {
                OrbitLog.log("flashcards", "couldn't make cards from \(material.id): \(error)")
                flashcardStatus = "The local AI isn't available; will try again later."
                break
            }
        }
        context.saveQuietly()
        save()
        if made > 0 {
            flashcardStatus = "Made \(made) new card\(made == 1 ? "" : "s")"
            OrbitLog.log("flashcards", "made \(made) cards")
        }
    }

    // MARK: Review

    var allCards: [Flashcard] { context?.all(StoredFlashcard.self).map(\.value) ?? [] }

    func dailyReviewPlan(now: Date = Date()) -> DailyReviewPlan {
        FlashcardDeck.dailyReview(allCards, now: now, endOfDay: cal.endOfDay(now))
    }

    func week(of card: Flashcard) -> Int? { state.cardMeta[card.id.uuidString]?.week }

    /// Grades a card (Again/Hard/Good/Easy) and completes today's review task once the session is done.
    func review(_ card: Flashcard, answer: ReviewAnswer, now: Date = Date()) {
        guard let context, let stored = context.record(StoredFlashcard.self, id: card.id.uuidString) else { return }
        stored.apply(FlashcardDeck.review(stored.value, answer: answer, now: now))
        var meta = state.cardMeta[card.id.uuidString]
            ?? FlashcardMeta(cardID: card.id, week: nil, sourceID: card.noteID ?? "", sourceKind: .notes, createdAt: now)
        meta.reviews += 1
        if answer == .again { meta.lapses += 1 }
        state.cardMeta[card.id.uuidString] = meta
        let day = cal.format(now, "yyyy-MM-dd")
        state.reviewedToday = [day: (state.reviewedToday[day] ?? 0) + 1]
        stats.recordReview(now: now)
        context.saveQuietly()
        completeReviewTaskIfDone(now: now)
    }

    static func reviewTaskID(day: String) -> UUID { StableUUID.make("orbit-flashcard-review|\(day)") }

    /// Puts a "10-minute flashcard review" to-do on today's plan (once a day, if cards are due).
    func ensureDailyFlashcardReview(now: Date) async {
        guard FeatureSettings.bool(FeatureSettings.dailyReviewTaskEnabled, default: true), let context else { return }
        let day = cal.format(now, "yyyy-MM-dd")
        guard state.lastReviewTaskDay != day, cal.minuteOfDay(now) >= max(0, prefs.morningBriefTime - 30) else { return }
        state.lastReviewTaskDay = day
        let plan = dailyReviewPlan(now: now)
        guard plan.dueCount > 0 else { return }
        let id = Self.reviewTaskID(day: day)
        guard context.record(StoredTask.self, id: id.uuidString) == nil else { return }
        let minutes = max(5, plan.estimatedMinutes)
        let task = OrbitTask(id: id, title: "Flashcard review (\(plan.sessionCards.count) cards)",
                             notes: "Orbit's daily \(minutes)-minute review. Open Flashcards → Review.",
                             estimateMinutes: minutes, deadline: cal.date(minute: prefs.workCutoff, of: now),
                             earliestStart: now, priority: .normal, energy: .low, source: .notes,
                             sourceRef: "flashcards:\(day)", minBlockMinutes: minutes, maxBlockMinutes: minutes)
        context.insert(StoredTask(task: task))
        context.saveQuietly()
        tasksChanged()
        OrbitLog.log("flashcards", "daily review task: \(plan.sessionCards.count) of \(plan.dueCount) due")
    }

    private func completeReviewTaskIfDone(now: Date) {
        let day = cal.format(now, "yyyy-MM-dd")
        guard let context, let task = context.record(StoredTask.self, id: Self.reviewTaskID(day: day).uuidString),
              task.completedAt == nil else { return }
        let dueLeft = FlashcardDeck.dueCount(allCards, by: now)
        let reviewed = state.reviewedToday[day] ?? 0
        if dueLeft == 0 || reviewed >= 20 {
            task.minutesDone = task.estimateMinutes
            task.completedAt = now
            task.updatedAt = now
            context.saveQuietly()
            tasksChanged()
        }
    }

    // MARK: Assistant

    func flashcardsDueText(module: String?, limit: Int) -> String {
        let now = Date()
        let plan = dailyReviewPlan(now: now)
        var cards = SpacedRepetition.dueCards(allCards, now: cal.endOfDay(now), moduleCode: module, limit: limit)
        if cards.isEmpty { cards = Array(allCards.filter { module == nil || $0.moduleCode == module }.shuffled().prefix(limit)) }
        guard !cards.isEmpty else { return "No flashcards yet." }
        var lines = ["\(plan.dueCount) card\(plan.dueCount == 1 ? "" : "s") due today" + (plan.briefLine.map { "; \($0)" } ?? "") + "."]
        lines += cards.map { c in
            let week = self.week(of: c).map { " week \($0)" } ?? ""
            return "Q: \(c.front)\nA: \(c.back)" + (c.moduleCode.map { " [\($0)\(week)]" } ?? "")
        }
        return lines.joined(separator: "\n\n")
    }
}
