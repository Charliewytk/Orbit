import SwiftUI
import OrbitCore

/// Natural-language quick add with a live preview of what was understood,
/// Fantastical style: "essay plan BEM2031 2h before Friday".
struct QuickAddField: View {
    @Environment(AppModel.self) private var app
    var placeholder: String = "Add a task"
    /// Focus the field when it appears.
    var autofocus: Bool = false
    var onAdded: ((StoredTask) -> Void)? = nil

    @State private var text = ""
    @State private var added = 0
    @FocusState private var focused: Bool

    init(placeholder: String = "Add a task", autofocus: Bool = false, onAdded: ((StoredTask) -> Void)? = nil) {
        self.placeholder = placeholder
        self.autofocus = autofocus
        self.onAdded = onAdded
    }

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let result = trimmed.isEmpty ? nil : app.parse(text)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(focused ? Theme.accent : Theme.textTertiary)
                    .frame(width: 16)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .focused($focused)
                    .onSubmit(add)
                    .submitLabel(.done)
                    #if os(macOS)
                    .onExitCommand { text = "" }
                    #endif
                if result != nil {
                    Text("↩")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .transition(.opacity)
                }
            }
            if let result {
                ParsedChips(result: result)
                    .padding(.leading, 16 + Theme.Space.s)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 6)
        .animation(Motion.quick, value: result == nil)
        .successHaptic(added)
        .onAppear { if autofocus { focused = true } }
    }

    private func add() {
        guard let task = app.addTask(text: text) else { return }
        added += 1
        text = ""
        focused = true
        onAdded?(task)
        let when = task.deadline.map { " · due \(Fmt.shortDue($0, app.calendar))" } ?? ""
        app.show("Added “\(task.title)”\(when)", undo: { [weak app] in
            guard let app else { return }
            app.delete(task)
        })
    }
}

/// The parsed pieces of a quick-add line, as quiet inline text.
struct ParsedChips: View {
    @Environment(AppModel.self) private var app
    var result: QuickAddResult

    var body: some View {
        let t = result.task
        Flow(spacing: Theme.Space.s) {
            chip(t.title.isEmpty ? "Untitled" : t.title, symbol: nil, primary: true)
            if let d = t.deadline {
                chip(Fmt.dayTime(d, app.calendar), symbol: "calendar")
            }
            if let s = t.earliestStart {
                chip("from \(Fmt.day(s, app.calendar))", symbol: "arrow.right")
            }
            if let code = t.moduleCode {
                ModuleChip(code: code)
            }
            chip(Fmt.duration(t.estimateMinutes) + (result.hasExplicitEstimate ? "" : " est."), symbol: "clock")
            if t.priority > .normal { chip("Priority", symbol: "exclamationmark", color: Theme.danger) }
            if let r = result.ignoredRecurrence { chip("Repeats not supported: \(r)", symbol: nil, color: Theme.textTertiary) }
        }
    }

    private func chip(_ text: String, symbol: String?, primary: Bool = false, color: Color = Theme.textSecondary) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small).foregroundStyle(Theme.textTertiary) }
            Text(text).lineLimit(1)
        }
        .font(Theme.caption.weight(primary ? .medium : .regular))
        .foregroundStyle(primary ? Theme.textPrimary : color)
    }
}
