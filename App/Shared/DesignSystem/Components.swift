import SwiftUI

// Basic building blocks. This file is also compiled into the widget and share
// extensions, so it only depends on SwiftUI and Theme.swift. App-only pieces
// (glass toolbars, the icon rail, rings) live in Glass.swift.

// MARK: - Cards

/// A solid rounded card: white (charcoal in dark mode) or a pastel fill,
/// radius 28, a faint edge and a very soft shadow. No materials, so it's cheap
/// to draw and scrolls smoothly.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Space.l
    var fill: Color = Theme.surface
    var radius: CGFloat = Theme.Radius.card
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .softCard(fill: fill, radius: radius)
    }
}

/// A pastel card (sage, blush, butter, lavender…), the dashboard's hero tiles.
struct PastelCard<Content: View>: View {
    var fill: Color
    var padding: CGFloat = 20
    var radius: CGFloat = Theme.Radius.card
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .softCard(fill: fill, radius: radius, shadow: false)
    }
}

extension View {
    /// The solid card look: fill, continuous corners, faint edge, soft shadow.
    func softCard(fill: Color = Theme.surface, radius: CGFloat = Theme.Radius.card, shadow: Bool = true) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.glassRim, lineWidth: 1))
            .shadow(color: shadow ? Theme.glassShadow : .clear, radius: 14, y: 4)
    }
}

// MARK: - Round buttons and icons

/// A symbol in a white circle (list rows, card headers).
struct IconCircle: View {
    var symbol: String
    var size: CGFloat = 36
    var fill: Color = Theme.surface
    var ink: Color = Theme.textPrimary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .accessibilityHidden(true)
    }
}

/// The round white "↗" button on stat tiles and cards.
struct ArrowButton: View {
    var symbol: String = "arrow.up.right"
    var size: CGFloat = 34
    var help: String = "Open"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.surface))
                .shadow(color: Theme.glassShadow, radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Shrinks a little while pressed.
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.92
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// A big-number tile: "Completed 18", "Your score 72", "Active 11".
struct StatTile: View {
    var title: String
    var value: String
    var symbol: String
    var fill: Color
    var caption: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top) {
                IconCircle(symbol: symbol, size: 32)
                Spacer(minLength: Theme.Space.s)
                if let action { ArrowButton(size: 30, help: "Open \(title)", action: action) }
            }
            Spacer(minLength: Theme.Space.xs)
            Text(value)
                .font(Theme.number(36))
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                if let caption {
                    Text(caption).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .softCard(fill: fill, shadow: false)
        .accessibilityElement(children: .combine)
    }
}

/// The pill search field ("Search…" with a magnifier), top-right of a page.
struct PillSearchField: View {
    var placeholder: String = "Search"
    @Binding var text: String
    var width: CGFloat? = 240

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.body)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: width)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - Headings

/// Section heading: rounded semibold, optional count and action.
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
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Theme.hover, in: Capsule())
                    .contentTransition(.numericText())
            }
            if let subtitle {
                Text(subtitle).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - Modules

/// Turns a module code into a plain-English title. The apps point this at
/// OrbitCore's `ModuleNames` at launch; the widgets (no OrbitCore) show the code.
enum ModuleLabel {
    nonisolated(unsafe) static var resolve: (String) -> String = { $0 }
    nonisolated(unsafe) static var symbol: (String?) -> String = { _ in "book.closed.fill" }

    static func title(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "" }
        return resolve(code)
    }
}

/// A small coloured dot for a module.
struct ModuleDot: View {
    var code: String?
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Theme.moduleColor(code))
            .frame(width: size, height: size)
    }
}

/// A module as a tinted capsule with its icon and English title
/// ("Introduction to Statistics"); the code is in the tooltip.
struct ModuleChip: View {
    var code: String?
    var showIcon = true

    var body: some View {
        if let code, !code.isEmpty {
            let color = Theme.moduleColor(code)
            HStack(spacing: 5) {
                if showIcon {
                    Image(systemName: ModuleLabel.symbol(code)).imageScale(.small)
                } else {
                    ModuleDot(code: code, size: 6)
                }
                Text(ModuleLabel.title(code))
                    .lineLimit(1)
            }
            .font(Theme.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
            .fixedSize()
            .help(code)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

// MARK: - Progress

/// A rounded progress bar with an optional target marker.
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
                    .fill(color)
                    .frame(width: max(value > 0 ? height : 0, geo.size.width * max(0, min(1, value))))
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

/// A progress ring with round caps.
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
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.bouncy, value: progress)
            if let label {
                Text(label).font(Theme.number(11, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
        }
    }
}

// MARK: - Empty state

/// Friendly empty state: an icon in a soft circle, a line of text and at most one action.
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
                IconCircle(symbol: systemImage, size: 36, fill: Theme.lavender)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title)
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                if let message {
                    Text(message)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(PillButtonStyle())
                        .padding(.top, Theme.Space.xs)
                }
            }
        }
        .padding(.vertical, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Buttons

/// Primary action: a solid ink capsule (black in light mode).
struct PillButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    var foreground: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body.weight(.semibold))
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, 8)
            .foregroundStyle(foreground ?? Theme.onAccent)
            .background(Capsule().fill(color))
            .opacity(configuration.isPressed ? 0.85 : 1)
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
                .padding(.vertical, 6)
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
