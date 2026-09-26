import SwiftUI

/// Orbit's look: quiet, typographic and native, in the spirit of Notion and
/// Notion Calendar. Mostly neutrals, one restrained blue accent, module
/// colours only as small dots and thin edges. See docs/DESIGN.md §0.
///
/// This file is also compiled into the widget and share extensions, so it
/// only depends on SwiftUI.
enum Theme {
    // MARK: Neutrals

    /// Main content background (soft white / soft black, never pure).
    static let background = Color.dynamic(light: 0xFFFFFF, dark: 0x191919)
    /// Sidebar-like secondary surfaces (Notion's off-white).
    static let sidebar = Color.dynamic(light: 0xF7F7F5, dark: 0x202020)
    /// Popovers and anything that floats.
    static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x252525)
    /// Subtle fill: input fields, the user's chat messages, quote blocks.
    static let surfaceRaised = Color.dynamic(light: 0xF7F7F5, dark: 0x2A2A2A)
    /// Row hover fill.
    static let hover = Color.dynamic(light: 0x37352F, lightAlpha: 0.05, dark: 0xFFFFFF, darkAlpha: 0.055)
    /// Pressed / active fill.
    static let pressed = Color.dynamic(light: 0x37352F, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.09)
    /// Selected row fill (non-sidebar).
    static let selection = Color.dynamic(light: 0x2383E2, lightAlpha: 0.12, dark: 0x529CCA, darkAlpha: 0.22)
    /// Hairline separators and the rare stroke.
    static let border = Color.dynamic(light: 0x37352F, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.09)
    static let separator = border

    // MARK: Text

    static let textPrimary = Color.dynamic(light: 0x37352F, dark: 0xFFFFFF, darkAlpha: 0.81)
    static let textSecondary = Color.dynamic(light: 0x787774, dark: 0x9B9A97)
    static let textTertiary = Color.dynamic(light: 0xA5A4A0, dark: 0x6F6E6B)

    // MARK: Meaning

    /// The one accent: selection, links, primary actions.
    static let accent = Color.dynamic(light: 0x2383E2, dark: 0x529CCA)
    static let success = Color.dynamic(light: 0x0F7B6C, dark: 0x4DAB9A)
    static let warning = Color.dynamic(light: 0xD9730D, dark: 0xFFA344)
    /// Overdue and destructive.
    static let danger = Color.dynamic(light: 0xE03E3E, dark: 0xFF7369)
    /// The calendar "now" line.
    static let now = Color.dynamic(light: 0xE03E3E, dark: 0xEB5757)

    // MARK: Module colours (Notion's muted tones)

    /// Light / dark pairs: red, orange, yellow, green, blue, purple, pink, brown.
    static let modulePalette: [(light: UInt32, dark: UInt32)] = [
        (0xE03E3E, 0xFF7369), (0xD9730D, 0xFFA344), (0xDFAB01, 0xFFDC49), (0x0F7B6C, 0x4DAB9A),
        (0x0B6E99, 0x529CCA), (0x6940A5, 0x9A6DD7), (0xAD1A72, 0xE255A1), (0x64473A, 0x937264),
    ]

    private static let moduleColors: [Color] = modulePalette.map { Color.dynamic(light: $0.light, dark: $0.dark) }

    /// Neutral colour for things without a module.
    static let neutralModule = Color.dynamic(light: 0x9B9A97, dark: 0x7F7E7B)

    /// Stable colour for a module code (same code → same colour on every device).
    static func moduleColor(_ code: String?) -> Color {
        guard let code, !code.isEmpty else { return neutralModule }
        let hash = code.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return moduleColors[Int(hash % UInt32(moduleColors.count))]
    }

    /// A palette colour by index (0 red, 1 orange, 2 yellow, 3 green, 4 blue, 5 purple, 6 pink, 7 brown).
    static func paletteColor(_ index: Int) -> Color { moduleColors[abs(index) % moduleColors.count] }

    /// Flat tint used behind calendar blocks.
    static func tint(_ color: Color) -> Color { color.opacity(0.14) }

    // MARK: Type (system font only; sizes 11 / 13 / 15 / 17 / 22 / 26)

    enum Size {
        static let caption: CGFloat = 11
        static let body: CGFloat = 13
        static let large: CGFloat = 15
        static let title3: CGFloat = 17
        static let title2: CGFloat = 22
        static let title: CGFloat = 26
    }

    /// Snaps any requested size onto the scale.
    static func scaled(_ size: CGFloat) -> CGFloat {
        let scale: [CGFloat] = [11, 13, 15, 17, 22, 26]
        return scale.min { abs($0 - size) < abs($1 - size) } ?? 13
    }

    /// Page and hero titles (bold, Notion-like).
    static func title(_ size: CGFloat = Size.title) -> Font { .system(size: scaled(size), weight: .bold) }

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
    static let sectionTitle = Font.system(size: Size.title3, weight: .semibold)
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
        static let xs: CGFloat = 4
        /// Rows, buttons, fields.
        static let s: CGFloat = 6
        /// Popovers, the rare card.
        static let m: CGFloat = 8
        /// Sheets, the command palette.
        static let l: CGFloat = 12
    }

    static let padding: CGFloat = Space.l
    static let gap: CGFloat = Space.m
    static let radius: CGFloat = Radius.m
    static let smallRadius: CGFloat = Radius.s
    /// Reading width for page-like screens.
    static let readingWidth: CGFloat = 760
    static let hairline: CGFloat = 0.5

    /// Default animation (kept for older call sites).
    static let spring = Motion.snappy
}

/// Short, non-bouncy motion.
enum Motion {
    /// Selection, toggles, the checkbox.
    static let snappy = Animation.spring(response: 0.25, dampingFraction: 0.86)
    /// Layout changes, list insert and remove.
    static let smooth = Animation.spring(response: 0.3, dampingFraction: 0.9)
    /// Hover and opacity.
    static let fade = Animation.easeOut(duration: 0.15)
    /// Most other things.
    static let quick = Animation.easeOut(duration: 0.18)
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
