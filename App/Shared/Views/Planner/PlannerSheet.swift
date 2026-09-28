import SwiftUI
import OrbitCore

/// Chat-style planner: say (or type) everything at once, see "Here's what I'll do",
/// tweak items or reply in a line ("move the stats one to Sunday"), then add it all.
struct PlannerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var initialText: String

    @State private var turns: [PlannerTurn] = []
    @State private var proposal: PlanProposal?
    @State private var draft = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(turns) { PlannerBubble(turn: $0) }
                    if proposal != nil { PlannerPreview(proposal: Binding($proposal)!) }
                    if busy { ProgressView().controlSize(.small) }
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            PlannerComposer(text: $draft, placeholder: proposal == nil ? "Tell Orbit what's going on…" : "Adjust: “move the stats one to Sunday”",
                            busy: busy, send: send)
            footer
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 520)
        .task { if turns.isEmpty, !initialText.isEmpty { send(initialText) } }
    }

    private var footer: some View {
        HStack {
            if proposal?.usedAI == false {
                Text("Understood without AI").font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(commitLabel) { commit() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || (proposal?.items.filter(\.included).isEmpty ?? true) && (proposal?.restDays.isEmpty ?? true))
        }
        .padding(Theme.Space.m)
    }

    private var commitLabel: String {
        let n = proposal?.items.filter(\.included).count ?? 0
        return n == 0 ? "Apply" : "Add \(n) to my plan"
    }

    private func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        turns.append(PlannerTurn(fromUser: true, text: text))
        draft = ""
        busy = true
        Task { @MainActor in
            let next: PlanProposal
            if let current = proposal { next = await app.revisePlan(current, reply: text) } else { next = await app.proposePlan(text) }
            proposal = next
            let notes = next.warnings.isEmpty ? "" : "\n\n" + next.warnings.joined(separator: "\n")
            turns.append(PlannerTurn(fromUser: false, text: next.summary + notes))
            busy = false
        }
    }

    private func commit() {
        guard let proposal else { return }
        Task { @MainActor in
            await app.commit(proposal)
            dismiss()
        }
    }
}

struct PlannerTurn: Identifiable, Hashable {
    let id = UUID()
    var fromUser: Bool
    var text: String
}

struct PlannerBubble: View {
    var turn: PlannerTurn

    var body: some View {
        HStack {
            if turn.fromUser { Spacer(minLength: 60) }
            Text(turn.text)
                .font(Theme.body)
                .foregroundStyle(turn.fromUser ? Theme.textPrimary : Theme.textSecondary)
                .textSelection(.enabled)
                .padding(Theme.Space.s)
                .background(turn.fromUser ? Theme.accent.opacity(0.12) : Theme.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.s))
            if !turn.fromUser { Spacer(minLength: 60) }
        }
    }
}

/// The proposed items: include/remove, change time and length.
struct PlannerPreview: View {
    @Environment(AppModel.self) private var app
    @Binding var proposal: PlanProposal

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(proposal.blocksToMove) { b in
                Label("Moving “\(b.title)” off \(Fmt.day(b.start, app.calendar))", systemImage: "arrow.uturn.right")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            ForEach($proposal.items) { $item in
                PlannerItemRow(item: $item, onChange: resummarise)
                Hairline()
            }
        }
    }

    private func resummarise() {
        proposal.summary = app.conversationalPlanner.summary(proposal, context: app.plannerContext())
    }
}

struct PlannerItemRow: View {
    @Environment(AppModel.self) private var app
    @Binding var item: ProposedItem
    var onChange: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Button { item.included.toggle(); onChange() } label: {
                Image(systemName: item.included ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.included ? Theme.accent : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help(item.included ? "Leave this out" : "Include this")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Theme.body.weight(.medium)).foregroundStyle(item.included ? Theme.textPrimary : Theme.textTertiary)
                    .strikethrough(!item.included)
                if let detail = item.detail { Text(detail).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                if item.included { timing }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.xs)
    }

    private var timing: some View {
        HStack(spacing: Theme.Space.s) {
            DatePicker("", selection: Binding(get: { item.start ?? Date() }, set: { item.start = $0; onChange() }),
                       displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
            Stepper(Fmt.duration(item.minutes), value: Binding(get: { item.minutes }, set: { item.minutes = $0; onChange() }),
                    in: 10...240, step: 15)
                .font(Theme.caption)
            if let d = item.deadline {
                Text("due \(Fmt.dayTime(d, app.calendar))").font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .controlSize(.small)
    }
}

/// Multi-line input with a send button and (on the Mac) dictation.
struct PlannerComposer: View {
    @Binding var text: String
    var placeholder: String
    var busy: Bool
    var send: (String) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.s) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .lineLimit(1...5)
                .onSubmit { send(text) }
            #if os(macOS)
            DictationButton(text: $text)
            #endif
            Button { send(text) } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Send")
        }
        .padding(Theme.Space.m)
    }
}

/// Opens the planner sheet with some text (from Quick Add).
struct PlannerRequest: Identifiable {
    let id = UUID()
    var text: String
}

extension View {
    /// Presents `PlannerSheet` for `request`.
    func plannerSheet(_ request: Binding<PlannerRequest?>) -> some View {
        sheet(item: request) { r in PlannerSheet(initialText: r.text) }
    }
}
