import AppKit
import Foundation
import Observation
import SwiftData
import OrbitCore

/// Ed Discussion (edstem.org, US region by default; see EdWeb.region). Polls the student's courses every 30 minutes
/// while the Mac is awake, notifies about important posts (staff, pinned,
/// announcements, deadline/exam/room-change words, replies to their threads),
/// adds deadline mentions as to-dos, and feeds posts into the ELE activity feed
/// and the course knowledge base so "Ask Orbit" can answer "what's new on Ed?".
@MainActor
@Observable
final class EdService {
    @ObservationIgnored weak var hub: FeatureHub?

    private(set) var state = EdState()
    private(set) var connected = false
    private(set) var needsSignIn = false
    private(set) var syncing = false
    private(set) var signingIn = false
    private(set) var lastError: String?

    private let fileName = "ed-state.json"
    @ObservationIgnored private var loginController: EdLoginWindowController?
    @ObservationIgnored private var harvester: EdTokenHarvester?

    static let interval: TimeInterval = 30 * 60
    static let summariesKey = "features.ed.localSummaries"

    /// Stored in the Keychain (never logged, never synced).
    struct Secret: Codable {
        var token: String
        var kind: EdClient.TokenKind
    }

    // MARK: Persistence

    func load() {
        if let saved = hub?.files.load(EdState.self, fileName) { state = saved }
        connected = SecretVault.load(Secret.self, .edToken) != nil
    }

    func save() { hub?.files.save(state, fileName) }

    private func client() -> EdClient? {
        guard let secret = SecretVault.load(Secret.self, .edToken) else { return nil }
        return EdClient(token: secret.token, tokenKind: secret.kind, region: EdWeb.region)
    }

    // MARK: Connecting

    /// Opens the Ed login window; stores the token once Ed accepts it.
    func signIn() async {
        if let existing = loginController {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        signingIn = true
        defer { signingIn = false }
        let controller = EdLoginWindowController()
        loginController = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let result = await controller.result()
        loginController = nil
        guard let signedIn = result else { return }
        store(Secret(token: signedIn.0, kind: .session), user: signedIn.1)
        await sync()
    }

    /// For a personal API token pasted from edstem.org/<region>/settings/api-tokens.
    func useAPIToken(_ token: String) async -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        for kind in [EdClient.TokenKind.apiToken, .session] {
            if let user = try? await EdClient(token: t, tokenKind: kind, region: EdWeb.region).user() {
                store(Secret(token: t, kind: kind), user: user)
                await sync()
                return true
            }
        }
        lastError = "Ed didn't accept that token."
        return false
    }

    private func store(_ secret: Secret, user: EdUserResponse) {
        SecretVault.save(secret, .edToken)
        state.userID = user.user.id
        state.userName = user.user.name
        state.courses = user.courses.map(\.course).filter(\.isActive)
        connected = true
        needsSignIn = false
        lastError = nil
        save()
        OrbitLog.log("ed", "connected: \(state.courses.count) active course(s)")
    }

    func disconnect() {
        SecretVault.delete(.edToken)
        connected = false
        needsSignIn = false
        state = EdState()
        save()
        OrbitLog.log("ed", "disconnected")
    }

    // MARK: Sync

    func syncIfDue(now: Date) async {
        guard connected, !syncing else { return }
        if let last = state.lastSync, now.timeIntervalSince(last) < Self.interval { return }
        await sync(now: now)
    }

    func sync(now: Date = Date()) async {
        guard !syncing, var api = client() else { return }
        syncing = true
        defer { syncing = false }
        do {
            let user: EdUserResponse
            do {
                user = try await api.user()
            } catch EdError.unauthorized {
                // The web token expired: try to pick up a fresh one silently.
                guard let fresh = await refreshToken() else { throw EdError.unauthorized }
                api = EdClient(token: fresh.token, tokenKind: .session, region: EdWeb.region)
                user = fresh.user
            }
            state.userID = user.user.id
            state.userName = user.user.name
            state.courses = user.courses.map(\.course).filter(\.isActive)

            var found: [EdItem] = []
            for course in state.courses {
                do {
                    let threads = try await api.threads(courseID: course.id, limit: 30)
                    found += EdSync.process(course: course, response: threads, state: &state, region: EdWeb.region, now: now)
                } catch EdError.unauthorized {
                    throw EdError.unauthorized
                } catch {
                    OrbitLog.log("ed", "\(course.code): \(error)")
                }
            }
            let fresh = state.add(found)
            state.lastSync = now
            needsSignIn = false
            lastError = nil
            save()
            await integrate(fresh, now: now)
            OrbitLog.log("ed", "\(state.courses.count) course(s), \(fresh.count) new item(s)")
        } catch EdError.unauthorized {
            needsSignIn = true
            lastError = "Ed signed you out. Connect again to keep getting updates."
            OrbitLog.log("ed", "sign-in expired")
        } catch {
            lastError = "Couldn't reach Ed: \(error.localizedDescription)"
            OrbitLog.log("ed", "sync failed: \(error)")
        }
    }

