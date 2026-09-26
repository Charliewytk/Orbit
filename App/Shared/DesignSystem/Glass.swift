import SwiftUI
import OrbitCore

// Orbit Glass: the Liquid Glass layer (apps only; not compiled into extensions).
//
// Every macOS 26 / iOS 26 API is used behind two guards:
//   #if compiler(>=6.2)                → Xcode 16 (Swift 6.0/6.1) never sees the symbols
//   if #available(macOS 26.0, iOS 26.0, *) → older systems get the fallback at run time
// The fallback is a material with a bright rim and a soft shadow, so the app looks
// the same family on macOS 15.

// MARK: - Glass surfaces

/// What `orbitGlass` falls back to before macOS 26: material + tint + rim + shadow.
struct GlassFallback<S: Shape>: ViewModifier {
    var shape: S
    var tint: Color?
    var shadow: Bool = true
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint { shape.fill(tint.opacity(scheme == .dark ? 0.16 : 0.1)) }
                    shape.fill(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.06 : 0.35), .clear],
                                              startPoint: .top, endPoint: .center))
                }
            }
            .overlay {
                shape.stroke(LinearGradient(colors: [Theme.glassRim, Theme.glassRim.opacity(0.15)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
            }
            .shadow(color: shadow ? Theme.glassShadow : .clear, radius: 16, y: 6)
    }
}

extension View {
    /// Liquid Glass on macOS 26 / iOS 26, material glass before.
    @ViewBuilder
    func orbitGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint.map { $0.opacity(0.35) }).interactive(interactive), in: shape)
        } else {
            self.modifier(GlassFallback(shape: shape, tint: tint))
        }
        #else
        self.modifier(GlassFallback(shape: shape, tint: tint))
        #endif
    }

    /// Glass in the standard card shape.
    func orbitGlassCard(radius: CGFloat = Theme.Radius.card, tint: Color? = nil) -> some View {
        orbitGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint)
    }

    /// Clear-ish glass for small floating controls (capsule).
    @ViewBuilder
    func orbitGlassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        orbitGlass(in: Capsule(), tint: tint, interactive: interactive)
    }

    /// `.buttonStyle(.glass)` on macOS 26, a glass capsule before.
    @ViewBuilder
    func orbitGlassButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(GlassCapsuleButtonStyle())
        }
        #else
        self.buttonStyle(GlassCapsuleButtonStyle())
        #endif
    }

    /// `.buttonStyle(.glassProminent)` tinted on macOS 26, a gradient capsule before.
    @ViewBuilder
    func orbitGlassProminentButton(_ color: Color = Theme.accent) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(color)
        } else {
            self.buttonStyle(PillButtonStyle(color: color))
        }
        #else
        self.buttonStyle(PillButtonStyle(color: color))
        #endif
    }

    /// Mirrors content under the sidebar / toolbar on macOS 26 (no-op before).
    @ViewBuilder
    func orbitBackgroundExtension() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            self.backgroundExtensionEffect()
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Standard screen background: the ambient backdrop. Skipped inside a glass
    /// pane (TwoPane), so there's only ever one backdrop on screen.
    func orbitBackground() -> some View {
        modifier(OrbitBackdropModifier())
    }

    /// For Form / List screens: hide their opaque background and show the backdrop.
    func orbitScreen() -> some View {
        scrollContentBackground(.hidden).orbitBackground()
    }
}

/// Draws the ambient backdrop unless the view already sits inside a glass pane.
struct OrbitBackdropModifier: ViewModifier {
    @Environment(\.inGlassPane) private var inGlassPane

    func body(content: Content) -> some View {
        if inGlassPane {
            content
        } else {
            content.background { AmbientBackdrop().ignoresSafeArea() }
        }
    }
}

private struct InGlassPaneKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside TwoPane's glass panes (screens there don't draw their own backdrop).
    var inGlassPane: Bool {
        get { self[InGlassPaneKey.self] }
        set { self[InGlassPaneKey.self] = newValue }
    }
}

/// Groups glass shapes so they render (and morph) together on macOS 26.
struct OrbitGlassContainer<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// A glass capsule button (fallback for `.glass`).
struct GlassCapsuleButtonStyle: ButtonStyle {
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body.weight(.medium))
            .foregroundStyle(tint ?? Theme.textPrimary)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 6)
            .modifier(GlassFallback(shape: Capsule(), tint: tint, shadow: false))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// A padded glass card (the dashboard's building block).
struct GlassCard<Content: View>: View {
    var padding: CGFloat = Theme.Space.l
    var tint: Color? = nil
    var radius: CGFloat = Theme.Radius.card
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .orbitGlassCard(radius: radius, tint: tint)
    }
}

// MARK: - Ambient backdrop

/// Time of day, for the backdrop colours and the greeting.
enum DayPhase {
    case dawn, day, dusk, night

    static func at(_ date: Date, calendar: Calendar = .current) -> DayPhase {
        let h = calendar.component(.hour, from: date)
        switch h {
        case 5..<9: return .dawn
        case 9..<17: return .day
        case 17..<21: return .dusk
        default: return .night
        }
    }

