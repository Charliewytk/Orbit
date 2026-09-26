import SwiftUI
import SwiftData
import OrbitCore

/// What "Later" moves: one scheduled block, or a whole task.
enum LaterTarget {
    case block(StoredBlock)
    case task(StoredTask)
}

/// "Later" button: quick options (in 1 hour, this evening, tomorrow, next free, pick a time),
/// then Orbit's pushback when the move looks like a bad idea. The user can always override.
struct MoveLaterButton: View {
    @Environment(AppModel.self) private var app
    var target: LaterTarget
    var label: String = "Later"
    @State private var open = false

    var body: some View {
        Button(label) { open = true }
            .help("Move to later")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                MoveLaterPanel(target: target) { open = false }
                    .environment(app)
            }
    }
}

struct MoveLaterPanel: View {
    @Environment(AppModel.self) private var app
    var target: LaterTarget
    var onDone: () -> Void

    @State private var assessment: DeferralAssessment?
    @State private var picking = false
    @State private var picked = Date().addingTimeInterval(3600)

    private var item: DeferralItem {
        switch target {
        case .block(let b): app.deferralItem(for: b)
        case .task(let t): app.deferralItem(for: t)
        }
    }

    private var excluded: Set<String> {
        if case .block(let b) = target { return [b.id] }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let assessment {
                LaterPushback(assessment: assessment, required: item.origin == .required,
                              onUse: { move(to: $0, assessment: assessment) },
                              onOverride: { move(to: assessment.target, assessment: assessment) },
                              onBack: { self.assessment = nil })
            } else {
                optionsList
            }
        }
        .padding(Theme.Space.m)
        .frame(width: 280, alignment: .leading)
    }

    private var optionsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Move to later").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
            if item.timesMoved > 0 {
                Text("Moved \(item.timesMoved) time\(item.timesMoved == 1 ? "" : "s") already")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            ForEach(app.laterOptions(for: item, excluding: excluded)) { option in
                Button { choose(option.start) } label: {
                    HStack {
                        Text(option.label)
                        Spacer()
                        Text(Fmt.dayTime(option.start, app.calendar)).foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            Hairline()
            if picking {
                DatePicker("", selection: $picked, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                Button("Move here") { choose(picked) }.buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Button("Pick a time…") { picking = true }.buttonStyle(.plain).padding(.vertical, 4)
            }
        }
        .font(Theme.body)
    }

    private func choose(_ date: Date) {
        let a = app.assessLater(item, to: date, excluding: excluded)
        if a.level == .ok { move(to: date, assessment: a) } else { withAnimation(Motion.snappy) { assessment = a } }
    }

    private func move(to date: Date, assessment: DeferralAssessment) {
        switch target {
        case .block(let b): app.moveLater(b, to: date, assessment: assessment)
        case .task(let t): app.moveLater(t, to: date, assessment: assessment)
        }
        onDone()
    }
}

/// Orbit's reasons not to move it, a better slot, and an override.
struct LaterPushback: View {
    @Environment(AppModel.self) private var app
    var assessment: DeferralAssessment
    var required: Bool
    var onUse: (Date) -> Void
    var onOverride: () -> Void
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label(assessment.level == .resist ? "Orbit wouldn't move this" : "Worth a second look",
                  systemImage: assessment.level == .resist ? "exclamationmark.triangle" : "info.circle")
                .font(Theme.body.weight(.semibold))
                .foregroundStyle(assessment.level == .resist ? Theme.danger : Theme.textPrimary)
            ForEach(assessment.messages, id: \.self) { line in
                Text(line).font(Theme.body).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if required {
                Text("This is required uni work.").font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            if let better = assessment.suggestion {
                Button("Do it \(assessment.suggestionLabel ?? Fmt.dayTime(better, app.calendar)) instead") { onUse(better) }
                    .buttonStyle(.borderedProminent)
            }
            HStack {
                Button("Back", action: onBack).buttonStyle(.borderless)
                Spacer()
                Button(assessment.level == .resist ? "Move anyway" : "Move", action: onOverride)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
    }
}
