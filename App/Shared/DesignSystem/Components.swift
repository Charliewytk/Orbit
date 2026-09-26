import SwiftUI

// Basic building blocks. This file is also compiled into the widget and share
// extensions, so it only depends on SwiftUI and Theme.swift. The glass
// modifiers (`orbitGlass`, `GlassCard`, the ambient backdrop) live in
// Glass.swift, which only the apps compile.

/// A translucent card with a soft rim. In the apps prefer `GlassCard`, which
/// uses real Liquid Glass on macOS 26.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.padding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.glassRim, lineWidth: 0.75))
            .shadow(color: Theme.glassShadow, radius: 18, y: 8)
    }
}

/// Section heading: 13 pt semibold, optional count and action.
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
                .foregroundStyle(Theme.textPrimary)
            if let count {
                Text("\(count)")
                    .font(Theme.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
                    .contentTransition(.numericText())
            }
            if let subtitle {
                Text(subtitle).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}

/// A small coloured dot for a module (with a soft glow).
struct ModuleDot: View {
    var code: String?
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Theme.moduleColor(code).gradient)
            .frame(width: size, height: size)
            .shadow(color: Theme.moduleColor(code).opacity(0.5), radius: size * 0.4)
    }
}

/// Module code as a tinted capsule.
struct ModuleChip: View {
    var code: String?
    var body: some View {
        if let code, !code.isEmpty {
            HStack(spacing: 5) {
                ModuleDot(code: code, size: 6)
                Text(code)
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.moduleColor(code))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.moduleColor(code).opacity(0.14), in: Capsule())
            .fixedSize()
        }
    }
}

/// Small tinted capsule tag.
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
        .font(Theme.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.13), in: Capsule())
        .fixedSize()
    }
}

/// A rounded progress bar with a gradient fill and an optional target marker.
struct ThinProgressBar: View {
    var value: Double
    var target: Double? = nil
    var color: Color = Theme.accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hover)
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(value > 0 ? height : 0, geo.size.width * max(0, min(1, value))))
                    .shadow(color: color.opacity(0.35), radius: 4)
                if let target {
                    Capsule()
                        .fill(Theme.textSecondary)
                        .frame(width: 2, height: height + 6)
                        .offset(x: geo.size.width * max(0, min(1, target)) - 1)
                }
            }
        }
        .frame(height: height)
        .animation(Motion.smooth, value: value)
    }
}

/// A progress ring with a gradient stroke and round caps.
struct ProgressRing: View {
    var progress: Double
    var color: Color = Theme.accent
    var lineWidth: CGFloat = 4
    var label: String? = nil

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(AngularGradient(colors: [color.opacity(0.7), color], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(0.01, min(1, progress)))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.bouncy, value: progress)
            if let label {
                Text(label).font(Theme.number(11, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
        }
    }
}

/// Friendly empty state: a tinted icon, a line of text and at most one action.
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
        HStack(alignment: .top, spacing: Theme.Space.m) {
            if let systemImage, !systemImage.isEmpty {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title)
                    .font(Theme.body.weight(.medium))
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
                        .font(Theme.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, Theme.Space.xs)
                }
            }
        }
        .padding(.vertical, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Primary action: a gradient capsule with a soft glow.
struct PillButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body.weight(.semibold))
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, 7)
            .foregroundStyle(.white)
            .background(
                Capsule().fill(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom))
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.75))
            .shadow(color: color.opacity(configuration.isPressed ? 0.15 : 0.35), radius: 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// Plain text button with a hover / press capsule.
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
                .font(Theme.body.weight(.medium))
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 5)
                .foregroundStyle(enabled ? color : Theme.textTertiary)
                .background(configuration.isPressed ? Theme.pressed : (hovering && enabled ? Theme.hover : Color.clear),
                            in: Capsule())
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(Motion.fade, value: hovering)
                .animation(Motion.snappy, value: configuration.isPressed)
        }
    }
}

extension View {
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
