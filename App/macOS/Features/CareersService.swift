import AppKit
import Foundation
import Observation
import SwiftData
import WebKit
import OrbitCore

/// Careers: Trackr's finance programme lists, polled every 2 hours while the Mac
/// is awake. Notifies when watched programmes open or are about to close, and
/// adds an "Apply: …" to-do when a starred or watched programme opens.
/// Everything is stored under Application Support/Orbit/Features.
@MainActor
@Observable
final class CareersService {
    @ObservationIgnored weak var hub: FeatureHub?

    private(set) var opportunities: [Opportunity] = []
    private(set) var events: [CareersEvent] = []
    var preferences = CareersPreferences()
    private(set) var lastSync: Date?
    private(set) var syncing = false
    private(set) var status = ""

    @ObservationIgnored private var state = CareersStore()
    private let fileName = "careers.json"
    @ObservationIgnored private var scraper: TrackrWebScraper?

    static let interval: TimeInterval = 2 * 3600

    var enabled: Bool {
        get { FeatureSettings.bool(Self.enabledKey, default: true) }
        set { FeatureSettings.defaults.set(newValue, forKey: Self.enabledKey) }
    }
    static let enabledKey = "features.careers.enabled"

    // MARK: Persistence

    func load() {
        guard let hub, let saved = hub.files.load(CareersStore.self, fileName) else { return }
        state = saved
        opportunities = saved.opportunities
        events = saved.events
        preferences = saved.preferences
        lastSync = saved.lastSync
    }

    func save() {
        state.opportunities = opportunities
        state.events = Array(events.prefix(300))
        state.preferences = preferences
        state.lastSync = lastSync
        hub?.files.save(state, fileName)
    }

    var tracker: CareersTracker { CareersTracker(preferences: preferences, now: Date()) }

    // MARK: Sync

    func syncIfDue(now: Date) async {
        guard enabled, !syncing else { return }
        if let last = lastSync, now.timeIntervalSince(last) < Self.interval {
            // Closing-soon and "expected soon" reminders are time-based: check them hourly between fetches.
            if now.timeIntervalSince(state.lastReminderCheck ?? .distantPast) > 3600 {
                state.lastReminderCheck = now
                handle(tracker.events(old: opportunities, new: opportunities, sent: Set(state.sent.keys)), now: now)
            }
            return
        }
        await sync(now: now)
    }

    func sync(now: Date = Date()) async {
        guard !syncing else { return }
        syncing = true
        status = "Checking Trackr…"
        defer { syncing = false }
        var fetched: [Opportunity] = []
        var failures: [String] = []
        for category in OpportunityCategory.allCases where preferences.categories.contains(category) {
            let season = TrackrParser.season(for: category, now: now)
            do {
                fetched += try await TrackrClient().fetch(category: category, season: season, region: preferences.region)
            } catch {
                OrbitLog.log("careers", "API failed for \(category.rawValue): \(error.localizedDescription); trying the page")
                do {
                    let s = scraper ?? TrackrWebScraper()
                    scraper = s
                    fetched += try await s.scrape(category: category)
                } catch {
                    failures.append(category.label)
                    OrbitLog.log("careers", "page read failed for \(category.rawValue): \(error.localizedDescription)")
                    // Keep what we had for this category.
                    fetched += opportunities.filter { $0.category == category }
                }
            }
        }
        guard !fetched.isEmpty else {
            status = "Couldn't reach Trackr. Orbit will try again later."
            lastSync = now
            save()
            return
        }
        let old: [Opportunity]? = state.hasBaseline ? opportunities : nil
        let new = dedupe(fetched)
        let found = CareersTracker(preferences: preferences, now: now).events(old: old, new: new, sent: Set(state.sent.keys))
        opportunities = new
        state.hasBaseline = true
        lastSync = now
        state.lastReminderCheck = now
        handle(found, now: now)
        status = failures.isEmpty ? "" : "Couldn't read \(failures.joined(separator: ", ")) this time."
        OrbitLog.log("careers", "\(new.count) programmes, \(found.count) new event(s)")
        save()
    }

