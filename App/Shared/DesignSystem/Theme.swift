import SwiftUI

/// Orbit Glass: macOS 26 "Liquid Glass" look. Translucent glass cards over a
/// slowly moving, time-of-day ambient backdrop; an indigo → violet → pink accent;
/// vivid module colours; SF Pro Rounded for big numbers. See docs/DESIGN.md.
///
/// This file is also compiled into the widget and share extensions, so it
/// only depends on SwiftUI. Glass helpers live in Glass.swift (app only).
enum Theme {
    // MARK: Surfaces

    /// Base window colour (under the ambient backdrop; widgets use it directly).
    static let background = Color.dynamic(light: 0xF3F2FA, dark: 0x0D0C15)
    /// Sidebar-like secondary surfaces.
    static let sidebar = Color.dynamic(light: 0xEDEBF7, dark: 0x14131E)
    /// Popovers and anything that floats (used where glass isn't available).
    static let surface = Color.dynamic(light: 0xFFFFFF, lightAlpha: 0.86, dark: 0x1D1B2A, darkAlpha: 0.86)
    /// Subtle fill: input fields, quote blocks.
    static let surfaceRaised = Color.dynamic(light: 0x1B1740, lightAlpha: 0.05, dark: 0xFFFFFF, darkAlpha: 0.07)
    /// Row hover fill.
    static let hover = Color.dynamic(light: 0x1B1740, lightAlpha: 0.055, dark: 0xFFFFFF, darkAlpha: 0.07)
    /// Pressed / active fill.
    static let pressed = Color.dynamic(light: 0x1B1740, lightAlpha: 0.1, dark: 0xFFFFFF, darkAlpha: 0.12)
    /// Selected row fill (non-sidebar).
    static let selection = Color.dynamic(light: 0x6246EA, lightAlpha: 0.14, dark: 0x8B7BFF, darkAlpha: 0.24)
    /// Hairline separators.
    static let border = Color.dynamic(light: 0x1B1740, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.1)
    static let separator = border
    /// The bright rim on glass (top-left light).
    static let glassRim = Color.dynamic(light: 0xFFFFFF, lightAlpha: 0.75, dark: 0xFFFFFF, darkAlpha: 0.16)
    /// Soft shadow under floating glass.
    static let glassShadow = Color.dynamic(light: 0x2A1F6B, lightAlpha: 0.12, dark: 0x000000, darkAlpha: 0.45)

    // MARK: Text

    static let textPrimary = Color.dynamic(light: 0x15122A, dark: 0xFFFFFF, darkAlpha: 0.95)
    static let textSecondary = Color.dynamic(light: 0x57536E, dark: 0xBDB9D2)
    static let textTertiary = Color.dynamic(light: 0x928EA8, dark: 0x7D7995)

    // MARK: Accent and meaning

    /// Primary accent: selection, links, primary actions.
    static let accent = Color.dynamic(light: 0x6246EA, dark: 0x9B8CFF)
    /// Secondary accents for gradients.
    static let indigo = Color.dynamic(light: 0x4F6BFF, dark: 0x7389FF)
    static let violet = Color.dynamic(light: 0x8B5CF6, dark: 0xA78BFA)
    static let pink = Color.dynamic(light: 0xEC4899, dark: 0xFF6FB5)
    static let cyan = Color.dynamic(light: 0x06B6D4, dark: 0x3FDCF2)
    static let success = Color.dynamic(light: 0x10A874, dark: 0x3BDDA0)
    static let warning = Color.dynamic(light: 0xF08C00, dark: 0xFFB547)
    /// Overdue and destructive.
    static let danger = Color.dynamic(light: 0xEF3B5D, dark: 0xFF6B81)
    /// The calendar "now" line.
    static let now = Color.dynamic(light: 0xFF2D55, dark: 0xFF4F70)
    /// Routine blocks (meals, reading, shutdown): soft and neutral, never competing with study.
    static let routine = Color.dynamic(light: 0x9A93AD, dark: 0xA8A2BE)

