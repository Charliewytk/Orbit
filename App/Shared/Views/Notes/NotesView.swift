import SwiftUI
import SwiftData
import OrbitCore

/// Notes. On the Mac: "Library" (the notes folder tree, PDFs, typed notes) and "Review"
/// (lecture pages by module and week, gaps, flashcards). The iPhone shows Review only.
struct NotesView: View {
    #if os(macOS)
    enum Tab: String { case library, review }
    @AppStorage("notesTab") private var tab: Tab = .library
    #endif

    var body: some View {
        #if os(macOS)
        Group {
            switch tab {
            case .library: NotesLibraryView()
            case .review: NotesReviewView()
            }
        }
        .navigationTitle("Notes")
        .toolbar {
            ToolbarItem(placement: .principal) {
                GlassSegmented(options: [(value: Tab.library, title: "Library"), (value: Tab.review, title: "Review")],
                               selection: $tab)
            }
        }
        #else
        NotesReviewView()
        #endif
    }
}

/// Notes review: lecture pages grouped by module and week on the left, the page on the right.
struct NotesReviewView: View {
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

    private var dueCards: Int { cards.filter { $0.due <= Date() }.count }

    private var modules: [String] { Array(Set(notes.compactMap(\.moduleCode))).sorted() }

    var body: some View {
        let selection = Binding<String?>(get: { app.selectedNoteID }, set: { app.selectedNoteID = $0 })
        TwoPane(selection: selection, listWidth: 300) {
            listPane(selection: selection)
        } detail: { id in
            if let id, let note = notes.first(where: { $0.id == id }) {
                NoteDetailView(note: note).id(note.id)
            } else {
                Text(notes.isEmpty ? "" : "No page selected")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Notes")
        .searchable(text: $query, prompt: "Search lectures")
        .task(id: query) { await search() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Module", selection: $moduleFilter) {
                        Text("All modules").tag(String?.none)
                        ForEach(modules, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                } label: {
                    Label("Module", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Filter by module")
                Button { showReview = true } label: {
                    Label(dueCards == 0 ? "Flashcards" : "Review \(dueCards)", systemImage: "rectangle.on.rectangle")
                }
                .disabled(cards.isEmpty)
                .help("Review flashcards")
                Button { showAsk = true } label: {
                    Label("Ask your notes", systemImage: "questionmark.bubble")
                }
                .help("Ask a question about your notes")
            }
        }
        .sheet(isPresented: $showAsk) { AskNotesSheet(moduleCode: moduleFilter) }
        .sheet(isPresented: $showReview) { FlashcardReviewView(moduleCode: moduleFilter) }
    }

    // MARK: List

    private func listPane(selection: Binding<String?>) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !query.isEmpty {
                    groupTitle(searching ? "Searching…" : "Results")
                    if hits.isEmpty && !searching {
                        EmptyState(title: "No matches in your notes.").padding(.horizontal, Theme.Space.s)
                    }
                    ForEach(hits) { hit in
                        NoteHitRow(hit: hit, isSelected: selection.wrappedValue == hit.noteID)
                            .onTapGesture { selection.wrappedValue = hit.noteID }
                    }
                } else {
                    let gaps = self.gaps
                    if !gaps.isEmpty {
                        groupTitle("Gaps")
                        ForEach(Array(gaps.prefix(6).enumerated()), id: \.offset) { _, gap in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                                Image(systemName: gapSymbol(gap.kind))
                                    .font(.system(size: 11))
                                    .foregroundStyle(gap.kind == .missingNotes ? Theme.warning : Theme.textTertiary)
                                    .frame(width: 14)
                                Text(gap.message)
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, Theme.Space.s)
                            .padding(.vertical, 4)
                        }
                    }
                    if notes.isEmpty {
                        EmptyState(title: "No notes yet.",
                                   message: "Your Mac reads your OneNote pages, typed and handwritten, and they appear here.")
                            .padding(.horizontal, Theme.Space.s)
                    }
                    ForEach(groupedNotes, id: \.key) { group in
                        groupTitle(group.key)
                        ForEach(group.notes) { note in
                            NoteRow(note: note, isSelected: selection.wrappedValue == note.id)
                                .onTapGesture { selection.wrappedValue = note.id }
                        }
                    }
                }
            }
            .padding(Theme.Space.xs)
            .padding(.bottom, Theme.Space.l)
        }
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.caption.weight(.medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, Theme.Space.s)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.xs)
    }

    private var gaps: [NoteGap] {
        let lectures = events.map(\.value).filter(StudyCoach.isLecture)
        return GapDetector.detect(notes: notes.map(\.stub), lectures: lectures, now: Date(), timeZone: app.prefs.timeZone)
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
        case .missingNotes: "exclamationmark.circle"
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
    var isSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(note.title.isEmpty ? "Untitled page" : note.title)
                    .font(Theme.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                Text(note.created.formatted(.dateTime.day().month(.abbreviated)))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            if let summary = note.summary, !summary.isEmpty {
                Text(summary)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            if note.lowConfidence {
                Text("Some handwriting to check")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 7)
        .hoverRow(selected: isSelected)
    }
}

private struct NoteHitRow: View {
    var hit: NoteHit
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.s) {
                Text(hit.title).font(Theme.body.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                ModuleTag(code: hit.moduleCode)
                if let w = hit.week { Text("Wk \(w)").font(Theme.caption).foregroundStyle(Theme.textTertiary) }
            }
            Text(hit.snippet).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(3)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 7)
        .hoverRow(selected: isSelected)
    }
}

