import SwiftUI
import OrbitCore

/// Picks a time of day stored as minutes after midnight.
struct MinutePicker: View {
    var title: String
    @Binding var minutes: MinuteOfDay

    private var date: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: (minutes / 60) % 24, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { newValue in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }

    var body: some View {
        DatePicker(title, selection: date, displayedComponents: .hourAndMinute)
    }
}

/// Wrapping row of chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Chips that wrap onto new lines.
struct Flow<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: Content

    var body: some View {
        FlowLayout(spacing: spacing).callAsFunction { content }
    }
}

/// "Gmail" / "Exeter" badge.
struct AccountBadge: View {
    var account: MailAccount
    var body: some View {
        switch account {
        case .gmail: Tag(text: "Gmail", color: Theme.danger, systemImage: "envelope")
        case .exeter: Tag(text: "Exeter", color: Theme.accent, systemImage: "building.columns")
        }
    }
}

/// Small green/amber/red dot.
struct StatusDot: View {
    var color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

extension RAGStatus {
    var color: Color {
        switch self {
        case .green: Theme.success
        case .amber: Theme.warning
        case .red: Theme.danger
        }
    }
}

extension ModuleStanding.Outlook {
    var rag: RAGStatus {
        switch self {
        case .secured, .onTrack: .green
        case .stretch: .amber
        case .outOfReach, .missed: .red
        }
    }

    var label: String {
        switch self {
        case .secured: "Secured"
        case .onTrack: "On track"
        case .stretch: "Stretch"
        case .outOfReach: "Out of reach"
        case .missed: "Below target"
        }
    }
}

/// A floating message at the bottom of the window.
struct BannerOverlay: ViewModifier {
    var message: String?
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: message)
    }
}

extension View {
    func banner(_ message: String?) -> some View { modifier(BannerOverlay(message: message)) }

    /// Success haptic on iOS (no-op on Mac).
    func successHaptic<T: Equatable>(_ trigger: T) -> some View {
        #if os(iOS)
        return sensoryFeedback(.success, trigger: trigger)
        #else
        return self
        #endif
    }
}

/// Opens a URL in the default browser / app.
@MainActor
func openExternal(_ url: URL) {
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}
