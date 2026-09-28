import SwiftUI
import OrbitCore

// Colour coding for where work came from (TaskOrigin in OrbitCore):
// blue "You set", violet "Orbit recommends", orange "Required", and a hot pink
// "Do now" glow on the block that's scheduled right now.

extension TaskOrigin {
    var color: Color {
        switch self {
        case .yours: Color.dynamic(light: 0x4A7FC8, dark: 0x9CC3EE)
        case .recommended: Color.dynamic(light: 0x7E6AC9, dark: 0xC0B2F5)
        case .required: Color.dynamic(light: 0xD07A2E, dark: 0xF3B98E)
        }
    }

    /// The soft pastel fill for cards and icon circles (sky, lavender, peach).
    var pastel: Color {
        switch self {
        case .yours: Theme.sky
        case .recommended: Theme.lavender
        case .required: Theme.peach
        }
    }

    var symbol: String {
        switch self {
        case .yours: "person.fill"
        case .recommended: "wand.and.stars"
        case .required: "building.columns.fill"
        }
    }
}

enum DoNow {
    static let color = Color.dynamic(light: 0xE0667F, dark: 0xF2A1B3)
    static let label = "Do now"
}

extension StoredTask {
    var origin: TaskOrigin {
        TaskOrigin.of(source: source, sourceRef: sourceRef, moduleCode: moduleCode, assessmentID: assessmentID)
    }
}

/// A small coloured dot for a task's origin.
struct OriginDot: View {
    var origin: TaskOrigin
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(origin.color.gradient)
            .frame(width: size, height: size)
            .help(origin.label)
            .accessibilityLabel(origin.label)
    }
}

/// "Required" / "Orbit recommends" / "You set" as a tinted capsule.
struct OriginChip: View {
    var origin: TaskOrigin
    var short = true

    var body: some View {
        Tag(text: short ? origin.shortLabel : origin.label, color: origin.color, systemImage: origin.symbol)
    }
}

/// "Do now" capsule with a pulsing dot.
struct DoNowBadge: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(DoNow.color).frame(width: 6, height: 6)
                .scaleEffect(pulse ? 1.4 : 1)
                .opacity(pulse ? 0.6 : 1)
            Text(DoNow.label)
        }
        .font(Theme.caption.weight(.bold))
        .foregroundStyle(DoNow.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(DoNow.color.opacity(0.14), in: Capsule())
        .fixedSize()
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// The legend shown on Home: three origins plus "Do now".
struct OriginLegend: View {
    var body: some View {
        HStack(spacing: Theme.Space.m) {
            ForEach(TaskOrigin.allCases) { o in
                HStack(spacing: 5) {
                    OriginDot(origin: o)
                    Text(o.label)
                }
            }
            HStack(spacing: 5) {
                Circle().fill(DoNow.color).frame(width: 7, height: 7)
                Text(DoNow.label)
            }
        }
        .font(Theme.caption.weight(.medium))
        .foregroundStyle(Theme.textSecondary)
    }
}

/// Filter chips for Tasks: All / You set / Orbit recommends / Required.
struct OriginFilterChips: View {
    @Binding var selection: TaskOrigin?
    var counts: [TaskOrigin: Int] = [:]

    var body: some View {
        HStack(spacing: 6) {
            chip(nil, "All", color: Theme.accent, count: counts.values.reduce(0, +))
            ForEach(TaskOrigin.allCases) { o in
                chip(o, o.label, color: o.color, count: counts[o] ?? 0)
            }
        }
    }

    private func chip(_ value: TaskOrigin?, _ title: String, color: Color, count: Int) -> some View {
        let selected = selection == value
        return Button {
            withAnimation(Motion.snappy) { selection = value }
        } label: {
            HStack(spacing: 5) {
                if let value { OriginDot(origin: value) }
                Text(title)
                if count > 0 {
                    Text("\(count)").monospacedDigit().foregroundStyle(selected ? color : Theme.textTertiary)
                }
            }
            .font(Theme.caption.weight(.semibold))
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(selected ? color.opacity(0.18) : Theme.hover))
            .overlay(Capsule().strokeBorder(selected ? color.opacity(0.5) : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
