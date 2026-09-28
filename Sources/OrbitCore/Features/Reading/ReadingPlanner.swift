import Foundation

/// A reading to be done by a certain time (usually the lecture or tutorial it's for).
public struct ReadingAssignment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var moduleCode: String
    public var title: String
    public var week: Int?
    /// Page count if known (Talis metadata or "pp. 45–67" in the title).
    public var pages: Int?
    /// Minutes if known outright (overrides pages).
    public var minutes: Int?
    public var isGuide: Bool
    public var essential: Bool
    /// When it has to be finished (the session it's for).
    public var neededBy: Date
    /// Don't start before this.
    public var availableFrom: Date?
    public var done: Bool

    public init(id: String, moduleCode: String, title: String, week: Int? = nil, pages: Int? = nil, minutes: Int? = nil,
                isGuide: Bool = false, essential: Bool = true, neededBy: Date, availableFrom: Date? = nil, done: Bool = false) {
        self.id = id; self.moduleCode = moduleCode; self.title = title; self.week = week; self.pages = pages
        self.minutes = minutes; self.isGuide = isGuide; self.essential = essential; self.neededBy = neededBy
        self.availableFrom = availableFrom; self.done = done
    }
}

/// One day's slice of a reading, as a to-do.
public struct ReadingChunk: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var readingID: String
    public var moduleCode: String
    public var index: Int
    public var count: Int
    public var title: String
    public var minutes: Int
    public var pageRange: ClosedRange<Int>?
    /// Local midnight of the day it's planned for.
    public var day: Date
    public var earliestStart: Date
    public var deadline: Date

    public var sourceRef: String { "reading:\(readingID)#\(index)" }

    public func task(done: Bool = false) -> OrbitTask {
        OrbitTask(id: id, title: title, notes: "Reading for \(moduleCode). Chunk \(index + 1) of \(count).",
                  estimateMinutes: minutes, deadline: deadline, earliestStart: earliestStart, priority: .normal,
                  energy: .medium, moduleCode: moduleCode, source: .ele, sourceRef: sourceRef,
                  minBlockMinutes: minutes, maxBlockMinutes: minutes)
    }
}

public enum ReadingEstimator {
    public static let defaultPages = 20
    public static let chapterPages = 30
    public static let guidePages = 5
    /// 20 pages ≈ 40 minutes.
    public static let minutesPerPage = 2.0

    static let pageRangeRE = try! NSRegularExpression(
        pattern: "\\b(?:pp?\\.?|pages?)\\s*(\\d{1,4})\\s*[-–—]\\s*(\\d{1,4})\\b", options: [.caseInsensitive])
    static let pageCountRE = try! NSRegularExpression(pattern: "\\b(\\d{1,4})\\s*(?:pp|pages)\\b", options: [.caseInsensitive])
    static let chapterRE = try! NSRegularExpression(pattern: "\\b(?:chapters?|chs?\\.?|ch\\.)\\s*(\\d{1,2})(?:\\s*(?:[-–—]|and|&)\\s*(\\d{1,2}))?",
                                                    options: [.caseInsensitive])

    /// Pages from a title like "Mankiw ch. 3, pp. 45–67" (a page range wins over chapters).
    public static func pages(in title: String) -> (pages: Int, range: ClosedRange<Int>?)? {
        let ns = title as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let m = pageRangeRE.firstMatch(in: title, range: full),
           let a = Int(ns.substring(with: m.range(at: 1))), let b = Int(ns.substring(with: m.range(at: 2))), b >= a, b - a < 400 {
            return (b - a + 1, a...b)
        }
        if let m = pageCountRE.firstMatch(in: title, range: full), let n = Int(ns.substring(with: m.range(at: 1))), n > 0, n < 1000 {
            return (n, nil)
        }
        if let m = chapterRE.firstMatch(in: title, range: full) {
            var chapters = 1
            if m.range(at: 2).location != NSNotFound, let a = Int(ns.substring(with: m.range(at: 1))),
               let b = Int(ns.substring(with: m.range(at: 2))) {
                chapters = ns.substring(with: m.range).lowercased().contains("and") || ns.substring(with: m.range).contains("&")
                    ? 2 : max(1, b - a + 1)
            }
            return (chapters * chapterPages, nil)
        }
        return nil
    }

