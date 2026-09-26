import SwiftUI
import OrbitCore

/// Flashcards overview: today's short review, cards per module, and the deck.
struct FlashcardsView: View {
    @State private var search = ""
    @State private var module: String?
    @State private var reviewing = false
    private var hub: FeatureHub { .shared }

    var body: some View {
        let cards = hub.allCards
        let plan = hub.dailyReviewPlan()
        let modules = Array(Set(cards.compactMap(\.moduleCode))).sorted()
        let shown = cards.filter { c in
            (module == nil || c.moduleCode == module)
                && (search.isEmpty || c.front.localizedCaseInsensitiveContains(search) || c.back.localizedCaseInsensitiveContains(search))
        }.sorted { $0.due < $1.due }

        List {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plan.dueCount == 0 ? "Nothing due today" : "\(plan.dueCount) due today")
                            .font(.system(size: 17, weight: .semibold))
                        Text(plan.briefLine ?? "New cards appear as your notes and slides sync.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Start review") { reviewing = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(plan.dueCount == 0)
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                }
                .padding(.vertical, 4)
                if !plan.byModule.isEmpty {
                    Text(plan.byModule.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "   "))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button(hub.generatingFlashcards ? "Making cards…" : "Make cards from new slides and notes") {
                        Task { await hub.generateFlashcards() }
                    }
                    .disabled(hub.generatingFlashcards)
                    Spacer()
                    Text(hub.flashcardStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Cards are made on this Mac by the local AI from ELE lecture slides and your notes, de-duplicated per module.")
            }
            Section("\(shown.count) card\(shown.count == 1 ? "" : "s")") {
                ForEach(shown) { card in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.front)
                        Text(card.back).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        HStack(spacing: 8) {
                            if let m = card.moduleCode { Text(m) }
                            if let w = hub.week(of: card) { Text("Week \(w)") }
                            Text("Due \(hub.cal.shortDay(card.due))")
                        }
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .searchable(text: $search, prompt: "Search cards")
        .toolbar {
            Picker("Module", selection: $module) {
                Text("All modules").tag(String?.none)
                ForEach(modules, id: \.self) { Text($0).tag(String?.some($0)) }
            }
        }
        .navigationTitle("Flashcards")
        .sheet(isPresented: $reviewing) {
            FlashcardReviewView(module: module).frame(minWidth: 560, minHeight: 420)
        }
    }
}

/// Review session: front → Space shows the answer → 1 Again · 2 Hard · 3 Good · 4 Easy.
struct FlashcardReviewView: View {
    var module: String?
    @Environment(\.dismiss) private var dismiss
    @State private var queue: [UUID] = []
    @State private var revealed = false
    @State private var done = 0
    @State private var loaded = false
    private var hub: FeatureHub { .shared }

    private var current: Flashcard? {
        guard let id = queue.first else { return nil }
        return hub.allCards.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(queue.isEmpty ? "Review" : "\(queue.count) left")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let card = current {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        if let m = card.moduleCode { Text(m) }
                        if let w = hub.week(of: card) { Text("Week \(w)") }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(card.front).font(.system(size: 22, weight: .semibold)).textSelection(.enabled)
                    if revealed {
                        Divider()
                        Text(card.back).font(.system(size: 15)).textSelection(.enabled)
                    }
                }
                Spacer()
                if revealed {
                    HStack(spacing: 8) {
                        ForEach(ReviewAnswer.allCases) { answer in
                            Button {
                                grade(card, answer)
                            } label: {
                                VStack(spacing: 2) {
                                    Text("\(answer.rawValue)  \(answer.label)")
                                    Text(FlashcardDeck.intervalLabel(card, answer: answer)).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .keyboardShortcut(KeyEquivalent(answer.key), modifiers: [])
                        }
                    }
                    .controlSize(.large)
                } else {
                    Button("Show answer (Space)") { revealed = true }
                        .keyboardShortcut(.space, modifiers: [])
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Spacer()
                ContentUnavailableView(done > 0 ? "Review done" : "Nothing due",
                                       systemImage: "checkmark.circle",
                                       description: Text(done > 0 ? "\(done) card\(done == 1 ? "" : "s") reviewed. See you tomorrow." : "No cards are due right now."))
                Spacer()
            }
        }
        .padding(24)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let now = Date()
        if module == nil {
            queue = hub.dailyReviewPlan(now: now).sessionCards
        } else {
            queue = SpacedRepetition.dueCards(hub.allCards, now: hub.cal.endOfDay(now), moduleCode: module, limit: 20).map(\.id)
        }
    }

    private func grade(_ card: Flashcard, _ answer: ReviewAnswer) {
        hub.review(card, answer: answer)
        queue.removeFirst()
        // Forgotten cards come back at the end of this session.
        if answer == .again { queue.append(card.id) } else { done += 1 }
        revealed = false
    }
}
