import Foundation
import OrbitCore

/// Imports chats and finds plans in them. Runs the same on both devices; the
/// AI stage is used when this device has one (`backend.planRouter`), otherwise
/// the rule stage alone runs.
extension AppModel {
    private var myNames: Set<String> {
        var names: Set<String> = ["Me", "me", "You", "you"]
        if !firstName.isEmpty { names.insert(firstName) }
        return names
    }

    private var extractor: PlanExtractor {
        PlanExtractor(router: backend.planRouter, purpose: .privateData, timeZone: prefs.timeZone)
    }

    /// A WhatsApp "Export chat" file (.txt or .zip).
    func importWhatsApp(url: URL) async throws -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let messages = try WhatsAppExportParser(myNames: myNames, timeZone: prefs.timeZone).parse(fileAt: url)
        let plans = await extractor.extract(from: messages)
        return ingest(plans: plans, source: "whatsapp")
    }

    /// An unzipped Instagram "Download your information" folder.
    func importInstagram(folder: URL) async throws -> Int {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let threads = try InstagramExportParser(myNames: myNames).parse(exportFolder: folder)
        let plans = await extractor.extract(from: threads.flatMap(\.messages))
        return ingest(plans: plans, source: "instagram")
    }

    /// Pasted or shared text.
    func importText(_ text: String) async -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let plans = await extractor.extract(fromSharedText: trimmed, myNames: myNames)
        return ingest(plans: plans, source: "shared")
    }

    /// A chat screenshot: read on-device with Apple Vision, then extract.
    func importScreenshot(_ image: Data) async throws -> Int {
        #if canImport(Vision)
        let plans = try await extractor.extract(fromScreenshot: image, ocr: AppleVisionOCR(), takenAt: Date())
        return ingest(plans: plans, source: "screenshot")
        #else
        return 0
        #endif
    }
}
