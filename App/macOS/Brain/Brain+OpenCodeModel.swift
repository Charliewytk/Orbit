import Foundation
import OrbitCore

/// Picks the OpenCode model and reasoning variant: the Settings choice, or automatically
/// "Muse Spark 1.3" at "xhigh" when OpenCode offers it (matched loosely on name/id).
extension OrbitBrain {
    static let resolvedVariantKey = "openCodeResolvedVariant"

    /// Asks OpenCode for its models and remembers the automatic choice.
    func resolveOpenCodeModel() async {
        guard let options = try? await launcher.provider(model: nil).modelOptions(), !options.isEmpty else { return }
        let saved = MacPrefs.string(MacPrefs.openCodeModel)
        let ref = OpenCodeModelResolver.resolve(saved: saved, options: options)
        if saved == nil { MacPrefs.defaults.set(ref?.string ?? "", forKey: MacPrefs.openCodeResolvedModel) }
        let option = options.first { $0.ref == ref }
        let variant = OpenCodeModelResolver.variant(saved: MacPrefs.string(MacPrefs.openCodeVariant), option: option)
        MacPrefs.defaults.set(variant ?? "none", forKey: Self.resolvedVariantKey)
    }

    /// The variant to send (nil = model default).
    func openCodeVariant() -> String? {
        let v = MacPrefs.string(Self.resolvedVariantKey) ?? MacPrefs.string(MacPrefs.openCodeVariant) ?? OpenCodeModelResolver.preferredVariant
        return v == "none" ? nil : v
    }
}
