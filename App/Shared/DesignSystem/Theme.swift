import SwiftUI

/// Orbit Soft: a light, friendly dashboard look. An off-white canvas, big
/// rounded cards in soft pastel fills (sage, blush, butter, lavender, sky,
/// peach), near-black ink for primary actions and selection, and SF Pro
/// Rounded for headings and big numbers. Dark mode is a neutral charcoal with
/// the same pastels muted. See docs/DESIGN.md.
///
/// This file is also compiled into the widget and share extensions, so it
/// only depends on SwiftUI. Glass helpers live in Glass.swift (app only).
enum Theme {
    // MARK: Surfaces

    /// The window canvas: off-white / neutral charcoal.
    static let background = Color.dynamic(light: 0xF3F3F0, dark: 0x161617)
    /// The icon rail and other secondary surfaces.
    static let sidebar = Color.dynamic(light: 0xFFFFFF, dark: 0x1E1E20)
    /// Cards, popovers and anything that floats.
    static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x232325)
    /// Subtle fill: input fields, quote blocks.
    static let surfaceRaised = Color.dynamic(light: 0x111111, lightAlpha: 0.045, dark: 0xFFFFFF, darkAlpha: 0.07)
    /// Row hover fill.
    static let hover = Color.dynamic(light: 0x111111, lightAlpha: 0.05, dark: 0xFFFFFF, darkAlpha: 0.07)
    /// Pressed / active fill.
    static let pressed = Color.dynamic(light: 0x111111, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.12)
    /// Selected row fill (non-rail).
    static let selection = Color.dynamic(light: 0x111111, lightAlpha: 0.07, dark: 0xFFFFFF, darkAlpha: 0.1)
    /// Hairline separators.
    static let border = Color.dynamic(light: 0x111111, lightAlpha: 0.07, dark: 0xFFFFFF, darkAlpha: 0.09)
    static let separator = border
    /// Card edge (very faint).
    static let glassRim = Color.dynamic(light: 0x111111, lightAlpha: 0.04, dark: 0xFFFFFF, darkAlpha: 0.06)
    /// Soft shadow under cards.
    static let glassShadow = Color.dynamic(light: 0x1C1C1A, lightAlpha: 0.06, dark: 0x000000, darkAlpha: 0.35)

    // MARK: Text

    static let textPrimary = Color.dynamic(light: 0x151515, dark: 0xF3F3F0)
    static let textSecondary = Color.dynamic(light: 0x5E5E5A, dark: 0xB4B4AE)
    static let textTertiary = Color.dynamic(light: 0x9A9A94, dark: 0x7B7B76)

    // MARK: Ink and pastels

    /// Primary: near-black ink (near-white in dark mode). Selection, primary buttons.
    static let accent = Color.dynamic(light: 0x151515, dark: 0xF3F3F0)
    /// Text and icons on top of `accent`.
    static let onAccent = Color.dynamic(light: 0xFFFFFF, dark: 0x151515)
    /// Ink alias, for readability at call sites.
    static let ink = accent

    // Pastel card fills (light) and their muted dark twins.
    static let sage = Color.dynamic(light: 0xDCEBD8, dark: 0x2C3A2F)
    static let mint = Color.dynamic(light: 0xD2EEE2, dark: 0x27392F)
    static let blush = Color.dynamic(light: 0xF8DCDA, dark: 0x3E2D2F)
    static let butter = Color.dynamic(light: 0xFAEFC2, dark: 0x3B3624)
    static let lavender = Color.dynamic(light: 0xE3DDF6, dark: 0x312D45)
    static let sky = Color.dynamic(light: 0xD7E6F6, dark: 0x273342)
    static let peach = Color.dynamic(light: 0xFBE2CE, dark: 0x3E3127)

    /// Deeper versions of the pastels, for icons and progress on a pastel card.
    static let sageInk = Color.dynamic(light: 0x4E7A55, dark: 0x9FD1A8)
    static let blushInk = Color.dynamic(light: 0xB65A58, dark: 0xF2A6A2)
    static let butterInk = Color.dynamic(light: 0x9A7B12, dark: 0xF0D57A)
    static let lavenderInk = Color.dynamic(light: 0x6A58B8, dark: 0xC0B2F5)
    static let skyInk = Color.dynamic(light: 0x3F6C9E, dark: 0x9CC3EE)
    static let peachInk = Color.dynamic(light: 0xB0683A, dark: 0xF3B98E)

    /// A pastel by index (0 sage, 1 blush, 2 butter, 3 lavender, 4 sky, 5 peach).
    static let pastels: [Color] = [sage, blush, butter, lavender, sky, peach]
    static let pastelInks: [Color] = [sageInk, blushInk, butterInk, lavenderInk, skyInk, peachInk]
    static func pastel(_ i: Int) -> Color { pastels[abs(i) % pastels.count] }
    static func pastelInk(_ i: Int) -> Color { pastelInks[abs(i) % pastelInks.count] }

    // MARK: Meaning (softened)

    static let indigo = Color.dynamic(light: 0x5B6FD6, dark: 0x93A2F0)
    static let violet = Color.dynamic(light: 0x8E78D8, dark: 0xB8A8F2)
    static let pink = Color.dynamic(light: 0xE27A9C, dark: 0xF2A5BF)
    static let cyan = Color.dynamic(light: 0x3E9FB5, dark: 0x8ED3E2)
    static let success = Color.dynamic(light: 0x3F9A64, dark: 0x8BD6A6)
    static let warning = Color.dynamic(light: 0xD48A1E, dark: 0xF2C074)
    /// Overdue and destructive.
    static let danger = Color.dynamic(light: 0xD9534F, dark: 0xF28E8A)
    /// The calendar "now" line.
    static let now = Color.dynamic(light: 0xE0566B, dark: 0xF28A9A)
    /// Routine blocks (meals, reading, shutdown): soft and neutral.
    static let routine = Color.dynamic(light: 0xA3A39B, dark: 0x8C8C86)

    /// Kept for older call sites: a gentle pastel sweep (no more purple glow).
    static let accentGradient = LinearGradient(colors: [accent, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Friendly pastel sweep for heroes and the app icon mood.
    static let pastelGradient = LinearGradient(colors: [Color(hex: 0xDCEBD8), Color(hex: 0xE3DDF6), Color(hex: 0xF8DCDA)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Rings (pastel-tuned)

    static let ringStudy = Color.dynamic(light: 0xE8849A, dark: 0xF2A1B3)
    static let ringStudyEnd = Color.dynamic(light: 0xF2A9B8, dark: 0xF8C2CE)
    static let ringTasks = Color.dynamic(light: 0x6FB47E, dark: 0x9BD6A8)
    static let ringTasksEnd = Color.dynamic(light: 0xA3D5A9, dark: 0xC0E6C6)
    static let ringReviews = Color.dynamic(light: 0x8C7FD9, dark: 0xB5AAF0)
    static let ringReviewsEnd = Color.dynamic(light: 0xB9AFEE, dark: 0xD2CAF7)
    static let flame = LinearGradient(colors: [Color(hex: 0xFFC247), Color(hex: 0xFF7A45)], startPoint: .top, endPoint: .bottom)

    // MARK: Module colours (pastel-deep, readable as text)

    /// Light / dark pairs: rose, peach, butter, sage, teal, sky, lavender, pink.
    static let modulePalette: [(light: UInt32, dark: UInt32)] = [
        (0xD06A78, 0xF2A1AC), (0xCF8248, 0xF3B98E), (0xB39122, 0xF0D57A), (0x4F9A63, 0x9FD1A8),
        (0x3E9AA6, 0x8ED3DC), (0x4F7FC0, 0x9CC3EE), (0x7E6AC9, 0xC0B2F5), (0xC4679A, 0xF0A8CC),
    ]

    private static let moduleColors: [Color] = modulePalette.map { Color.dynamic(light: $0.light, dark: $0.dark) }

    /// Neutral colour for things without a module.
    static let neutralModule = Color.dynamic(light: 0x8E8E88, dark: 0x8A8A84)

    /// Stable colour for a module code (same code → same colour on every device).
    static func moduleColor(_ code: String?) -> Color {
        guard let code, !code.isEmpty else { return neutralModule }
        let hash = code.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return moduleColors[Int(hash % UInt32(moduleColors.count))]
    }

    /// A palette colour by index (0 rose, 1 peach, 2 butter, 3 sage, 4 teal, 5 sky, 6 lavender, 7 pink).
    static func paletteColor(_ index: Int) -> Color { moduleColors[abs(index) % moduleColors.count] }

    /// Tint used behind calendar blocks and chips.
    static func tint(_ color: Color) -> Color { color.opacity(0.18) }

    // MARK: Type (SF Pro Rounded for headings and numbers)

    enum Size {
        static let caption: CGFloat = 11
        static let body: CGFloat = 13
        static let large: CGFloat = 15
        static let title3: CGFloat = 17
        static let title2: CGFloat = 22
        static let title: CGFloat = 30
        static let display: CGFloat = 40
    }

    /// Snaps any requested size onto the scale.
    static func scaled(_ size: CGFloat) -> CGFloat {
        let scale: [CGFloat] = [11, 13, 15, 17, 22, 26, 30, 34, 40, 56]
        return scale.min { abs($0 - size) < abs($1 - size) } ?? 13
    }

    /// Page and hero titles: rounded and bold.
    static func title(_ size: CGFloat = Size.title) -> Font { .system(size: scaled(size), weight: .bold, design: .rounded) }

    /// Big numbers: SF Pro Rounded, bold, tabular.
    static func number(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    #if os(iOS)
    static let body = Font.system(size: Size.title3)
    static let callout = Font.system(size: Size.large)
    static let headline = Font.system(size: Size.title3, weight: .semibold, design: .rounded)
    static let caption = Font.system(size: Size.body)
    static let large = Font.system(size: Size.title3)
    #else
    static let body = Font.system(size: Size.body)
    static let callout = Font.system(size: Size.body)
    static let headline = Font.system(size: Size.body, weight: .semibold, design: .rounded)
    static let caption = Font.system(size: Size.caption)
    static let large = Font.system(size: Size.large)
    #endif
    static let pageTitle = Font.system(size: Size.title, weight: .bold, design: .rounded)
    static let displayTitle = Font.system(size: Size.display, weight: .bold, design: .rounded)
    static let sectionTitle = Font.system(size: Size.title3, weight: .bold, design: .rounded)
    /// Card titles on the dashboard.
    static let cardTitle = Font.system(size: Size.large, weight: .semibold, design: .rounded)
    static let mono = Font.system(size: Size.caption).monospacedDigit()

    // MARK: Spacing (4 / 8 pt grid) and shape

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    enum Radius {
        /// Chips, checkboxes, calendar blocks.
        static let xs: CGFloat = 8
        /// Rows, buttons, fields.
        static let s: CGFloat = 12
        /// Popovers, small cards.
        static let m: CGFloat = 18
        /// Sheets, the command palette.
        static let l: CGFloat = 22
        /// Cards.
        static let card: CGFloat = 28
        /// Hero panels, onboarding.
        static let xl: CGFloat = 32
    }

    static let padding: CGFloat = Space.l
    static let gap: CGFloat = Space.m
    static let radius: CGFloat = Radius.m
    static let smallRadius: CGFloat = Radius.s
    /// Reading width for page-like screens.
    static let readingWidth: CGFloat = 860
    static let hairline: CGFloat = 0.5

    /// Default animation (kept for older call sites).
    static let spring = Motion.snappy
}

/// Springy but controlled motion.
enum Motion {
    /// Selection, toggles.
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.8)
    /// Layout changes, list insert and remove.
    static let smooth = Animation.spring(response: 0.38, dampingFraction: 0.86)
    /// Bouncy moments: the checkbox, rings closing, the add confirmation.
    static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.58)
    /// Hover and opacity.
    static let fade = Animation.easeOut(duration: 0.16)
    /// Most other things.
    static let quick = Animation.easeOut(duration: 0.2)
    /// Cards arriving on screen.
    static let arrive = Animation.spring(response: 0.5, dampingFraction: 0.85)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }

    /// A colour with separate light and dark values (each with an optional alpha).
    static func dynamic(light: UInt32, lightAlpha: Double = 1, dark: UInt32, darkAlpha: Double = 1) -> Color {
        #if os(macOS)
        return Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(Color(hex: dark, opacity: darkAlpha))
                : NSColor(Color(hex: light, opacity: lightAlpha))
        })
        #else
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(Color(hex: dark, opacity: darkAlpha))
                : UIColor(Color(hex: light, opacity: lightAlpha))
        })
        #endif
    }
}