    public static func estimate(_ r: ReadingAssignment) -> (pages: Int, minutes: Int, range: ClosedRange<Int>?) {
        if let m = r.minutes { return (Int(Double(m) / minutesPerPage), m, nil) }
        let parsed = pages(in: r.title)
        let pages = r.pages ?? parsed?.pages ?? (r.isGuide ? guidePages : defaultPages)
        let minutes = max(10, Int((Double(pages) * minutesPerPage / 5).rounded()) * 5)
        return (pages, minutes, r.pages == nil ? parsed?.range : nil)
    }
}

/// Splits readings into ≤ 45-minute daily chunks across the days before they're
/// needed, balancing the load across days. Re-running it each day re-balances:
/// finished minutes are subtracted and what's left is spread over the days remaining.
public struct ReadingPlanner: Sendable {
    public var prefs: UserPrefs
    public var maxChunkMinutes: Int
    public var minChunkMinutes: Int
    /// How many days before it's needed a reading can start.
    public var leadDays: Int
    /// Soft cap on reading per day before spilling to another day.
    public var dailyReadingCap: Int

    public init(prefs: UserPrefs = UserPrefs(), maxChunkMinutes: Int = 45, minChunkMinutes: Int = 15, leadDays: Int = 7,
                dailyReadingCap: Int = 120) {
        self.prefs = prefs; self.maxChunkMinutes = maxChunkMinutes; self.minChunkMinutes = minChunkMinutes
        self.leadDays = leadDays; self.dailyReadingCap = dailyReadingCap
    }

    var cal: DayCalendar { DayCalendar(timeZone: prefs.timeZone) }

    public static func chunkID(readingID: String, index: Int) -> UUID { StableUUID.make("reading-chunk|\(readingID)|\(index)") }

