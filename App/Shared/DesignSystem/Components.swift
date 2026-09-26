import SwiftUI

// Basic building blocks. This file is also compiled into the widget and share
// extensions, so it only depends on SwiftUI and Theme.swift.

/// A flat surface with a hairline edge. Use sparingly: prefer whitespace and
/// separators. Never nest cards.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.padding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: Theme.hairline))
    }
}

/// Section heading: 13 pt semibold in secondary text, optional count and action.
struct SectionHeader: View {
    var title: String
    var subtitle: String? = nil
    var count: Int? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.headline)
                .foregroundStyle(Theme.textSecondary)
            if let count {
                Text("\(count)")
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .contentTransition(.numericText())
            }
            if let subtitle {
                Text(subtitle).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}

/// A small coloured dot for a module.
struct ModuleDot: View {
    var code: String?
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(Theme.moduleColor(code)).frame(width: size, height: size)
    }
}

/// Module code as a coloured dot plus the code in secondary text.
struct ModuleChip: View {
    var code: String?
    var body: some View {
        if let code, !code.isEmpty {
            HStack(spacing: 5) {
                ModuleDot(code: code, size: 7)
                Text(code)
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .fixedSize()
        }
    }
}

/// Quiet text tag: a faint fill, 11 pt text. Colour only when it means something.
struct Tag: View {
    var text: String
    var color: Color = Theme.textSecondary
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(text).lineLimit(1)
        }
        .font(Theme.caption)
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
        .fixedSize()
    }
}

/// A 4 pt progress bar with an optional target marker.
struct ThinProgressBar: View {
    var value: Double
    var target: Double? = nil
    var color: Color = Theme.accent
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hover)
                Capsule().fill(color)
                    .frame(width: geo.size.width * max(0, min(1, value)))
                if let target {
                    Rectangle()
                        .fill(Theme.textSecondary)
                        .frame(width: 1.5, height: height + 6)
                        .offset(x: geo.size.width * max(0, min(1, target)) - 0.75)
                }
            }
        }
        .frame(height: height)
        .animation(Motion.smooth, value: value)
    }
}

/// Thin progress ring (kept for compact places such as widgets).
struct ProgressRing: View {
    var progress: Double
    var color: Color = Theme.accent
    var lineWidth: CGFloat = 3
    var label: String? = nil

    var body: some View {
        ZStack {
            Circle().stroke(Theme.hover, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.smooth, value: progress)
            if let label { Text(label).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textPrimary) }
        }
    }
}

/// Quiet empty state: one line of text and at most one action.
struct EmptyState: View {
    var systemImage: String? = nil
    var title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    init(systemImage: String? = nil, title: String, message: String? = nil,
         actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title)
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
            if let message {
                Text(message)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(Theme.body)
                    .foregroundStyle(Theme.accent)
                    .padding(.top, Theme.Space.xs)
            }
        }
        .padding(.vertical, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Primary action: a flat accent rectangle (not a pill). Use once per screen.
struct PillButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body.weight(.medium))
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 6)
            .foregroundStyle(.white)
            .background(color.opacity(configuration.isPressed ? 0.85 : 1),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
            .animation(Motion.fade, value: configuration.isPressed)
    }
}

/// Plain text button with a hover / press fill.
struct SoftButtonStyle: ButtonStyle {
    var color: Color = Theme.textPrimary
    func makeBody(configuration: Configuration) -> some View {
        SoftButtonBody(configuration: configuration, color: color)
    }

    private struct SoftButtonBody: View {
        var configuration: ButtonStyleConfiguration
        var color: Color
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(Theme.body)
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Space.xs)
                .foregroundStyle(enabled ? color : Theme.textTertiary)
                .background(configuration.isPressed ? Theme.pressed : (hovering && enabled ? Theme.hover : Color.clear),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(Motion.fade, value: hovering)
        }
    }
}

extension View {
    /// Standard screen background.
    func orbitBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }

    /// A hairline separator below the view.
    func hairlineBelow() -> some View {
        overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: Theme.hairline) }
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

/// A full-width hairline.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: Theme.hairline)
    }
}