    /// Nine mesh colours (3 × 3, row by row).
    func colors(dark: Bool) -> [Color] {
        let hex: [UInt32]
        switch (self, dark) {
        case (.dawn, false): hex = [0xFFD9C7, 0xFFC4DA, 0xE4D4FF, 0xFFE8D6, 0xF7D6FF, 0xD7DEFF, 0xFFF1E4, 0xE9E1FF, 0xCFE4FF]
        case (.day, false): hex = [0xD6E4FF, 0xE3DAFF, 0xFFDDF0, 0xDDF3FF, 0xECE6FF, 0xE2DCFF, 0xD2F4EC, 0xDCE6FF, 0xF3DDFF]
        case (.dusk, false): hex = [0xFFD2B8, 0xFFB8D2, 0xE0C2FF, 0xFFC9C0, 0xF4C6F0, 0xC9C6FF, 0xFFDCC4, 0xE8C8FF, 0xBFC8FF]
        case (.night, false): hex = [0xCFD3FF, 0xDCCBFF, 0xE9CCF5, 0xD4DAFF, 0xE2D8FF, 0xCFC7F7, 0xD9E0FF, 0xD8CEFF, 0xE4D0F7]
        case (.dawn, true): hex = [0x2A1633, 0x3A1A3B, 0x221A45, 0x2D1830, 0x2A1B40, 0x1A1D46, 0x1E1428, 0x241A3E, 0x141B3A]
        case (.day, true): hex = [0x10193D, 0x1C1644, 0x2B1540, 0x0F2140, 0x1B1A48, 0x221748, 0x0E2230, 0x161B44, 0x271644]
        case (.dusk, true): hex = [0x2E1726, 0x3A1636, 0x251745, 0x301A26, 0x2C1840, 0x1C1A48, 0x24141E, 0x2A1740, 0x161838]
        case (.night, true): hex = [0x0B0D24, 0x150E2E, 0x1E0F33, 0x0C1330, 0x14123A, 0x1A1034, 0x080C1E, 0x10102E, 0x170D2A]
        }
        return hex.map { Color(hex: $0) }
    }
}

/// A soft, slowly moving mesh gradient that shifts colour with the time of day.
/// One per screen; cheap (GPU mesh) and paused with Reduce Motion.
struct AmbientBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var phase: DayPhase? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let colors = (phase ?? DayPhase.at(context.date)).colors(dark: scheme == .dark)
            MeshGradient(width: 3, height: 3, points: Self.points(t), colors: colors, smoothsColors: true)
                .overlay {
                    // A faint veil keeps text readable on every colour.
                    (scheme == .dark ? Color.black.opacity(0.18) : Color.white.opacity(0.22))
                }
        }
        .accessibilityHidden(true)
    }

    /// Corners and edges stay put; the middle points drift in slow loops.
    static func points(_ t: TimeInterval) -> [SIMD2<Float>] {
        func wobble(_ speed: Double, _ offset: Double, _ amount: Double) -> Float {
            Float(0.5 + sin(t * speed + offset) * amount)
        }
        func p(_ x: Float, _ y: Float) -> SIMD2<Float> { SIMD2<Float>(x, y) }
        let top = wobble(0.11, 0, 0.12)
        let left = wobble(0.09, 1, 0.12)
        let midX = wobble(0.13, 2, 0.16)
        let midY = wobble(0.1, 3, 0.16)
        let right = wobble(0.08, 4, 0.12)
        let bottom = wobble(0.12, 5, 0.12)
        return [
            p(0, 0), p(top, 0), p(1, 0),
            p(0, left), p(midX, midY), p(1, right),
            p(0, 1), p(bottom, 1), p(1, 1),
        ]
    }
}

// MARK: - Icons

/// A rounded-square colour tile with a white symbol (macOS Settings style).
struct IconTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            .shadow(color: color.opacity(0.35), radius: 3, y: 1)
    }
}

// MARK: - Rings

/// One ring: a gradient arc with round caps; glows when complete.
struct RingArc: View {
    var progress: Double
    var start: Color
    var end: Color
    var lineWidth: CGFloat

    var body: some View {
        let p = max(0, progress)
        ZStack {
            Circle().stroke(start.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0001, min(1, p)))
                .stroke(AngularGradient(colors: [start, end], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(0.05, min(1, p)))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: p >= 1 ? end.opacity(0.6) : .clear, radius: lineWidth * 0.5)
            if p > 1 {
                // Second lap: a short overlay arc so going past the goal shows.
                Circle()
                    .trim(from: 0, to: min(1, p - 1))
                    .stroke(end, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: .black.opacity(0.25), radius: 2)
            }
        }
    }
}

/// Fitness-style concentric rings: study minutes, to-dos, reviews.
struct ActivityRings: View {
    var study: Double
    var tasks: Double
    var reviews: Double
    var size: CGFloat = 132
    var lineWidth: CGFloat? = nil
    @State private var shown = false

