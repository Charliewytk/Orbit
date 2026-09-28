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
        let modules = Array(Set(cards.compactMap(\.moduleCode))).sorted()
        List {
            todaySection(hub.dailyReviewPlan())
            generateSection
            deckSection(filtered(cards))
        }
        .orbitScreen()
        .searchable(text: $search, prompt: "Search cards")
        .toolbar {
            Picker("Module", selection: $module) {
                Text("All modules").tag(String?.none)
                ForEach(modules, id: \.self) { Text($0).tag(String?.some($0)) }
            }
        }
        .navigationTitle("Flashcards")
        .sheet(isPresented: $reviewing) {
            DeckReviewView(module: module).frame(minWidth: 560, minHeight: 420)
        }
    }

    private func filtered(_ cards: [Flashcard]) -> [Flashcard] {
        cards.filter { c in
            (module == nil || c.moduleCode == module)
                && (search.isEmpty || c.front.localizedCaseInsensitiveContains(search)
                    || c.back.localizedCaseInsensitiveContains(search))
        }
        .sorted { $0.due < $1.due }
    }

    @ViewBuilder
    private func todaySection(_ plan: DailyReviewPlan) -> some View {
        Section {
            HStack(alignment: .center, spacing: Theme.Space.l) {
                ZStack {
                    ProgressRing(progress: plan.dueCount == 0 ? 1 : 0.08, color: Destination.review.color, lineWidth: 7)
                    Text("\(plan.dueCount)").font(Theme.number(22)).foregroundStyle(Theme.textPrimary)
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.dueCount == 0 ? "Nothing due today" : "\(plan.dueCount) due today")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(plan.briefLine ?? "New cards appear as your notes and slides sync.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { reviewing = true } label: { Label("Start review", systemImage: "play.fill") }
                    .orbitGlassProminentButton(Destination.review.color)
                    .controlSize(.large)
                    .disabled(plan.dueCount == 0)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            .padding(.vertical, 4)
            if !plan.byModule.isEmpty {
                Text(moduleSummary(plan.byModule))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func moduleSummary(_ byModule: [String: Int]) -> String {
        let parts: [String] = byModule.keys.sorted().map { key in "\(key): \(byModule[key] ?? 0)" }
        return parts.joined(separator: "   ")
    }

    private var generateSection: some View {
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
    }

    private func deckSection(_ shown: [Flashcard]) -> some View {
        Section("\(shown.count) card\(shown.count == 1 ? "" : "s")") {
            ForEach(shown) { card in
                CardRow(card: card)
            }
        }
    }
}

private struct CardRow: View {
    let card: Flashcard
    private var hub: FeatureHub { .shared }

    var body: some View {
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

/// Review session: front → Space shows the answer → 1 Again · 2 Hard · 3 Good · 4 Easy.
struct DeckReviewView: View {
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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(queue.isEmpty ? "Review" : "\(queue.count) left")
                    .font(Theme.number(15))
                    .contentTransition(.numericText())
                if done > 0 {
                    Tag(text: "\(done) done", color: Theme.success, systemImage: "checkmark")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .orbitGlassButton()
                    .keyboardShortcut(.cancelAction)
            }
            if let card = current {
                FlipCard(revealed: revealed, front: {
                    VStack(alignment: .leading, spacing: 12) {
                        meta(card)
                        Spacer(minLength: 0)
                        Text(card.front)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Text("Space to flip").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                }, back: {
                    VStack(alignment: .leading, spacing: 12) {
                        meta(card)
                        Text(card.front).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                        Hairline()
                        ScrollView {
                            Text(card.back)
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                })
                .id(card.id)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                .onTapGesture { withAnimation(Motion.smooth) { revealed.toggle() } }
                if revealed {
                    HStack(spacing: 8) {
                        ForEach(ReviewAnswer.allCases) { answer in
                            Button {
                                withAnimation(Motion.smooth) { grade(card, answer) }
                            } label: {
                                VStack(spacing: 2) {
                                    Text("\(answer.rawValue)  \(answer.label)").font(Theme.body.weight(.bold))
                                    Text(FlashcardDeck.intervalLabel(card, answer: answer)).font(.system(size: 11)).opacity(0.8)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                            }
                            .orbitGlassProminentButton(color(answer))
                            .keyboardShortcut(KeyEquivalent(answer.key), modifiers: [])
                        }
                    }
                    .controlSize(.large)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Button { withAnimation(Motion.smooth) { revealed = true } } label: {
                        Label("Show answer", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .orbitGlassButton()
                    .keyboardShortcut(.space, modifiers: [])
                    .controlSize(.large)
                }
            } else {
                Spacer()
                VStack(spacing: Theme.Space.m) {
                    ActivityRings(study: 0, tasks: 0, reviews: done > 0 ? 1 : 0, size: 110)
                    Text(done > 0 ? "Review done" : "Nothing due")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(done > 0 ? "\(done) card\(done == 1 ? "" : "s") reviewed. See you tomorrow." : "No cards are due right now.")
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(24)
        .orbitBackground()
        .onAppear(perform: load)
    }

    private func meta(_ card: Flashcard) -> some View {
        HStack(spacing: 8) {
            ModuleChip(code: card.moduleCode)
            if let w = hub.week(of: card) { Tag(text: "Week \(w)", color: Theme.textSecondary) }
        }
    }

    private func color(_ answer: ReviewAnswer) -> Color {
        switch answer {
        case .again: Theme.danger
        case .hard: Theme.warning
        case .good: Theme.success
        case .easy: Theme.cyan
        }
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

/// A card that flips in 3D between its front and back.
struct FlipCard<Front: View, Back: View>: View {
    var revealed: Bool
    @ViewBuilder var front: Front
    @ViewBuilder var back: Back

    var body: some View {
        ZStack {
            face { front }
                .opacity(revealed ? 0 : 1)
            face { back }
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(revealed ? 1 : 0)
        }
        .rotation3DEffect(.degrees(revealed ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: revealed)
        .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
    }

    private func face<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .orbitGlassCard(radius: Theme.Radius.xl, tint: Destination.review.color)
    }
}
