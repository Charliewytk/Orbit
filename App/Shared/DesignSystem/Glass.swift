import SwiftUI
import OrbitCore
#if os(macOS)
import AppKit
#endif

// Orbit Soft: the app-only visual layer (not compiled into the extensions).
//
// Cards are solid (white or pastel) with a faint edge and a soft shadow: cheap to
// draw, calm to look at. Liquid Glass is used only for small floating toolbar
// controls. Every macOS 26 / iOS 26 API sits behind two guards:
//   #if compiler(>=6.2)                → Xcode 16 (Swift 6.0/6.1) never sees the symbols
//   if #available(macOS 26.0, iOS 26.0, *) → older systems get the fallback at run time

// MARK: - Surfaces

/// The solid surface every former "glass" call now draws: fill (+ optional
/// pastel tint), faint edge, soft shadow.
struct SoftSurface<S: Shape>: ViewModifier {
    var shape: S
    var tint: Color?
    var shadow: Bool = true

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(Theme.surface)
                    if let tint { shape.fill(tint.opacity(0.12)) }
                }
            }
            .overlay { shape.stroke(Theme.glassRim, lineWidth: 1) }
            .shadow(color: shadow ? Theme.glassShadow : .clear, radius: 14, y: 4)
    }
}

extension View {
    /// A solid soft surface in `shape` (the old glass call; no material any more).
    func orbitGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(SoftSurface(shape: shape, tint: tint))
    }

    /// The standard card: solid, radius 28.
    func orbitGlassCard(radius: CGFloat = Theme.Radius.card, tint: Color? = nil) -> some View {
        orbitGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint)
    }

    /// Small capsule surface (chips, footers).
    func orbitGlassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        orbitGlass(in: Capsule(), tint: tint)
    }

    /// Real Liquid Glass, for floating toolbar controls only (a surface capsule before macOS 26).
    @ViewBuilder
    func orbitToolbarGlass<S: Shape>(in shape: S) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            self.glassEffect(Glass.regular.interactive(), in: shape)
        } else {
            self.modifier(SoftSurface(shape: shape, tint: nil, shadow: false))
        }
        #else
        self.modifier(SoftSurface(shape: shape, tint: nil, shadow: false))
        #endif
    }

    /// Secondary button: a white capsule with ink text.
    func orbitGlassButton() -> some View {
        buttonStyle(GlassCapsuleButtonStyle())
    }

    /// Primary button: a solid ink capsule (or `color`).
    func orbitGlassProminentButton(_ color: Color = Theme.accent) -> some View {
        buttonStyle(PillButtonStyle(color: color))
    }

    /// Mirrors content under the toolbar on macOS 26 (no-op before).
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

    /// Standard screen background: the flat off-white canvas.
    func orbitBackground() -> some View {
        modifier(OrbitBackdropModifier())
    }

    /// For Form / List screens: hide their opaque background and show the canvas.
    func orbitScreen() -> some View {
        scrollContentBackground(.hidden).orbitBackground()
    }
}

/// Draws the canvas unless the view already sits inside a card pane.
struct OrbitBackdropModifier: ViewModifier {
    @Environment(\.inGlassPane) private var inGlassPane

    func body(content: Content) -> some View {
        if inGlassPane {
            content
        } else {
            content.background { Theme.background.ignoresSafeArea() }
        }
    }
}

private struct InGlassPaneKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside TwoPane's card panes (screens there don't draw their own canvas).
    var inGlassPane: Bool {
        get { self[InGlassPaneKey.self] }
        set { self[InGlassPaneKey.self] = newValue }
    }
}

/// Groups glass shapes on macOS 26 (only toolbars use glass now).
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

/// Secondary capsule button: white fill, faint edge, ink label.
struct GlassCapsuleButtonStyle: ButtonStyle {
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body.weight(.semibold))
            .foregroundStyle(tint ?? Theme.textPrimary)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 7)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// A padded card (kept name; now a solid card).
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