    var body: some View {
        let w = lineWidth ?? size * 0.12
        let gap = w * 1.15
        ZStack {
            RingArc(progress: shown ? study : 0, start: Theme.ringStudy, end: Theme.ringStudyEnd, lineWidth: w)
                .frame(width: size, height: size)
            RingArc(progress: shown ? tasks : 0, start: Theme.ringTasks, end: Theme.ringTasksEnd, lineWidth: w)
                .frame(width: size - gap * 2, height: size - gap * 2)
            RingArc(progress: shown ? reviews : 0, start: Theme.ringReviews, end: Theme.ringReviewsEnd, lineWidth: w)
                .frame(width: size - gap * 4, height: size - gap * 4)
        }
        .frame(width: size, height: size)
        .animation(Motion.bouncy, value: study)
        .animation(Motion.bouncy, value: tasks)
        .animation(Motion.bouncy, value: reviews)
        .onAppear { withAnimation(.spring(response: 1.1, dampingFraction: 0.8).delay(0.15)) { shown = true } }
        .accessibilityElement()
        .accessibilityLabel("Study \(Int(study * 100))%, to-dos \(Int(tasks * 100))%, reviews \(Int(reviews * 100))%")
    }
}

// MARK: - Heatmap

/// GitHub-style heatmap of the last weeks (columns = weeks, Monday on top).
struct ActivityHeatmap: View {
    var cells: [[HeatCell?]]
    var cell: CGFloat = 11
    var spacing: CGFloat = 3

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(cells.indices, id: \.self) { w in
                VStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { d in
                        let c = d < cells[w].count ? cells[w][d] : nil
                        RoundedRectangle(cornerRadius: cell * 0.3, style: .continuous)
                            .fill(color(c?.level))
                            .frame(width: cell, height: cell)
                            .help(c.map(tooltip) ?? "")
                    }
                }
            }
        }
    }

    private func color(_ level: Int?) -> Color {
        guard let level else { return .clear }
        switch level {
        case 0: return Theme.hover
        case 1: return Theme.accent.opacity(0.3)
        case 2: return Theme.accent.opacity(0.55)
        case 3: return Theme.violet.opacity(0.85)
        default: return Theme.pink
        }
    }

    private func tooltip(_ c: HeatCell) -> String {
        "\(c.day): \(Fmt.duration(c.stats.studyMinutes)) study · \(c.stats.tasksDone) to-dos · \(c.stats.reviews) reviews"
    }
}

// MARK: - Motion

/// Cards arrive with a staggered fade, rise and scale.
struct StaggeredAppear: ViewModifier {
    var index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .scaleEffect(shown || reduceMotion ? 1 : 0.98)
            .onAppear {
                withAnimation(Motion.arrive.delay(Double(min(index, 14)) * 0.045)) { shown = true }
            }
    }
}

/// Hover: lifts slightly with a stronger shadow.
struct HoverLift: ViewModifier {
    var amount: CGFloat = 1.012
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? amount : 1)
            .shadow(color: Theme.glassShadow.opacity(hovering ? 1 : 0), radius: hovering ? 22 : 0, y: hovering ? 10 : 0)
            .onHover { hovering = $0 }
            .animation(Motion.snappy, value: hovering)
    }
}

extension View {
    func staggeredAppear(_ index: Int) -> some View { modifier(StaggeredAppear(index: index)) }
    func hoverLift(_ amount: CGFloat = 1.012) -> some View { modifier(HoverLift(amount: amount)) }
}

/// A small burst of dots (confetti-lite) each time `trigger` changes.
struct CheckBurst: View {
    var trigger: Int
    var colors: [Color] = [Theme.pink, Theme.violet, Theme.cyan, Theme.success, Theme.warning]
    @State private var fired = false

    var body: some View {
        ZStack {
            ForEach(0..<10, id: \.self) { i in
                let angle = Double(i) / 10 * 2 * .pi
                Circle()
                    .fill(colors[i % colors.count])
                    .frame(width: 5, height: 5)
                    .offset(x: fired ? cos(angle) * 22 : 0, y: fired ? sin(angle) * 22 : 0)
                    .opacity(fired ? 0 : 1)
                    .scaleEffect(fired ? 0.4 : 1)
            }
        }
        .allowsHitTesting(false)
        .opacity(trigger == 0 ? 0 : 1)
        .onChange(of: trigger) { _, _ in
            fired = false
            withAnimation(.easeOut(duration: 0.6)) { fired = true }
        }
    }
}

// MARK: - Glass segmented control

/// A capsule segmented control with a sliding glass thumb.
struct GlassSegmented<Value: Hashable>: View {
    var options: [(value: Value, title: String)]
    @Binding var selection: Value
    var counts: [Value: Int] = [:]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let selected = option.value == selection
                Button {
                    withAnimation(Motion.snappy) { selection = option.value }
                } label: {
                    HStack(spacing: 5) {
                        Text(option.title)
                        if let n = counts[option.value], n > 0 {
                            Text("\(n)")
                                .font(Theme.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                        }
                    }
                    .font(Theme.body.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Theme.surface)
                                .shadow(color: Theme.glassShadow, radius: 6, y: 2)
                                .matchedGeometryEffect(id: "thumb", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .orbitGlass(in: Capsule())
    }
}
