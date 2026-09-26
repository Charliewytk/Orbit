import SwiftUI
import SwiftData
import OrbitCore

/// One row in the ⌘K palette.
struct PaletteCommand: Identifiable {
    var id: String
    var title: String
    var subtitle: String? = nil
    var symbol: String
    var section: String
    var shortcut: String? = nil
    /// Extra words to match against (module name, etc).
    var keywords: String = ""
    var moduleCode: String? = nil
    var action: @MainActor () -> Void
}

/// Fuzzy subsequence scoring: consecutive letters and word starts score higher.
enum FuzzyMatch {
    static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let t = Array(text.lowercased())
        var qi = 0, score = 0, streak = 0
        var previous: Character = " "
        for c in t {
            if qi < q.count && c == q[qi] {
                qi += 1
                streak += 1
                score += 1 + streak * 2
                if previous == " " || previous == "-" || previous == "·" { score += 6 }
            } else {
                streak = 0
            }
            previous = c
        }
        guard qi == q.count else { return nil }
        if text.lowercased().hasPrefix(query.lowercased()) { score += 20 }
        return score - t.count / 8
    }
}

/// ⌘K: fuzzy search over screens, tasks, modules and actions.
struct CommandPalette: View {
    @Environment(AppModel.self) private var app
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @Query(filter: #Predicate<StoredTask> { $0.completedAt == nil }, sort: \StoredTask.createdAt, order: .reverse)
    private var tasks: [StoredTask]
    @Query(sort: \StoredModule.id) private var modules: [StoredModule]
    @Query(sort: \StoredNote.created, order: .reverse) private var notes: [StoredNote]

    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search or type a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.Size.title3))
                    .focused($focused)
                    .onSubmit { run(results) }
                    .onKeyPress(.downArrow) { move(1, count: results.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: results.count); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    #if os(macOS)
                    .onExitCommand { close() }
                    #endif
                KeyHint(keys: "esc")
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(height: 48)

            if !results.isEmpty {
                Hairline()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                                if index == 0 || results[index - 1].section != command.section {
                                    Text(command.section)
                                        .font(Theme.caption)
                                        .foregroundStyle(Theme.textTertiary)
                                        .padding(.horizontal, Theme.Space.m)
                                        .padding(.top, index == 0 ? Theme.Space.xs : Theme.Space.s)
                                        .padding(.bottom, 2)
                                }
                                row(command, selected: index == selection)
                                    .id(command.id)
                                    .onTapGesture { selection = index; run(results) }
                            }
                        }
                        .padding(Theme.Space.xs)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selection) { _, new in
                        if results.indices.contains(new) { proxy.scrollTo(results[new].id) }
                    }
                }
            }
        }
        .frame(width: 620)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .orbitGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .shadow(color: Theme.glassShadow, radius: 30, y: 14)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private func row(_ command: PaletteCommand, selected: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: command.symbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18)
            if let code = command.moduleCode { ModuleDot(code: code, size: 7) }
            Text(command.title)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            if let subtitle = command.subtitle {
                Text(subtitle).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            if let shortcut = command.shortcut { KeyHint(keys: shortcut) }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 32)
        .background(selected ? Theme.selection : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        .contentShape(Rectangle())
    }

    // MARK: Results

    private var results: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            return Array((actions(for: q) + screens).prefix(14))
        }
        let actionList = actions(for: q)
        // "Add task" and "Ask Orbit" for the typed text always come last.
        let typed = actionList.filter { $0.id.hasPrefix("dyn-") }
        let all = actionList.filter { !$0.id.hasPrefix("dyn-") } + screens + taskCommands + moduleCommands + noteCommands
        let best = all
            .compactMap { c -> (PaletteCommand, Int)? in
                FuzzyMatch.score(q, in: c.title + " " + c.keywords).map { (c, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .prefix(24)
            .map { $0.0 }
        // Keep sections together, in the order of their best hit.
        var order: [String] = []
        for c in best where !order.contains(c.section) { order.append(c.section) }
        return order.flatMap { section in best.filter { $0.section == section } } + typed
    }

    private func actions(for q: String) -> [PaletteCommand] {
        var out: [PaletteCommand] = [
            PaletteCommand(id: "add-task", title: "Add task…", symbol: "plus", section: "Actions", shortcut: "⌘N",
                           keywords: "new todo quick add") {
                NotificationCenter.default.post(name: .orbitQuickAdd, object: nil)
            },
            PaletteCommand(id: "sync", title: "Sync now", symbol: "arrow.clockwise", section: "Actions", shortcut: "⌘R",
                           keywords: "refresh update") {
                Task { await app.backend.syncNow() }
                app.show("Syncing…")
            },
            PaletteCommand(id: "replan", title: "Reshuffle my plan", symbol: "arrow.triangle.2.circlepath",
                           section: "Actions", keywords: "replan schedule") {
                Task { await app.backend.requestReplan() }
                app.show("Reshuffling your plan")
            },
            PaletteCommand(id: "ask", title: "Ask Orbit…", symbol: "bubble.left.and.text.bubble.right",
                           section: "Actions", keywords: "chat question") {
                navigate(.chat)
            },
        ]
        #if os(macOS)
        out.append(PaletteCommand(id: "settings", title: "Settings…", symbol: "gearshape", section: "Actions",
                                  shortcut: "⌘,", keywords: "preferences accounts") { openSettings() })
        #endif
        if !q.isEmpty {
            out.append(PaletteCommand(id: "dyn-add", title: "Add task “\(q)”", symbol: "plus.circle", section: "Actions") {
                if let task = app.addTask(text: q) {
                    app.show("Added “\(task.title)”", undo: { [weak app] in app?.delete(task) })
                }
            })
            out.append(PaletteCommand(id: "dyn-ask", title: "Ask Orbit “\(q)”", symbol: "text.bubble", section: "Actions") {
                navigate(.chat)
                Task { await app.backend.sendChat(q) }
            })
        }
        return out
    }

    private var screens: [PaletteCommand] {
        Destination.macSidebar.enumerated().map { index, d in
            PaletteCommand(id: "screen-\(d.rawValue)", title: d.title, symbol: d.symbol, section: "Go to",
                           shortcut: index < 9 ? "⌘\(index + 1)" : nil) { navigate(d) }
        }
    }

    private var taskCommands: [PaletteCommand] {
        tasks.prefix(300).map { t in
            PaletteCommand(id: "task-\(t.id)", title: t.title,
                           subtitle: t.deadline.map { Fmt.shortDue($0, app.calendar) },
                           symbol: "circle", section: "Tasks", keywords: t.moduleCode ?? "", moduleCode: t.moduleCode) {
                app.selectedTaskID = t.id
                navigate(.tasks)
            }
        }
    }

    private var moduleCommands: [PaletteCommand] {
        modules.map { m in
            PaletteCommand(id: "module-\(m.id)", title: m.name.isEmpty ? m.id : "\(m.id) \(m.name)",
                           symbol: "graduationcap", section: "Modules", moduleCode: m.id) {
                app.selectedModuleID = m.id
                navigate(.uni)
            }
        }
    }

    private var noteCommands: [PaletteCommand] {
        notes.prefix(300).map { n in
            PaletteCommand(id: "note-\(n.id)", title: n.title.isEmpty ? "Untitled page" : n.title,
                           subtitle: n.week.map { "Week \($0)" }, symbol: "note.text", section: "Notes",
                           keywords: n.moduleCode ?? "", moduleCode: n.moduleCode) {
                app.selectedNoteID = n.id
                navigate(.notes)
            }
        }
    }

    // MARK: Actions

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func run(_ results: [PaletteCommand]) {
        guard results.indices.contains(selection) else { return }
        let command = results[selection]
        close()
        command.action()
    }

    private func navigate(_ d: Destination) {
        NotificationCenter.default.post(name: .orbitNavigate, object: d)
    }

    private func close() {
        isPresented = false
    }
}

extension Notification.Name {
    /// Opens the in-window quick add (⌘N).
    static let orbitQuickAdd = Notification.Name("orbitQuickAdd")
    /// Toggles the command palette (⌘K).
    static let orbitCommandPalette = Notification.Name("orbitCommandPalette")
}
