import SwiftUI
import SwiftData
import OrbitCore

struct NotesView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \StoredNote.created, order: .reverse) private var notes: [StoredNote]
    @Query private var cards: [StoredFlashcard]
    @Query private var events: [StoredEvent]
    @State private var query = ""
    @State private var hits: [NoteHit] = []
    @State private var searching = false
    @State private var showAsk = false
    @State private var showReview = false
    @State private var moduleFilter: String?

    private var dueCards: [StoredFlashcard] { cards.filter { $0.due <= Date() } }

    private var gaps: [NoteGap] {
        let lectures = events.map(\.value).filter(StudyCoach.isLecture)
        return GapDetector.detect(notes: notes.map(\.stub), lectures: lectures, now: Date(), timeZone: app.prefs.timeZone)
    }

    private var modules: [String] { Array(Set(notes.compactMap(\.moduleCode))).sorted() }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Button { showAsk = true } label: { Label("Ask your notes", systemImage: "sparkle.magnifyingglass") }
                        .buttonStyle(PillButtonStyle())
                    Button { showReview = true } label: {
                        Label(dueCards.isEmpty ? "Flashcards" : "Review \(dueCards.count)", systemImage: "rectangle.on.rectangle.angled")
                    }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(cards.isEmpty)
                }
                .listRowBackground(Color.clear)
            }

            if !query.isEmpty {
                Section(searching ? "Searching…" : "Results") {
                    if hits.isEmpty && !searching {
                        Text("No matches in your notes.").foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(hits) { hit in
                        NavigationLink {
                            if let note = notes.first(where: { $0.id == hit.noteID }) { NoteDetailView(note: note) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(hit.title).font(Theme.callout.weight(.semibold))
                                    ModuleChip(code: hit.moduleCode)
                                    if let w = hit.week { Tag(text: "Week \(w)") }
                                    if hit.isTyped { Tag(text: "Key point", color: Theme.success) }
                                }
                                Text(hit.snippet).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(3)
                            }
                        }
                    }
                }
            } else {
                if !gaps.isEmpty {
                    Section("Gaps") {
                        ForEach(Array(gaps.prefix(8).enumerated()), id: \.offset) { _, gap in
                            Label(gap.message, systemImage: gapSymbol(gap.kind))
                                .font(Theme.callout)
                                .foregroundStyle(gap.kind == .missingNotes ? Theme.warning : Theme.textPrimary)
                        }
                    }
                }

                if notes.isEmpty {
                    EmptyState(systemImage: "pencil.and.scribble", title: "No notes yet",
                               message: "Your Mac reads your OneNote pages (typed and handwritten) and they appear here.")
                        .listRowBackground(Color.clear)
                }

                ForEach(groupedNotes, id: \.key) { group in
                    Section(group.key) {
                        ForEach(group.notes) { note in
                            NavigationLink { NoteDetailView(note: note) } label: { NoteRow(note: note) }
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .orbitBackground()
        .navigationTitle("Notes")
        .searchable(text: $query, prompt: "Search lectures, typed and handwritten")
        .task(id: query) { await search() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Module", selection: $moduleFilter) {
                        Text("All modules").tag(String?.none)
                        ForEach(modules, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                } label: { Label("Module", systemImage: "line.3.horizontal.decrease.circle") }
            }
        }
        .sheet(isPresented: $showAsk) { AskNotesSheet(moduleCode: moduleFilter) }
        .sheet(isPresented: $showReview) { FlashcardReviewView(moduleCode: moduleFilter) }
    }

    private struct NoteGroup { var key: String; var notes: [StoredNote] }

    private var groupedNotes: [NoteGroup] {
        let filtered = notes.filter { moduleFilter == nil || $0.moduleCode == moduleFilter }
        let dict = Dictionary(grouping: filtered) { n -> String in
            let module = n.moduleCode ?? "Other"
            return n.week.map { "\(module) · Week \($0)" } ?? module
        }
        return dict.map { NoteGroup(key: $0.key, notes: $0.value) }
            .sorted { ($0.notes.map(\.created).max() ?? .distantPast) > ($1.notes.map(\.created).max() ?? .distantPast) }
    }

    private func gapSymbol(_ kind: NoteGap.Kind) -> String {
        switch kind {
        case .missingTypedSummary: "keyboard"
        case .missingNotes: "exclamationmark.triangle"
        case .lowConfidence: "questionmark.circle"
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { hits = []; return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        searching = true
        hits = await app.backend.searchNotes(q, moduleCode: moduleFilter)
        searching = false
    }
}

struct NoteRow: View {
    var note: StoredNote

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(note.title.isEmpty ? "Untitled page" : note.title)
                .font(Theme.body.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 6) {
                if note.hasTyped { Tag(text: "typed ✓", color: Theme.success) }
                if note.hasHandwriting { Tag(text: "handwriting ✓", color: Theme.accent) }
                if note.lowConfidence { Tag(text: "check ⚠︎", color: Theme.warning) }
                Spacer()
                Text(note.created.formatted(date: .abbreviated, time: .omitted))
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            if let summary = note.summary, !summary.isEmpty {
                Text(summary).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}

struct NoteDetailView: View {
    @Environment(AppModel.self) private var app
    @Query private var cards: [StoredFlashcard]
    var note: StoredNote
    @State private var full: LectureNote?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ModuleChip(code: note.moduleCode)
                        if let w = note.week { Tag(text: "Week \(w)") }
                        if note.hasTyped { Tag(text: "typed ✓", color: Theme.success) }
                        if note.hasHandwriting { Tag(text: "handwriting ✓", color: Theme.accent) }
                        if note.lowConfidence { Tag(text: "low confidence ⚠︎", color: Theme.warning) }
                    }
                    Text(note.title).font(Theme.title(26)).foregroundStyle(Theme.textPrimary)
                    Text([note.notebook, note.section].filter { !$0.isEmpty }.joined(separator: " › "))
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }

                if let summary = note.summary, !summary.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Summary", systemImage: "text.alignleft").font(Theme.headline).foregroundStyle(Theme.accent)
                            Text(summary).font(Theme.body).textSelection(.enabled)
                        }
                    }
                }

                let keyPoints = full?.keyPoints ?? note.keyPoints
                if !keyPoints.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Key points (typed)", systemImage: "star").font(Theme.headline).foregroundStyle(Theme.success)
                            Text(keyPoints).font(Theme.body).textSelection(.enabled)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Full lecture detail (handwriting)", systemImage: "pencil.and.scribble")
                            .font(Theme.headline).foregroundStyle(Theme.accent)
                        if let full {
                            let segments = full.segments.filter { $0.kind != .typed }
                            if segments.isEmpty {
                                Text("No handwriting on this page.").foregroundStyle(Theme.textSecondary)
                            }
                            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                                VStack(alignment: .leading, spacing: 4) {
                                    if seg.kind == .diagram { Tag(text: "Diagram", systemImage: "scribble.variable") }
                                    if seg.kind == .math { Tag(text: "Maths", systemImage: "function") }
                                    Text(highlighted(seg))
                                        .font(seg.kind == .math ? Theme.mono : Theme.body)
                                        .textSelection(.enabled)
                                }
                            }
                            if !full.segments.flatMap(\.uncertainWords).isEmpty {
                                Text("Highlighted words were hard to read.")
                                    .font(Theme.caption).foregroundStyle(Theme.warning)
                            }
                        } else if note.hasHandwriting {
                            Text(app.backend.isBrain ? "The full transcription isn't on this Mac yet."
                                 : "The full handwriting transcription stays on your Mac. Open this note there to read it.")
                                .font(Theme.callout).foregroundStyle(Theme.textSecondary)
                        } else {
                            Text("No handwriting on this page.").foregroundStyle(Theme.textSecondary)
                        }
                    }
                }

                let noteCards = cards.filter { $0.noteID == note.id }
                if !noteCards.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("\(noteCards.count) flashcards", systemImage: "rectangle.on.rectangle.angled")
                                .font(Theme.headline).foregroundStyle(Theme.accent)
                            ForEach(noteCards.prefix(5)) { c in
                                Text("• \(c.front)").font(Theme.callout).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            }
            .padding(Theme.padding)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .orbitBackground()
        .navigationTitle(note.title)
        .onAppear { full = app.backend.fullNote(id: note.id) }
    }

    /// Handwriting text with uncertain words highlighted.
    private func highlighted(_ seg: NoteSegment) -> AttributedString {
        var s = AttributedString(seg.text)
        for word in Set(seg.uncertainWords) where !word.isEmpty && word != "?" {
            var searchRange = s.startIndex..<s.endIndex
            while let r = s[searchRange].range(of: word) {
                let color: Color = Theme.warning.opacity(0.28)
                s[r].backgroundColor = color
                searchRange = r.upperBound..<s.endIndex
            }
        }
        return s
    }
}

