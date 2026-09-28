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
        let result = await extractor.analyze(messages)
        ingest(ticketDrops: result.ticketDrops, source: "whatsapp")
        return ingest(plans: result.plans, source: "whatsapp")
    }

    /// An unzipped Instagram "Download your information" folder.
    func importInstagram(folder: URL) async throws -> Int {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let threads = try InstagramExportParser(myNames: myNames).parse(exportFolder: folder)
        let result = await extractor.analyze(threads.flatMap(\.messages))
        ingest(ticketDrops: result.ticketDrops, source: "instagram")
        return ingest(plans: result.plans, source: "instagram")
    }

    /// Pasted or shared text.
    func importText(_ text: String) async -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let result = await extractor.analyze(sharedText: trimmed, myNames: myNames)
        let drops = ingest(ticketDrops: result.ticketDrops, source: "shared")
        if drops > 0, result.plans.isEmpty { show("That's a ticket drop, not a plan: it's under Tickets on sale") }
        return ingest(plans: result.plans, source: "shared")
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