// MARK: - Backdrop

/// Time of day, for the greeting.
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
}

/// The canvas. It used to be an animated mesh gradient redrawn 15 times a
/// second on every screen; now it's a flat colour (nothing to redraw).
struct AmbientBackdrop: View {
    var phase: DayPhase? = nil

    var body: some View {
        Theme.background.accessibilityHidden(true)
    }
}

// MARK: - Icons

/// A soft rounded tile: pastel tint with a coloured symbol.
struct IconTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous).fill(color.opacity(0.16))
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Rings

/// One ring: an arc with round caps.
struct RingArc: View {
    var progress: Double
    var start: Color
    var end: Color
    var lineWidth: CGFloat

    var body: some View {
        let p = max(0, progress)
        ZStack {
            Circle().stroke(start.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0001, min(1, p)))
                .stroke(LinearGradient(colors: [start, end], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if p > 1 {
                Circle()
                    .trim(from: 0, to: min(1, p - 1))
                    .stroke(end, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

/// Concentric rings: study minutes, to-dos, reviews. Bounce when they move and
/// pop once when all three close.
struct ActivityRings: View {
    var study: Double
    var tasks: Double
    var reviews: Double
    var size: CGFloat = 132
    var lineWidth: CGFloat? = nil
    @State private var shown = false
    @State private var closedPop = false

    private var allClosed: Bool { study >= 1 && tasks >= 1 && reviews >= 1 }

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
        .scaleEffect(closedPop ? 1.08 : 1)
        .animation(Motion.bouncy, value: study)
        .animation(Motion.bouncy, value: tasks)
        .animation(Motion.bouncy, value: reviews)
        .onAppear { withAnimation(.spring(response: 1.0, dampingFraction: 0.72).delay(0.1)) { shown = true } }
        .onChange(of: allClosed) { _, closed in
            guard closed else { return }
            withAnimation(Motion.bouncy) { closedPop = true }
            withAnimation(Motion.bouncy.delay(0.35)) { closedPop = false }
        }
        .accessibilityElement()
        .accessibilityLabel("Study \(Int(study * 100))%, to-dos \(Int(tasks * 100))%, reviews \(Int(reviews * 100))%")
    }
}

// MARK: - Heatmap

/// GitHub-style heatmap of the last weeks (columns = weeks, Monday on top), in sage.
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
        .drawingGroup()
    }

    private func color(_ level: Int?) -> Color {
        guard let level else { return .clear }
        switch level {
        case 0: return Theme.hover
        case 1: return Theme.sageInk.opacity(0.25)
        case 2: return Theme.sageInk.opacity(0.45)
        case 3: return Theme.sageInk.opacity(0.7)
        default: return Theme.sageInk
        }
    }

    private func tooltip(_ c: HeatCell) -> String {
        "\(c.day): \(Fmt.duration(c.stats.studyMinutes)) study · \(c.stats.tasksDone) to-dos · \(c.stats.reviews) reviews"
    }
}

// MARK: - Motion

/// Cards arrive with a short staggered fade and rise (skipped with Reduce Motion).
struct StaggeredAppear: ViewModifier {
    var index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .onAppear {
                guard !shown, !reduceMotion else { return }
                withAnimation(Motion.arrive.delay(Double(min(index, 8)) * 0.035)) { shown = true }
            }
    }
}

/// Hover: a gentle lift (no shadow animation, which is expensive on big cards).
struct HoverLift: ViewModifier {
    var amount: CGFloat = 1.006
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? amount : 1)
            .onHover { hovering = $0 }
            .animation(Motion.snappy, value: hovering)
    }
}

extension View {
    func staggeredAppear(_ index: Int) -> some View { modifier(StaggeredAppear(index: index)) }
    func hoverLift(_ amount: CGFloat = 1.006) -> some View { modifier(HoverLift(amount: amount)) }
}