    private func dedupe(_ list: [Opportunity]) -> [Opportunity] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }

    /// Records events, notifies and adds apply tasks.
    private func handle(_ found: [CareersEvent], now: Date) {
        guard !found.isEmpty else { return }
        let byID = Dictionary(opportunities.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var notified = 0
        for e in found {
            state.sent[e.id] = now
            events.insert(e, at: 0)
            if e.notify && preferences.notificationsEnabled && notified < 6 {
                notified += 1
                hub?.notify(id: "careers-\(e.id)", title: e.title, body: e.body, category: "careers")
            }
            if e.kind == .opened, preferences.createApplyTasks, let o = byID[e.opportunityID], preferences.isWatched(o) {
                addApplyTask(o, now: now)
            }
        }
        // Forget sent keys after four months (a cycle).
        state.sent = state.sent.filter { now.timeIntervalSince($0.value) < 120 * 86400 }
    }

    /// Adds "Apply: <company> <programme>" once per programme.
    @discardableResult
    func addApplyTask(_ o: Opportunity, now: Date = Date()) -> Bool {
        guard let context = hub?.context else { return false }
        let plan = CareersTracker(preferences: preferences, now: now).applyTask(for: o)
        let id = StableUUID.make("orbit-careers|\(o.id)")
        guard context.record(StoredTask.self, id: id.uuidString) == nil else { return false }
        let task = OrbitTask(id: id, title: plan.title, notes: plan.notes, estimateMinutes: plan.estimateMinutes,
                             deadline: plan.deadline, earliestStart: now, priority: .high, energy: .medium,
                             source: .manual, sourceRef: plan.sourceRef, minBlockMinutes: 30, maxBlockMinutes: 90)
        context.insert(StoredTask(task: task))
        context.saveQuietly()
        hub?.tasksChanged()
        OrbitLog.log("careers", "apply task added for \(o.company)")
        return true
    }

    func hasApplyTask(_ o: Opportunity) -> Bool {
        hub?.context?.record(StoredTask.self, id: StableUUID.make("orbit-careers|\(o.id)").uuidString) != nil
    }

    // MARK: Watchlist

    func toggleStar(_ o: Opportunity) {
        if preferences.starred.contains(o.id) { preferences.starred.remove(o.id) } else {
            preferences.starred.insert(o.id)
            preferences.muted.remove(o.id)
        }
        save()
    }

    func toggleCompanyStar(_ company: String) {
        let key = company.lowercased()
        if preferences.starredCompanies.contains(key) { preferences.starredCompanies.remove(key) } else { preferences.starredCompanies.insert(key) }
        save()
    }

    func toggleMute(_ o: Opportunity) {
        if preferences.muted.contains(o.id) { preferences.muted.remove(o.id) } else { preferences.muted.insert(o.id) }
        save()
    }

    func updatePreferences(_ change: (inout CareersPreferences) -> Void) {
        change(&preferences)
        save()
    }

    // MARK: Assistant text

    func openText(watchedOnly: Bool) -> String {
        let t = tracker
        return t.text(t.openNow(opportunities, watchedOnly: watchedOnly),
                      empty: opportunities.isEmpty ? "Orbit hasn't read Trackr yet." : "Nothing on \(watchedOnly ? "the watchlist" : "Trackr") is open right now.")
    }

    func upcomingText(days: Int, watchedOnly: Bool) -> String {
        let t = tracker
        return t.text(t.openingSoon(opportunities, withinDays: days, watchedOnly: watchedOnly),
                      empty: "Nothing expected to open in the next \(days) days.")
    }

    func searchText(_ query: String) -> String {
        let t = tracker
        return t.text(t.search(opportunities, query: query), empty: "No programmes match “\(query)”.")
    }
}

/// On disk.
struct CareersStore: Codable {
    var opportunities: [Opportunity] = []
    var events: [CareersEvent] = []
    var preferences = CareersPreferences()
    var lastSync: Date?
    var lastReminderCheck: Date?
    var hasBaseline = false
    var sent: [String: Date] = [:]

    init() {}

    enum CodingKeys: String, CodingKey { case opportunities, events, preferences, lastSync, lastReminderCheck, hasBaseline, sent }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        opportunities = (try? c.decode([Opportunity].self, forKey: .opportunities)) ?? []
        events = (try? c.decode([CareersEvent].self, forKey: .events)) ?? []
        preferences = (try? c.decode(CareersPreferences.self, forKey: .preferences)) ?? CareersPreferences()
        lastSync = try? c.decode(Date.self, forKey: .lastSync)
        lastReminderCheck = try? c.decode(Date.self, forKey: .lastReminderCheck)
        hasBaseline = (try? c.decode(Bool.self, forKey: .hasBaseline)) ?? false
        sent = (try? c.decode([String: Date].self, forKey: .sent)) ?? [:]
    }
}

// MARK: - Reading the rendered page

/// Fallback when Trackr's API refuses us: load the tracker page in a hidden web
/// view (it's an Angular app, so the table only exists after its scripts run)
/// and read the table cells with JavaScript.
@MainActor
final class TrackrWebScraper: NSObject, WKNavigationDelegate {
    enum ScrapeError: LocalizedError {
        case empty, timeout
        var errorDescription: String? {
            switch self {
            case .empty: "The Trackr page had no table."
            case .timeout: "Trackr took too long to load."
            }
        }
    }

    private var view: WKWebView?
    private var waiter: NavigationWaiter?

    func scrape(category: OpportunityCategory) async throws -> [Opportunity] {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = view ?? WKWebView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1200), configuration: config)
        web.customUserAgent = ELEWebSession.userAgent
        web.navigationDelegate = self
        view = web
        let w = NavigationWaiter()
        waiter = w
        web.load(URLRequest(url: category.pageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45))
        let timeout = Task { @MainActor [weak w] in
            try? await Task.sleep(for: .seconds(45))
            w?.finish(.failure(ScrapeError.timeout))
        }
        defer { timeout.cancel() }
        try await w.wait()
        // The table fills in after the API call: poll for rows for up to 20 seconds.
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(1))
            let result = try? await web.callAsyncJavaScript(TrackrParser.tableScript, arguments: [:], in: nil, contentWorld: .page)
            guard let dict = result as? [String: Any] else { continue }
            let rows = (dict["rows"] as? [[Any]] ?? []).map { $0.map { $0 as? String ?? "" } }
            guard rows.count > 0 else { continue }
            let header = (dict["header"] as? [Any])?.map { $0 as? String ?? "" }
            let links = (dict["links"] as? [[Any]])?.map { $0.map { $0 as? String } }
            let parsed = TrackrParser.parseTable(rows: rows, header: (header?.isEmpty ?? true) ? nil : header,
                                                 category: category, links: links)
            if !parsed.isEmpty { return parsed }
        }
        throw ScrapeError.empty
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { waiter?.finish(.success(())) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { waiter?.finish(ELEWebSession.isCancel(error) ? .success(()) : .failure(error)) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            if ELEWebSession.isCancel(error) { return }
            waiter?.finish(.failure(error))
        }
    }
}
