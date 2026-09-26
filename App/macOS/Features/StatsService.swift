import Foundation
import Observation
import SwiftData
import OrbitCore

/// The "keep coming back" loop: today's three rings (study minutes, to-dos done,
/// flashcard reviews), the streak and the heatmap on Home and in the menu bar.
///
/// Study minutes and to-dos are recomputed from what Orbit already keeps (the
/// focus log, completed blocks and tasks). Reviews aren't kept per day anywhere
/// else, so they're counted here. Stored in Application Support/Orbit/Features/stats.json.
@MainActor
@Observable
final class StatsService {
    @ObservationIgnored weak var hub: FeatureHub?
    private(set) var ledger = StatsLedger()
    @ObservationIgnored private var observer: NSObjectProtocol?
    private let fileName = "stats.json"

    var goals: DailyGoals {
        get { ledger.goals }
        set { ledger.goals = newValue; save() }
    }

    func load() {
        if let saved = hub?.files.load(StatsLedger.self, fileName) { ledger = saved }
        observer = NotificationCenter.default.addObserver(forName: .orbitFlashcardReviewed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FeatureHub.shared.stats.recordReview(now: Date()) }
        }
    }

    func save() { hub?.files.save(ledger, fileName) }

    func recordReview(now: Date = Date()) {
        let key = keys.key(now)
        ledger.reviews[key, default: 0] += 1
        // Keep a year.
        if ledger.reviews.count > 400 {
            let cutoff = keys.key(daysBefore: 380, now)
            ledger.reviews = ledger.reviews.filter { $0.key >= cutoff }
        }
        save()
    }

    private var keys: DayKeys { DayKeys(timeZone: hub?.prefs.timeZone ?? TimeZone(identifier: "Europe/London")!) }

    /// Everything the rings, streak and heatmap need.
    func momentum(tasks: [StoredTask], blocks: [StoredBlock]) -> Momentum {
        let log = hub?.state.focusLog ?? []
        let loggedBlocks = Set(log.compactMap { $0.blockID?.uuidString })
        let focus = log.map { ($0.start, $0.minutes) }
        let ticked = blocks.filter { $0.completed && !loggedBlocks.contains($0.id) }.map { ($0.start, $0.minutes) }
        let done = tasks.compactMap(\.completedAt)
        let tz = hub?.prefs.timeZone ?? TimeZone(identifier: "Europe/London")!
        let days = DailyStatsBuilder.build(focus: focus, completedBlocks: ticked, completedTasks: done,
                                           reviews: ledger.reviews, timeZone: tz)
        return Momentum(days: days, goals: ledger.goals, timeZone: tz)
    }
}

struct StatsLedger: Codable {
    var reviews: [String: Int] = [:]
    var goals = DailyGoals()

    init() {}

    enum CodingKeys: String, CodingKey { case reviews, goals }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reviews = (try? c.decode([String: Int].self, forKey: .reviews)) ?? [:]
        goals = (try? c.decode(DailyGoals.self, forKey: .goals)) ?? DailyGoals()
    }
}
