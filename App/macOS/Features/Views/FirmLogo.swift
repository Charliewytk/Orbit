import AppKit
import SwiftUI
import OrbitCore

/// Firm logos for Careers: the favicon from Google's favicon service for the
/// firm's domain (FirmDomains in OrbitCore), cached in memory and on disk
/// (~/Library/Caches/Orbit/Logos). Falls back to a coloured monogram.
@MainActor
final class LogoCache {
    static let shared = LogoCache()

    private var memory: [String: NSImage] = [:]
    /// Domains with no real logo (so we don't ask again this launch).
    private var missing: Set<String> = []
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let directory: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Orbit/Logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cached(_ domain: String) -> NSImage? { memory[domain] }

    func image(for domain: String) async -> NSImage? {
        if let hit = memory[domain] { return hit }
        if missing.contains(domain) { return nil }
        if let task = inFlight[domain] { return await task.value }
        let file = directory.appendingPathComponent(domain.replacingOccurrences(of: "/", with: "_") + ".png")
        let task = Task<NSImage?, Never> { @MainActor in
            if let data = try? Data(contentsOf: file), let img = NSImage(data: data) { return img }
            guard let url = URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=128") else { return nil }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: data) else { return nil }
                // The service answers unknown domains with a tiny generic globe: treat that as "no logo".
                let px = img.representations.map(\.pixelsWide).max() ?? Int(img.size.width)
                guard px >= 32 else { return nil }
                try? data.write(to: file, options: .atomic)
                return img
            } catch {
                return nil
            }
        }
        inFlight[domain] = task
        let result = await task.value
        inFlight[domain] = nil
        if let result { memory[domain] = result } else { missing.insert(domain) }
        return result
    }
}

/// A firm's logo in a rounded tile, or its monogram.
struct FirmLogo: View {
    var company: String
    var size: CGFloat = 28
    @State private var image: NSImage?

    private var domain: String { FirmDomains.domain(for: company) }

    var body: some View {
        ZStack {
            if let image {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(.white)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.14)
            } else {
                let hue = FirmDomains.hue(for: company)
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.9),
                                                  Color(hue: hue, saturation: 0.75, brightness: 0.7)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(FirmDomains.monogram(company))
                    .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .strokeBorder(Theme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .task(id: company) {
            image = LogoCache.shared.cached(domain)
            if image == nil { image = await LogoCache.shared.image(for: domain) }
        }
        .accessibilityLabel(company)
    }
}
