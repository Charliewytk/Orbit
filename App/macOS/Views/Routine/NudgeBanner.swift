import SwiftUI
import OrbitCore

/// The current top nudge as a glass banner under the Home header.
struct NudgeBanner: View {
    var nudge: Nudge
    private var nudges: NudgeService { FeatureHub.shared.nudges }
    private var routine: RoutineService { FeatureHub.shared.routine }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(symbol: symbol, color: color, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(nudge.title)
                    .font(Theme.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(nudge.body)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Space.m)
            actions
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .orbitGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous), tint: color.opacity(0.5))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(LinearGradient(colors: [color.opacity(0.7), color.opacity(0.15)], startPoint: .leading, endPoint: .trailing),
                              lineWidth: 1)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            switch nudge.kind {
            case .shutdown:
                Button("Start shutdown") { routine.openShutdown() }
                    .orbitGlassProminentButton(Theme.violet)
            case .mealClosing:
                Button("Ate it") {
                    let id = String(nudge.id.dropFirst("meal:".count))
                    if let block = routine.blocks(on: Date()).first(where: { $0.id == id }) { routine.toggleDone(block) }
                    nudges.dismissBanner()
                }
                .orbitGlassProminentButton(Theme.success)
            default:
                if nudge.focusMinutes != nil || nudge.taskID != nil || nudge.blockID != nil {
                    Button("Start focus") { nudges.startFromBanner() }
                        .orbitGlassProminentButton(color)
                }
            }
            Button("Snooze 30m") { nudges.snoozeBanner() }
                .orbitGlassButton()
            Button {
                nudges.dismissBanner()
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary)
            .help("Not now")
        }
    }

    private var symbol: String {
        switch nudge.kind {
        case .freeGap: "hourglass"
        case .blockStarting: "play.circle.fill"
        case .deadlineNoProgress: "exclamationmark.circle.fill"
        case .mealClosing: "fork.knife"
        case .typeUp: "keyboard.fill"
        case .flashcardsDue: "rectangle.on.rectangle.angled"
        case .streakAtRisk: "flame.fill"
        case .shutdown: "moon.stars.fill"
        case .reading: "book.fill"
        }
    }

    private var color: Color {
        switch nudge.kind {
        case .freeGap, .blockStarting: DoNow.color
        case .deadlineNoProgress: Theme.danger
        case .mealClosing: Theme.routine
        case .typeUp: TaskOrigin.recommended.color
        case .flashcardsDue: Theme.cyan
        case .streakAtRisk: .orange
        case .shutdown, .reading: Theme.violet
        }
    }
}

/// "All systems go" / "2 need attention": opens Settings → Health.
struct HealthPill: View {
    private var health: HealthService { FeatureHub.shared.health }

    var body: some View {
        let problems = health.problems
        let worst = health.worst
        Button {
            HealthService.openSettings(tab: MacSettingsView.Tab.health.rawValue)
        } label: {
            HStack(spacing: 6) {
                StatusDot(color: color(worst))
                Text(health.rows.isEmpty ? "Checking…" : problems.isEmpty ? "All systems go"
                     : "\(problems.count) need\(problems.count == 1 ? "s" : "") attention")
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 5)
            .orbitGlass(in: Capsule(), tint: worst == .ok ? nil : color(worst).opacity(0.4), interactive: true)
        }
        .buttonStyle(.plain)
        .help(problems.isEmpty ? "Every connection is healthy." : problems.map { "\($0.title): \($0.detail)" }.joined(separator: "\n"))
    }

    private func color(_ level: HealthRow.Level) -> Color {
        switch level {
        case .ok: Theme.success
        case .warning: Theme.warning
        case .broken: Theme.danger
        }
    }
}
