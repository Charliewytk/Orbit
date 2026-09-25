import Foundation

/// Persistable sync progress: one cursor per provider plus recently seen message IDs.
public struct MailSyncState: Codable, Hashable, Sendable {
    /// Provider ID → cursor (Gmail history ID, Graph delta link, Apple Mail timestamp).
    public var cursors: [String: String]
    /// "account:id" keys of recently processed mail, newest last. Bounded by `maxSeen`.
    public var seenKeys: [String]
    public var lastSync: [String: Date]
    public var maxSeen: Int

    public init(cursors: [String: String] = [:], seenKeys: [String] = [], lastSync: [String: Date] = [:],
                maxSeen: Int = 5000) {
        self.cursors = cursors; self.seenKeys = seenKeys; self.lastSync = lastSync; self.maxSeen = maxSeen
    }
}

/// A notification to show for an important email.
public struct MailNotification: Codable, Hashable, Sendable, Identifiable {
    /// Same as the digest ID.
    public var id: String
    public var account: MailAccount
    public var title: String
    public var body: String
    public var importance: Double

    public init(id: String, account: MailAccount, title: String, body: String, importance: Double) {
        self.id = id; self.account = account; self.title = title; self.body = body; self.importance = importance
    }

    public init(digest d: EmailDigest) {
        self.init(id: d.id, account: d.account, title: "\(d.category.emoji) \(d.from)",
                  body: d.summary.isEmpty ? d.subject : "\(d.subject): \(d.summary)", importance: d.importance)
    }
}

/// The result of one sync pass.
public struct MailSyncReport: Sendable {
    /// Newly seen messages (full bodies: keep these on the Mac only).
    public var messages: [EmailMessage] = []
    /// Triage results for `messages`, most important first.
    public var digests: [EmailDigest] = []
    public var notifications: [MailNotification] = []
    /// Provider ID → error, for accounts that failed this time. Other accounts still sync.
    public var errors: [String: String] = [:]
}

/// Syncs every mail account, triages new mail and decides what to notify about.
///
/// Persist `state` after each sync (e.g. as JSON) and pass it back in on launch.
public actor MailSyncCoordinator {
    public private(set) var state: MailSyncState
    public var triage: TriageEngine
    /// Notify about mail found on an account's very first sync (usually two weeks of backlog).
    public var notifyOnFirstSync: Bool
    private var providers: [MailProvider]
    private var seen: Set<String>
    private var inFlight: Task<MailSyncReport, Never>?

    public init(providers: [MailProvider], triage: TriageEngine, state: MailSyncState = MailSyncState(),
                notifyOnFirstSync: Bool = false) {
        self.providers = providers; self.triage = triage; self.state = state
        self.notifyOnFirstSync = notifyOnFirstSync; self.seen = Set(state.seenKeys)
    }

    public func setProviders(_ p: [MailProvider]) { providers = p }
    public func setTriage(_ t: TriageEngine) { triage = t }
    /// Forget a provider's cursor so its next sync starts fresh.
    public func resetCursor(for providerID: String) { state.cursors[providerID] = nil }

    /// Fetches new mail from every provider, skips anything already seen, and triages the rest.
    /// Calls made while a sync is running wait for it and get the same report.
    public func sync() async -> MailSyncReport {
        if let running = inFlight { return await running.value }
        let task = Task { await self.runSync() }
        inFlight = task
        let report = await task.value
        inFlight = nil
        return report
    }

    private func runSync() async -> MailSyncReport {
        var report = MailSyncReport()
        var batch = Set<String>()
        var quiet = Set<String>()  // keys whose notifications are suppressed (first-sync backlog)
        for provider in providers {
            let pid = provider.providerID
            let firstSync = state.cursors[pid] == nil
            do {
                let (messages, cursor) = try await provider.fetchNew(since: state.cursors[pid])
                for m in messages {
                    let key = Self.key(m)
                    guard !seen.contains(key), batch.insert(key).inserted else { continue }
                    report.messages.append(m)
                    if firstSync && !notifyOnFirstSync { quiet.insert(key) }
                }
                if let cursor { state.cursors[pid] = cursor }
                state.lastSync[pid] = Date()
            } catch {
                report.errors[pid] = "\(error)"
            }
        }

        let digests = await triage.triage(report.messages)
        report.digests = digests.sorted { $0.importance > $1.importance }
        report.notifications = report.digests
            .filter { $0.notify && !quiet.contains("\($0.account.rawValue):\($0.id)") }
            .map(MailNotification.init(digest:))
        markSeen(report.messages.map(Self.key))
        return report
    }

    /// Saves a reply draft in the right account. Never sends.
    public func saveDraft(replyTo message: EmailMessage, body: String) async throws -> String {
        guard let provider = providers.first(where: { $0.account == message.account }) else {
            throw MailError.unsupported("No \(message.account.rawValue) account connected; drafts")
        }
        return try await provider.createDraft(replyTo: message, body: body)
    }

    public func hasSeen(_ message: EmailMessage) -> Bool { seen.contains(Self.key(message)) }

    private func markSeen(_ keys: [String]) {
        for k in keys where seen.insert(k).inserted { state.seenKeys.append(k) }
        let overflow = state.seenKeys.count - state.maxSeen
        if overflow > 0 {
            state.seenKeys.prefix(overflow).forEach { seen.remove($0) }
            state.seenKeys.removeFirst(overflow)
        }
    }

    static func key(_ m: EmailMessage) -> String { "\(m.account.rawValue):\(m.id)" }
}