struct AskNotesSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query private var notes: [StoredNote]
    var moduleCode: String?
    @State private var question = ""
    @State private var answer: NotesAnswer?
    @State private var asking = false
    @State private var sentToChat = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    TextField("What did the lecture say about…", text: $question)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(ask)
                    Button("Ask", action: ask).buttonStyle(PillButtonStyle()).disabled(question.isEmpty || asking)
                }
                if let moduleCode { Text("Searching \(moduleCode) only").font(Theme.caption).foregroundStyle(Theme.textSecondary) }
                if asking { HStack { ProgressView(); Text("Reading your notes…").foregroundStyle(Theme.textSecondary) } }
                if sentToChat {
                    EmptyState(systemImage: "bubble.left.and.bubble.right", title: "Sent to your Mac",
                               message: "The answer will appear in Chat once your Mac has read your notes.")
                }
                if let error { Text(error).foregroundStyle(Theme.danger).font(Theme.caption) }
                if let answer {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(answer.text).font(Theme.body).textSelection(.enabled)
                            if !answer.citations.isEmpty {
                                Text("Sources").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                                ForEach(answer.citations) { c in
                                    HStack {
                                        Text("[\(c.index)]").font(Theme.mono)
                                        Text(c.title).font(Theme.callout)
                                        ModuleChip(code: c.moduleCode)
                                        if let w = c.week { Tag(text: "Week \(w)") }
                                    }
                                }
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Ask your notes")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        asking = true
        error = nil
        Task {
            do {
                if let a = try await app.backend.askNotes(q, moduleCode: moduleCode) { answer = a } else { sentToChat = true }
            } catch {
                self.error = "Couldn't answer: \(error.localizedDescription)"
            }
            asking = false
        }
    }
}

