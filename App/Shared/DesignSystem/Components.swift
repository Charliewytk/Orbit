import SwiftUI

/// The standard rounded card used across Orbit.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.padding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
    }
}

/// Section header with an optional trailing action.
struct SectionHeader: View {
    var title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.headline).foregroundStyle(Theme.textPrimary)
                if let subtitle { Text(subtitle).font(Theme.caption).foregroundStyle(Theme.textSecondary) }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action).font(Theme.caption).buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
        }
    }
}

/// Small coloured capsule showing a module code.
struct ModuleChip: View {
    var code: String?
    var body: some View {
        if let code, !code.isEmpty {
            Text(code)
                .font(Theme.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(Theme.moduleColor(code))
                .background(Theme.moduleColor(code).opacity(0.14), in: Capsule())
        }
    }
}

/// Generic tag capsule.
struct Tag: View {
    var text: String
    var color: Color = Theme.textSecondary
    var systemImage: String? = nil
    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage { Image(systemName: systemImage) }
        }
        .labelStyle(.titleAndIcon)
        .font(Theme.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// Round progress ring (used for "on track for a First", daily progress).
struct ProgressRing: View {
    var progress: Double
    var color: Color = Theme.accent
    var lineWidth: CGFloat = 6
    var label: String? = nil

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Theme.spring, value: progress)
            if let label { Text(label).font(Theme.caption).foregroundStyle(Theme.textPrimary) }
        }
    }
}

/// Friendly empty state.
struct EmptyState: View {
    var systemImage: String
    var title: String
    var message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 34, weight: .light)).foregroundStyle(Theme.textTertiary)
            Text(title).font(Theme.headline).foregroundStyle(Theme.textPrimary)
            Text(message).font(Theme.callout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// Primary pill button style.
struct PillButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, design: .rounded).weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 9)
            .foregroundStyle(.white)
            .background(color.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

/// Soft secondary button.
struct SoftButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, design: .rounded).weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(color)
            .background(color.opacity(configuration.isPressed ? 0.2 : 0.12), in: Capsule())
    }
}

extension View {
    /// Standard screen background.
    func orbitBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }

    /// Light haptic on iOS; no-op on Mac.
    func haptic<T: Equatable>(_ trigger: T) -> some View {
        #if os(iOS)
        return sensoryFeedback(.selection, trigger: trigger)
        #else
        return self
        #endif
    }
}