/// A lecture page: key points (typed), then lecture detail (handwriting) with
/// hard-to-read words subtly underlined.
struct NoteDetailView: View {
    @Environment(AppModel.self) private var app
    @Query private var cards: [StoredFlashcard]
    var note: StoredNote
    @State private var full: LectureNote? = nil

    var body: some View {
        Page(maxWidth: 720) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.s) {
                    ModuleTag(code: note.moduleCode)
                    if let w = note.week { Text("Week \(w)") }
                    Text(note.created.formatted(date: .abbreviated, time: .omitted))
                    let path = [note.notebook, note.section].filter { !$0.isEmpty }.joined(separator: " › ")
                    if !path.isEmpty { Text(path).lineLimit(1) }
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                Text(note.title.isEmpty ? "Untitled page" : note.title)
                    .font(Theme.pageTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.top, Theme.Space.xxl)

            if let summary = note.summary, !summary.isEmpty {
                Text(summary)
                    .font(Theme.large)
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, Theme.Space.l)
            }

            let keyPoints = full?.keyPoints ?? note.keyPoints
            PageSection(title: "Key points") {
                if keyPoints.isEmpty {
                    Text("No typed key points on this page.").font(Theme.body).foregroundStyle(Theme.textTertiary)
                } else {
                    Text(keyPoints)
                        .font(Theme.large)
                        .foregroundStyle(Theme.textPrimary)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            PageSection(title: "Lecture detail") {
                lectureDetail
            }

            let noteCards = cards.filter { $0.noteID == note.id }
            if !noteCards.isEmpty {
                PageSection(title: "Flashcards", count: noteCards.count) {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        ForEach(noteCards.prefix(6)) { c in
                            Text(c.front).font(Theme.body).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(note.title)
        .onAppear { full = app.backend.fullNote(id: note.id) }
    }

    @ViewBuilder
    private var lectureDetail: some View {
        if let full {
            let segments = full.segments.filter { $0.kind != .typed }
            if segments.isEmpty {
                Text("No handwriting on this page.").font(Theme.body).foregroundStyle(Theme.textTertiary)
            }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        if seg.kind == .diagram || seg.kind == .math {
                            Text(seg.kind == .diagram ? "Diagram" : "Maths")
                                .font(Theme.caption.weight(.medium))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Text(highlighted(seg))
                            .font(seg.kind == .math ? .system(size: Theme.Size.body, design: .monospaced) : Theme.large)
                            .foregroundStyle(Theme.textPrimary)
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            if !full.segments.flatMap(\.uncertainWords).isEmpty {
                Text("Dotted words were hard to read.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, Theme.Space.s)
            }
        } else if note.hasHandwriting {
            Text(app.backend.isBrain ? "The full transcription isn't on this Mac yet."
                 : "The full handwriting transcription stays on your Mac. Open this page there to read it.")
                .font(Theme.body)
                .foregroundStyle(Theme.textTertiary)
        } else {
            Text("No handwriting on this page.").font(Theme.body).foregroundStyle(Theme.textTertiary)
        }
    }

    /// Handwriting text with uncertain words underlined with a dotted line.
    private func highlighted(_ seg: NoteSegment) -> AttributedString {
        var s = AttributedString(seg.text)
        for word in Set(seg.uncertainWords) where !word.isEmpty && word != "?" {
            var searchRange = s.startIndex..<s.endIndex
            while let r = s[searchRange].range(of: word) {
                s[r].underlineStyle = Text.LineStyle(pattern: .dot, color: Theme.warning)
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
                    Button("Ask", action: ask).buttonStyle(.borderedProminent).disabled(question.isEmpty || asking)
                }
                if let moduleCode { Text("Searching \(moduleCode) only").font(Theme.caption).foregroundStyle(Theme.textSecondary) }
                if asking { HStack { ProgressView().controlSize(.small); Text("Reading your notes…").foregroundStyle(Theme.textSecondary) } }
                if sentToChat {
                    EmptyState(title: "Sent to your Mac.",
                               message: "The answer appears in Ask Orbit once your Mac has read your notes.")
                }
                if let error { Text(error).foregroundStyle(Theme.danger).font(Theme.caption) }
                if let answer {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(answer.text).font(Theme.large).lineSpacing(4).textSelection(.enabled)
                            if !answer.citations.isEmpty {
                                Text("Sources").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                                ForEach(answer.citations) { c in
                                    HStack {
                                        Text("[\(c.index)]").font(Theme.mono).foregroundStyle(Theme.textTertiary)
                                        Text(c.title).font(Theme.body)
                                        ModuleTag(code: c.moduleCode)
                                        if let w = c.week { Text("Week \(w)").font(Theme.caption).foregroundStyle(Theme.textTertiary) }
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
                    Text("\(queue.count) to go · \(reviewed) done").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        ModuleTag(code: card.moduleCode)
                        Text(card.front).font(.system(size: Theme.Size.title2, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        if revealed {
                            Hairline()
                            Text(card.back).font(Theme.large).lineSpacing(4).foregroundStyle(Theme.textPrimary)
                                .transition(.opacity)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Theme.Space.xl)
                    .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.hairline))
                    .onTapGesture { withAnimation(Motion.quick) { revealed = true } }

                    if revealed {
                        HStack(spacing: Theme.Space.s) {
                            grade("Again", 1, key: "1")
                            grade("Hard", 3, key: "2")
                            grade("Good", 4, key: "3")
                            grade("Easy", 5, key: "4")
                        }
                    } else {
                        Button("Show answer") { withAnimation(Motion.quick) { revealed = true } }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.space, modifiers: [])
                    }
                } else {
                    EmptyState(title: reviewed > 0 ? "Session done." : "Nothing due.",
                               message: reviewed > 0 ? "You reviewed \(reviewed) card\(reviewed == 1 ? "" : "s"). They come back when they're due."
                                                     : "No cards are due right now.")
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

    private func grade(_ title: String, _ value: Int, key: Character) -> some View {
        Button(title) {
            guard let card = current else { return }
            app.review(card, grade: value)
            reviewed += 1
            withAnimation(Motion.quick) {
                queue.removeFirst()
                // "Again" comes back later in this session (10-minute learning step).
                if value < 3 { queue.append(card.id) }
                revealed = false
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .keyboardShortcut(KeyEquivalent(key), modifiers: [])
    }
}
