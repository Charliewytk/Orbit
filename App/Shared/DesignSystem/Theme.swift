import SwiftUI

/// Orbit's look: calm, soft and native. Warm neutral backgrounds, one accent
/// colour per module, rounded type, generous spacing, glassy cards.
enum Theme {
    // MARK: Colours (adapt to light/dark automatically)

    static let background = Color.dynamic(light: 0xF6F4F0, dark: 0x111113)
    static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x1C1C1F)
    static let surfaceRaised = Color.dynamic(light: 0xFBFAF8, dark: 0x242428)
    static let border = Color.dynamic(light: 0xE8E4DD, dark: 0x2E2E33)
    static let textPrimary = Color.dynamic(light: 0x1D1B18, dark: 0xF2F0EC)
    static let textSecondary = Color.dynamic(light: 0x6E6A63, dark: 0x9C9993)
    static let textTertiary = Color.dynamic(light: 0xA29D95, dark: 0x6B6964)

    /// Orbit's own accent: a soft indigo.
    static let accent = Color.dynamic(light: 0x5B5BD6, dark: 0x8B8BF0)
    static let success = Color.dynamic(light: 0x3E9B6E, dark: 0x5CC08F)
    static let warning = Color.dynamic(light: 0xD9822B, dark: 0xF0A45A)
    static let danger = Color.dynamic(light: 0xD14D4D, dark: 0xF07A7A)

    /// Module colours: muted, distinct, readable in both modes.
    static let modulePalette: [UInt32] = [
        0x6C8EEF, 0xE58A6B, 0x58B39B, 0xB37FD9, 0xE0B04F, 0x5FB2D6, 0xD9759E, 0x8EA65B,
    ]

    /// Stable colour for a module code (same code → same colour on every device).
    static func moduleColor(_ code: String?) -> Color {
        guard let code, !code.isEmpty else { return accent }
        let hash = code.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Color(hex: modulePalette[Int(hash % UInt32(modulePalette.count))])
    }

    // MARK: Type

    static func title(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static let headline = Font.system(.headline, design: .rounded)
    static let body = Font.system(.body, design: .default)
    static let callout = Font.system(.callout, design: .default)
    static let caption = Font.system(.caption, design: .rounded).weight(.medium)
    static let mono = Font.system(.caption, design: .monospaced)

    // MARK: Spacing & shape

    static let padding: CGFloat = 16
    static let gap: CGFloat = 12
    static let radius: CGFloat = 18
    static let smallRadius: CGFloat = 10

    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
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

    /// A colour with separate light and dark values.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if os(macOS)
        return Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(Color(hex: dark)) : NSColor(Color(hex: light))
        })
        #else
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light))
        })
        #endif
    }
}
