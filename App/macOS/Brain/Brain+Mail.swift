import Foundation
import SwiftData
import OrbitCore

extension OrbitBrain {
    /// "graph" (Microsoft Graph), "appleMail" (the Mac's Mail app) or "none".
    var exeterMailSource: String {
        MacPrefs.string(MacPrefs.exeterMailSource)
            ?? (accounts.microsoftConnected ? "graph" : AppleMailReader.canReadMailFolder() ? "appleMail" : "none")
    }

    func mailProviders() -> [MailProvider] {
        var providers: [MailProvider] = []
        if accounts.googleConnected, let google = accounts.google {
            providers.append(GmailClient(tokens: google))
        }
        switch exeterMailSource {
        case "graph":
            if accounts.microsoftConnected, let microsoft = accounts.microsoft {
                providers.append(GraphMailClient(tokens: microsoft))
            }
        case "appleMail":
            providers.append(AppleMailReader())
        default:
            break
        }
        return providers
    }

    func triageEngine() -> TriageEngine {
        let prefs = self.prefs
        let tz = prefs.timeZone
        return TriageEngine(router: router, prefs: prefs, dateFinder: { text in
            DateExtractor(now: Date(), timeZone: tz).extract(from: text).map(\.date)
        })
    }

    func mailSync() -> MailSyncCoordinator {
        if let existing = mailCoordinator { return existing }
        let coordinator = MailSyncCoordinator(providers: [], triage: triageEngine(),
                                              state: local.load(MailSyncState.self, "mail-state.json") ?? MailSyncState())
        mailCoordinator = coordinator
        return coordinator
    }

    // MARK: Sync

    func syncMail() async {
        let providers = mailProviders()
        guard !providers.isEmpty, begin(.gmail) else { return }
        defer { end(.gmail) }
        let coordinator = mailSync()
        await coordinator.setProviders(providers)
        await coordinator.setTriage(triageEngine())
        let report = await coordinator.sync()
        local.save(await coordinator.state, "mail-state.json")

        cache(report.messages)
        await addTicketEvents(from: report.messages)
        let index = context.indexed(StoredEmailDigest.self)
        for digest in report.digests {
            if let existing = index[digest.id] { existing.apply(digest) } else { context.insert(StoredEmailDigest(digest: digest)) }
        }
        context.saveQuietly()

        for n in report.notifications.prefix(5) {
            notify(id: "mail-\(n.id)", title: n.title, body: n.body, category: "mail")
        }

        let ids = providers.map { $0.providerID }
        if ids.contains("gmail") {
            let count = report.digests.filter { $0.account == .gmail }.count
            record(.gmail, error: report.errors["gmail"], detail: "\(count) new")
        }
        if let exeter = ids.first(where: { $0.hasPrefix("exeter") }) {
            let count = report.digests.filter { $0.account == .exeter }.count
            var error = report.errors[exeter]
            if exeter == "exeter-applemail", let e = error, e.localizedCaseInsensitiveContains("full disk") || e.contains("not found") {
                error = "Needs Full Disk Access (Settings → Mac → Open Full Disk Access) and the Exeter account added to Mail."
            }
            record(.exeterMail, error: error, detail: "\(count) new via \(exeter == "exeter-graph" ? "Microsoft" : "Apple Mail")")
        }
        if report.digests.contains(where: { !$0.suggestedTasks.isEmpty || !$0.suggestedEvents.isEmpty }) {
            app?.refreshWidgets()
        }
    }

    // MARK: Ticket emails (FIXR, Eventbrite, Skiddle, Ticketmaster, DICE)

    /// Ticket confirmations go straight on the calendar (Orbit's Google calendar, or
    /// this Mac's), without asking, with a notification. One entry per event.
    func addTicketEvents(from messages: [EmailMessage]) async {
        let parser = TicketEmailParser(timeZone: prefs.timeZone)
        let now = Date()
        var added: [TicketEvent] = []
        for m in messages {
            guard let t = parser.parse(m), t.end > now else { continue }
            guard context.record(StoredPlan.self, id: t.planID) == nil else { continue }
            let plan = StoredPlan(id: t.planID)
            plan.title = t.title
            plan.start = t.start
            plan.end = t.end
            plan.location = t.venue
            plan.sourceRaw = "email"
            plan.quote = t.notes
            plan.confidence = 0.95
            plan.kindLabel = t.provider.label
            plan.status = .accepted
            context.insert(plan)
            added.append(t)
            OrbitLog.log("mail", "ticket email → calendar: \(t.provider.label) \(t.title)")
        }
        guard !added.isEmpty else { return }
        context.saveQuietly()
        await writeAcceptedPlans()
        let cal = DayCalendar(timeZone: prefs.timeZone)
        for t in added {
            let when = "\(cal.format(t.start, "EEE d MMM"))" + (t.hasTime ? " \(cal.time(t.start))" : "")
            notify(id: t.planID, title: "Added \(t.provider.label) event: \(t.title)",
                   body: [when, t.venue].compactMap { $0 }.joined(separator: " · "), category: "plans")
        }
    }

    // MARK: Local message cache (full bodies, Mac only)

    private func loadCache() -> [String: EmailMessage] {
        if let mailCache { return mailCache }
        let list = local.load([EmailMessage].self, "mail-cache.json") ?? []
        let dict = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        mailCache = dict
        return dict
    }

    func cache(_ messages: [EmailMessage]) {
        guard !messages.isEmpty else { return }
        var dict = loadCache()
        for m in messages { dict[m.id] = m }
        let kept = dict.values.sorted { $0.date > $1.date }.prefix(600)
        dict = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        mailCache = dict
        local.save(Array(kept), "mail-cache.json")
    }

    /// The original email for a digest: from the cache, or fetched again.
    func message(for digestID: String) async -> EmailMessage? {
        if let m = loadCache()[digestID] { return m }
        guard let digest = context.record(StoredEmailDigest.self, id: digestID) else { return nil }
        for provider in mailProviders() where provider.account == digest.account {
            if let m = try? await provider.fetchMessage(id: digestID) {
                cache([m])
                return m
            }
        }
        return nil
    }

    // MARK: Drafts (never sent)

    func draftReply(digestID: String) async throws -> String? {
        guard let message = await message(for: digestID) else {
            throw BrainError("Orbit doesn't have the original email any more, so it can't draft a reply.")
        }
        isThinking = true
        defer { isThinking = false }
        let sender = MailAddress(name: message.fromName, address: message.from)
        let tone: ReplyTone = sender.domain.hasSuffix("exeter.ac.uk") ? .formal : .friendly
        let name = firstName.isEmpty ? "Me" : firstName
        let text = try await triageEngine().draftReply(for: message, tone: tone, signOff: name)
        if let digest = context.record(StoredEmailDigest.self, id: digestID) {
            digest.draftReply = text
            digest.draftRequested = false
            context.saveQuietly()
        }
        return text
    }

    func saveDraft(digestID: String, body: String) async throws {
        guard let message = await message(for: digestID) else {
            throw BrainError("Orbit doesn't have the original email any more.")
        }
        let coordinator = mailSync()
        await coordinator.setProviders(mailProviders())
        _ = try await coordinator.saveDraft(replyTo: message, body: body)
        if let digest = context.record(StoredEmailDigest.self, id: digestID) {
            digest.draftReply = body
            digest.draftSavedAt = Date()
            context.saveQuietly()
        }
    }
}