    /// The signature gradient (indigo → violet → pink).
    static let accentGradient = LinearGradient(colors: [indigo, violet, pink], startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Rings (Fitness-style)

    static let ringStudy = Color.dynamic(light: 0xFA114F, dark: 0xFF2D6A)
    static let ringStudyEnd = Color.dynamic(light: 0xFF5E9C, dark: 0xFF7AAE)
    static let ringTasks = Color.dynamic(light: 0x5BC21E, dark: 0x9BF03A)
    static let ringTasksEnd = Color.dynamic(light: 0xB6F03D, dark: 0xD4FF63)
    static let ringReviews = Color.dynamic(light: 0x00A9D6, dark: 0x1EEAEF)
    static let ringReviewsEnd = Color.dynamic(light: 0x5CE1F5, dark: 0x8BFBFF)
    static let flame = LinearGradient(colors: [Color(hex: 0xFFB200), Color(hex: 0xFF4D2E)], startPoint: .top, endPoint: .bottom)

    // MARK: Module colours (vivid)

    /// Light / dark pairs: red, orange, yellow, green, cyan, blue, violet, pink.
    static let modulePalette: [(light: UInt32, dark: UInt32)] = [
        (0xF03E5E, 0xFF6B84), (0xF76B15, 0xFF9A52), (0xE0A800, 0xFFD23F), (0x10A874, 0x3BDDA0),
        (0x0AA5C2, 0x3FDCF2), (0x3B6DF6, 0x6F95FF), (0x8B5CF6, 0xB195FF), (0xE0409A, 0xFF73BD),
    ]

    private static let moduleColors: [Color] = modulePalette.map { Color.dynamic(light: $0.light, dark: $0.dark) }

    /// Neutral colour for things without a module.
    static let neutralModule = Color.dynamic(light: 0x8E8AA3, dark: 0x8A86A0)

    /// Stable colour for a module code (same code → same colour on every device).
    static func moduleColor(_ code: String?) -> Color {
        guard let code, !code.isEmpty else { return neutralModule }
        let hash = code.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return moduleColors[Int(hash % UInt32(moduleColors.count))]
    }

    /// A palette colour by index (0 red, 1 orange, 2 yellow, 3 green, 4 cyan, 5 blue, 6 violet, 7 pink).
    static func paletteColor(_ index: Int) -> Color { moduleColors[abs(index) % moduleColors.count] }

    /// Tint used behind calendar blocks and chips.
    static func tint(_ color: Color) -> Color { color.opacity(0.18) }

    // MARK: Type (system font; SF Pro Rounded for numbers)

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

    /// Page and hero titles (bold).
    static func title(_ size: CGFloat = Size.title) -> Font { .system(size: scaled(size), weight: .bold) }

    /// Big numbers: SF Pro Rounded, bold, tabular.
    static func number(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    #if os(iOS)
    static let body = Font.system(size: Size.title3)
    static let callout = Font.system(size: Size.large)
    static let headline = Font.system(size: Size.title3, weight: .semibold)
    static let caption = Font.system(size: Size.body)
    static let large = Font.system(size: Size.title3)
    #else
    static let body = Font.system(size: Size.body)
    static let callout = Font.system(size: Size.body)
    static let headline = Font.system(size: Size.body, weight: .semibold)
    static let caption = Font.system(size: Size.caption)
    static let large = Font.system(size: Size.large)
    #endif
    static let pageTitle = Font.system(size: Size.title, weight: .bold)
    static let displayTitle = Font.system(size: Size.display, weight: .bold)
    static let sectionTitle = Font.system(size: Size.title3, weight: .bold)
    /// Card titles on the dashboard ("Today", "Deadlines").
    static let cardTitle = Font.system(size: Size.body, weight: .semibold)
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
        static let xs: CGFloat = 6
        /// Rows, buttons, fields.
        static let s: CGFloat = 10
        /// Popovers, small cards.
        static let m: CGFloat = 14
        /// Sheets, the command palette.
        static let l: CGFloat = 18
        /// Glass cards.
        static let card: CGFloat = 24
        /// Hero panels, onboarding.
        static let xl: CGFloat = 28
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
    static let arrive = Animation.spring(response: 0.55, dampingFraction: 0.82)
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