    /// - Parameter minutesDone: minutes already read per reading id (finished chunks).
    public func plan(_ readings: [ReadingAssignment], minutesDone: [String: Int] = [:], now: Date) -> [ReadingChunk] {
        let today = cal.startOfDay(now)
        var load: [Date: Int] = [:]
        var out: [ReadingChunk] = []

        let open = readings.filter { !$0.done }
            .filter { $0.neededBy > now || cal.isSameDay($0.neededBy, now) || $0.neededBy > now.addingTimeInterval(-3 * 86400) }
            .sorted { ($0.neededBy, $0.moduleCode, $0.id) < ($1.neededBy, $1.moduleCode, $1.id) }

        for r in open {
            let est = ReadingEstimator.estimate(r)
            let remaining = max(0, est.minutes - (minutesDone[r.id] ?? 0))
            guard remaining >= 5 else { continue }
            let firstIndex = chunkOffset(done: minutesDone[r.id] ?? 0)

            // Days it can go on: from max(today, availableFrom, neededBy − leadDays) to the day before it's needed
            // (or the day itself if it's needed later that day, or it's already late).
            let from = max(today, cal.startOfDay(r.availableFrom ?? cal.addingDays(-leadDays, to: r.neededBy)))
            let neededDay = cal.startOfDay(r.neededBy)
            var days = cal.dayStarts(from: from, to: neededDay).filter { !prefs.restDays.contains(cal.weekday($0)) }
            if days.isEmpty {
                let sameDayRoom = cal.minuteOfDay(r.neededBy) - max(prefs.dayStart, neededDay == today ? cal.minuteOfDay(now) : 0)
                days = [neededDay <= today ? today : (sameDayRoom >= 30 ? neededDay : max(today, cal.addingDays(-1, to: neededDay)))]
            }

            let count = max(1, Int((Double(remaining) / Double(maxChunkMinutes)).rounded(.up)))
            let sizes = Self.split(remaining, into: count, minimum: minChunkMinutes)
            let pageStep: Int? = est.range.map { _ in max(1, est.pages / max(1, sizes.count)) }

            var lastDay = days.first!
            var pageCursor = est.range?.lowerBound ?? 0
            for (i, size) in sizes.enumerated() {
                // Chunks go in order; each on the least-loaded allowed day from the previous chunk's day on,
                // preferring to spread one chunk per day when there's room.
                let candidates = days.filter { $0 >= lastDay }
                let remainingChunks = sizes.count - i
                let later = i > 0 ? candidates.filter { $0 > lastDay } : candidates
                let spread = later.count >= remainingChunks
                // With room to spare, keep enough days after this one for the remaining chunks.
                let pool = spread ? later.filter { d in later.filter { $0 > d }.count >= remainingChunks - 1 } : candidates
                let choice = (pool.isEmpty ? candidates : pool).min { a, b in
                    let la = load[a, default: 0], lb = load[b, default: 0]
                    let overA = la + size > dailyReadingCap, overB = lb + size > dailyReadingCap
                    if overA != overB { return !overA }
                    return la != lb ? la < lb : a < b
                } ?? days.last!
                lastDay = choice
                load[choice, default: 0] += size

                var range: ClosedRange<Int>?
                if let step = pageStep, let whole = est.range {
                    let upper = i == sizes.count - 1 ? whole.upperBound : min(whole.upperBound, pageCursor + step - 1)
                    range = pageCursor...max(pageCursor, upper)
                    pageCursor = upper + 1
                }
                let index = firstIndex + i
                let total = firstIndex + sizes.count
                let label = range.map { " (pp. \($0.lowerBound)–\($0.upperBound))" } ?? (total > 1 ? " (part \(index + 1) of \(total))" : "")
                let dayEnd = min(cal.endOfDay(choice), r.neededBy > now ? r.neededBy : cal.endOfDay(choice))
                let start = max(now, cal.date(minute: prefs.dayStart, of: choice))
                out.append(ReadingChunk(id: Self.chunkID(readingID: r.id, index: index), readingID: r.id, moduleCode: r.moduleCode,
                                        index: index, count: total, title: "Read: \(r.title)\(label)", minutes: size,
                                        pageRange: range, day: choice, earliestStart: min(start, dayEnd.addingTimeInterval(-Double(size) * 60)),
                                        deadline: dayEnd))
            }
        }
        return out.sorted { ($0.day, $0.moduleCode, $0.readingID, $0.index) < ($1.day, $1.moduleCode, $1.readingID, $1.index) }
    }

    /// Chunks already finished (so re-planned chunks keep counting up).
    func chunkOffset(done: Int) -> Int { done <= 0 ? 0 : Int((Double(done) / Double(maxChunkMinutes)).rounded(.up)) }

    /// Splits `total` into `count` near-equal 5-minute-rounded parts.
    static func split(_ total: Int, into count: Int, minimum: Int) -> [Int] {
        guard count > 1 else { return [total] }
        let base = Double(total) / Double(count)
        var parts = (0..<(count - 1)).map { _ in max(minimum, Int((base / 5).rounded()) * 5) }
        parts.append(max(5, total - parts.reduce(0, +)))
        return parts
    }

    /// The session a week's reading is for: the module's first lecture/tutorial/seminar
    /// in that teaching week, else Monday 09:00 of the week.
    public static func neededBy(moduleCode: String, weekStart: Date, events: [CalendarEvent], timeZone: TimeZone) -> Date {
        let cal = DayCalendar(timeZone: timeZone)
        let weekEnd = cal.addingDays(7, to: weekStart)
        let sessions = events.filter { e in
            !e.isAllDay && e.start >= weekStart && e.start < weekEnd
                && (NoteMetadataDetector.moduleCode(in: [e.title, e.notes])?.caseInsensitiveCompare(moduleCode) == .orderedSame)
        }
        return sessions.map(\.start).min() ?? cal.date(minute: 9 * 60, of: weekStart)
    }
}