/// SM-2 flashcard review: Again / Hard / Good / Easy.
struct FlashcardReviewView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query private var cards: [StoredFlashcard]
    var moduleCode: String?
    @State private var queue: [String] = []
    @State private var revealed = false
    @State private var reviewed = 0

    private var current: StoredFlashcard? { queue.first.flatMap { id in cards.first { $0.id == id } } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let card = current {
                    Text("\(queue.count) to go · \(reviewed) done").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 16) {
                        ModuleChip(code: card.moduleCode)
                        Text(card.front).font(Theme.title(22)).foregroundStyle(Theme.textPrimary)
                        if revealed {
                            Divider()
                            Text(card.back).font(Theme.body).foregroundStyle(Theme.textPrimary)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.06), radius: 16, y: 8)
                    .onTapGesture { withAnimation(Theme.spring) { revealed = true } }

                    if revealed {
                        HStack(spacing: 10) {
                            grade("Again", 1, Theme.danger)
                            grade("Hard", 3, Theme.warning)
                            grade("Good", 4, Theme.success)
                            grade("Easy", 5, Theme.accent)
                        }
                    } else {
                        Button("Show answer") { withAnimation(Theme.spring) { revealed = true } }
                            .buttonStyle(PillButtonStyle())
                            .keyboardShortcut(.space, modifiers: [])
                    }
                } else {
                    EmptyState(systemImage: "checkmark.seal", title: reviewed > 0 ? "Session done" : "Nothing due",
                               message: reviewed > 0 ? "You reviewed \(reviewed) card\(reviewed == 1 ? "" : "s"). They'll come back when they're due."
                                                     : "No cards are due right now. Come back later.")
                }
                Spacer()
            }
            .padding()
            .orbitBackground()
            .navigationTitle("Flashcards")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .frame(minWidth: 480, minHeight: 520)
        .onAppear(perform: load)
        .haptic(reviewed)
    }

    private func load() {
        let due = SpacedRepetition.dueCards(cards.map(\.value), now: Date(), moduleCode: moduleCode, limit: 40)
        queue = due.map { $0.id.uuidString }.filter { id in cards.contains { $0.id == id } }
        if queue.isEmpty {
            // Fall back to matching by stored id when ids aren't UUIDs.
            queue = cards.filter { $0.due <= Date() && (moduleCode == nil || $0.moduleCode == moduleCode) }
                .sorted { $0.due < $1.due }.prefix(40).map(\.id)
        }
    }

    private func grade(_ title: String, _ value: Int, _ color: Color) -> some View {
        Button(title) {
            guard let card = current else { return }
            app.review(card, grade: value)
            reviewed += 1
            withAnimation(Theme.spring) {
                queue.removeFirst()
                // "Again" comes back later in this session (10-minute learning step).
                if value < 3 { queue.append(card.id) }
                revealed = false
            }
        }
        .buttonStyle(PillButtonStyle(color: color))
    }
}