/// A small burst of pastel dots each time `trigger` changes (the checkbox tick).
struct CheckBurst: View {
    var trigger: Int
    var colors: [Color] = [Theme.ringStudy, Theme.ringTasks, Theme.ringReviews, Theme.butterInk, Theme.skyInk]
    @State private var fired = false

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) / 8 * 2 * .pi
                Circle()
                    .fill(colors[i % colors.count])
                    .frame(width: 5, height: 5)
                    .offset(x: fired ? cos(angle) * 20 : 0, y: fired ? sin(angle) * 20 : 0)
                    .opacity(fired ? 0 : 1)
                    .scaleEffect(fired ? 0.4 : 1)
            }
        }
        .allowsHitTesting(false)
        .opacity(trigger == 0 ? 0 : 1)
        .onChange(of: trigger) { _, _ in
            fired = false
            withAnimation(.easeOut(duration: 0.55)) { fired = true }
        }
    }
}

/// Subtle confetti: ~36 pastel pieces fall and fade once per `trigger` change.
/// Drawn in one Canvas (cheap), gone after ~1.8 s, skipped with Reduce Motion.
struct ConfettiView: View {
    var trigger: Int
    @State private var start: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let colors: [Color] = [
        Color(hex: 0xE8849A), Color(hex: 0x6FB47E), Color(hex: 0x8C7FD9), Color(hex: 0xE9C24A),
        Color(hex: 0x6FA3D8), Color(hex: 0xF0A36E),
    ]
    private let duration = 1.8

    var body: some View {
        Group {
            if let start, !reduceMotion {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSince(start)
                    Canvas { ctx, size in
                        guard t < duration else { return }
                        for i in 0..<36 {
                            let seed = Double(i) * 12.9898
                            let r1 = abs(sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1)
                            let r2 = abs(sin(seed * 1.7) * 24634.6345).truncatingRemainder(dividingBy: 1)
                            let x = size.width * (0.1 + 0.8 * r1) + sin(t * 3 + seed) * 12
                            let y = -10 + (size.height * 0.75) * (t / duration) * (0.6 + 0.6 * r2) + 40 * r2
                            let rect = CGRect(x: x, y: y, width: 7, height: 4)
                            var piece = ctx
                            piece.opacity = max(0, 1 - t / duration)
                            piece.translateBy(x: rect.midX, y: rect.midY)
                            piece.rotate(by: .radians(t * 4 + seed))
                            piece.fill(Path(roundedRect: CGRect(x: -3.5, y: -2, width: 7, height: 4), cornerRadius: 1.5),
                                       with: .color(Self.colors[i % Self.colors.count]))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            start = Date()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(duration + 0.1))
                start = nil
            }
        }
    }
}

// MARK: - Sounds

/// Small, optional sounds (Settings → General → "Play sounds"; on by default).
enum OrbitSound {
    static let enabledKey = "orbit.sounds"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// A soft tick when a to-do is completed.
    static func tick() { play("Pop", volume: 0.35) }
    /// All rings closed / a badge earned.
    static func celebrate() { play("Glass", volume: 0.4) }

    private static func play(_ name: String, volume: Float) {
        #if os(macOS)
        guard enabled, let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
        #endif
    }
}

// MARK: - Segmented control

/// A capsule segmented control with a sliding white thumb.
struct GlassSegmented<Value: Hashable>: View {
    var options: [(value: Value, title: String)]
    @Binding var selection: Value
    var counts: [Value: Int] = [:]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                segment(options[i])
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.hover))
    }

    private func segment(_ option: (value: Value, title: String)) -> some View {
        let selected = option.value == selection
        return Button {
            withAnimation(Motion.snappy) { selection = option.value }
        } label: {
            HStack(spacing: 5) {
                Text(option.title)
                if let n = counts[option.value], n > 0 {
                    Text("\(n)")
                        .font(Theme.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
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
                        .shadow(color: Theme.glassShadow, radius: 3, y: 1)
                        .matchedGeometryEffect(id: "thumb", in: ns)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