    private func refreshToken() async -> (token: String, user: EdUserResponse)? {
        guard SecretVault.load(Secret.self, .edToken)?.kind == .session else { return nil }
        let h = harvester ?? EdTokenHarvester()
        harvester = h
        guard let found = await h.harvest() else { return nil }
        SecretVault.save(Secret(token: found.token, kind: .session), .edToken)
        OrbitLog.log("ed", "token refreshed")
        return found
    }

    /// Activity feed, knowledge base, notifications and deadline to-dos.
    private func integrate(_ items: [EdItem], now: Date) async {
        guard !items.isEmpty, let brain = hub?.brain else { return }
        brain.academicLoadIfNeeded()
        _ = brain.academic.knowledge.recordActivity(items.map(EdSync.activityItem))
        for item in items {
            // Staff posts and useful student Q&A, tagged with the ELE week they're about.
            if let doc = EdLinker.document(item, kb: brain.academic.knowledge) ?? EdSync.document(item) {
                _ = brain.academic.knowledge.upsert(doc)
            }
        }
        addDeadlineTasks(items, brain: brain, now: now)
        brain.saveAcademic()
        brain.academic.publish()

        let important = items.filter { $0.importance.isImportant && !$0.baseline }
        for item in important.prefix(5) {
            var body = item.kind == .reply ? item.text : item.snippet
            if let summary = await summary(item) { body = summary }
            hub?.notify(id: "ed-\(item.id)", title: "\(item.moduleCode ?? item.courseCode) · \(item.title)",
                        body: String(((item.author.map { "\($0): " } ?? "") + body).prefix(220)), category: "ed")
        }
        if important.count > 5 {
            hub?.notify(id: "ed-more-\(Int(now.timeIntervalSince1970))", title: "Ed Discussion",
                        body: "\(important.count - 5) more important posts. Open Orbit → Uni → Ed.", category: "ed")
        }
    }

    /// One-line summary of a long post from the AI on this Mac (never a cloud model).
    private func summary(_ item: EdItem) async -> String? {
        guard FeatureSettings.bool(Self.summariesKey, default: false), item.text.count > 500,
              let router = hub?.router else { return nil }
        let text = try? await router.complete(
            system: "Summarise this course forum post for a student in one sentence (max 25 words). Keep dates, times and rooms exact.",
            user: String(item.text.prefix(4000)), purpose: .privateData)
        let s = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    /// Deadlines mentioned in staff posts become to-dos (once per thread and day).
    private func addDeadlineTasks(_ items: [EdItem], brain: OrbitBrain, now: Date) {
        guard let context = hub?.context else { return }
        let tz = brain.prefs.timeZone
        let extractor = DateExtractor(now: now, timeZone: tz, academic: brain.academic.knowledge.calendar)
        var london = Calendar(identifier: .gregorian)
        london.timeZone = tz
        let dayFormat = DateFormatter()
        dayFormat.dateFormat = "yyyy-MM-dd"
        dayFormat.timeZone = tz
        var added = 0
        for item in items {
            for match in EdSync.deadlineMentions(in: item, extractor: extractor) {
                let key = "\(item.threadID)|\(dayFormat.string(from: match.date))"
                guard !state.deadlineKeys.contains(key) else { continue }
                state.deadlineKeys.insert(key)
                let due = match.hasTime ? match.date
                    : (london.date(bySettingHour: 12, minute: 0, second: 0, of: match.date) ?? match.date)
                let id = StableUUID.make("orbit-ed|\(key)")
                guard context.record(StoredTask.self, id: id.uuidString) == nil else { continue }
                let sentence = EdText.snippet(item.text, 300)
                let task = OrbitTask(id: id, title: "\(item.moduleCode ?? item.courseCode): \(item.title)",
                                     notes: "From Ed Discussion\(item.author.map { " (\($0))" } ?? ""): \(sentence)\n\(item.url)",
                                     estimateMinutes: 60, deadline: due, earliestStart: now, priority: .normal,
                                     energy: .medium, moduleCode: item.moduleCode, source: .ele,
                                     sourceRef: "ed:\(item.threadID)")
                context.insert(StoredTask(task: task))
                added += 1
            }
        }
        if added > 0 {
            context.saveQuietly()
            hub?.tasksChanged()
            save()
            OrbitLog.log("ed", "\(added) deadline to-do(s) from Ed")
        }
    }

    // MARK: Assistant

    func activityText(since: Date?, course: String?) -> String {
        guard connected else { return "Ed Discussion isn't connected. Settings → Uni → Connect Ed Discussion." }
        let items = state.recent(since: since, moduleCode: course, limit: 30)
        let tz = hub?.prefs.timeZone ?? .current
        var text = EdSync.text(items, timeZone: tz)
        if let last = state.lastSync {
            text += "\n(Last checked \(Fmt.relative(last)).)"
        }
        return text
    }
}
