import Foundation

// The student's fixed personal routine: catered-hall meals (as windows with a
// movable 45-minute meal inside), book reading, the daily shutdown ritual and a
// protected sleep window. Stored inside `UserPrefs.routine` so it syncs with the
// other preferences. The scheduler treats every routine block as busy.

public enum RoutineKind: String, Codable, CaseIterable, Sendable {
    case breakfast, earlyContinental, brunch, lunch, dinner, reading, shutdown, sleep, gym, travel

    public var isMeal: Bool {
        switch self {
        case .breakfast, .earlyContinental, .brunch, .lunch, .dinner: true
        default: false
        }
    }

    public var symbol: String {
        switch self {
        case .breakfast, .earlyContinental: "cup.and.saucer.fill"
        case .brunch, .lunch: "fork.knife"
        case .dinner: "fork.knife.circle.fill"
        case .reading: "book.fill"
        case .shutdown: "moon.stars.fill"
        case .sleep: "bed.double.fill"
        case .gym: "figure.strengthtraining.traditional"
        case .travel: "figure.walk"
        }
    }
}

/// A catered meal: the hall serves between `windowStart` and `windowEnd`; Orbit
/// reserves `mealMinutes` somewhere inside it, as close to `preferredStart` as classes allow.
public struct MealWindow: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: RoutineKind
    public var name: String
    /// Weekday numbers, 1 = Sunday … 7 = Saturday.
    public var weekdays: Set<Int>
    public var windowStart: MinuteOfDay
    public var windowEnd: MinuteOfDay
    public var mealMinutes: Int
    public var preferredStart: MinuteOfDay
    public var enabled: Bool

    public init(id: String, kind: RoutineKind, name: String, weekdays: Set<Int>, windowStart: MinuteOfDay,
                windowEnd: MinuteOfDay, mealMinutes: Int = 45, preferredStart: MinuteOfDay? = nil, enabled: Bool = true) {
        self.id = id; self.kind = kind; self.name = name; self.weekdays = weekdays
        self.windowStart = windowStart; self.windowEnd = windowEnd; self.mealMinutes = mealMinutes
        self.preferredStart = preferredStart ?? windowStart; self.enabled = enabled
    }
}

/// Travel between the hall (home) and campus.
public struct TravelSettings: Codable, Hashable, Sendable {
    /// Hall ↔ campus, each way.
    public var travelMinutes: Int
    /// Between two campus buildings / to the library.
    public var walkMinutes: Int
    /// Gaps between campus events up to this long are spent on campus (no trip home).
    public var campusGapMinutes: Int
    /// Location words that mean "home" (the catered hall).
    public var homeKeywords: [String]
    /// Where on-campus work goes, e.g. "Forum library".
    public var campusStudySpot: String

    public init(travelMinutes: Int = 15, walkMinutes: Int = 5, campusGapMinutes: Int = 90,
                homeKeywords: [String] = ["holland hall"], campusStudySpot: String = "Forum library") {
        self.travelMinutes = travelMinutes; self.walkMinutes = walkMinutes; self.campusGapMinutes = campusGapMinutes
        self.homeKeywords = homeKeywords; self.campusStudySpot = campusStudySpot
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TravelSettings()
        travelMinutes = (try? c.decode(Int.self, forKey: .travelMinutes)) ?? d.travelMinutes
        walkMinutes = (try? c.decode(Int.self, forKey: .walkMinutes)) ?? d.walkMinutes
        campusGapMinutes = (try? c.decode(Int.self, forKey: .campusGapMinutes)) ?? d.campusGapMinutes
        homeKeywords = (try? c.decode([String].self, forKey: .homeKeywords)) ?? d.homeKeywords
        campusStudySpot = (try? c.decode(String.self, forKey: .campusStudySpot)) ?? d.campusStudySpot
    }
}

/// Placeholder for a future gym integration (sessions will become routine blocks).
public struct GymPlan: Codable, Hashable, Sendable {
    public var enabled: Bool
    /// Weekday → start minute. Not scheduled yet.
    public var sessions: [Int: MinuteOfDay]
    public var sessionMinutes: Int
    public init(enabled: Bool = false, sessions: [Int: MinuteOfDay] = [:], sessionMinutes: Int = 60) {
        self.enabled = enabled; self.sessions = sessions; self.sessionMinutes = sessionMinutes
    }
}

public struct RoutineSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var hallName: String
    public var meals: [MealWindow]
    public var readingEnabled: Bool
    public var readingStart: MinuteOfDay
    public var readingMinutes: Int
    public var readingTitle: String
    public var shutdownEnabled: Bool
    public var shutdownTime: MinuteOfDay
    /// Nothing is scheduled between bedtime and wake.
    public var bedtime: MinuteOfDay
    public var wakeTime: MinuteOfDay
    /// Getting ready after waking: no meal or work before wake + this.
    public var morningPrepMinutes: Int
    public var protectSleep: Bool
    /// Type-up blocks after lectures/tutorials.
    public var typeUpEnabled: Bool
    public var typeUpMinutes: Int
    /// A type-up not done this many days after it was planned is removed.
    public var typeUpExpiryDays: Int
    /// Also write routine blocks (meals, reading) to Google Calendar.
    public var pushRoutineToGoogle: Bool
    public var travel: TravelSettings
    public var gym: GymPlan

    public init(enabled: Bool = true, hallName: String = "Holland Hall", meals: [MealWindow] = RoutineSettings.hollandHallMeals,
                readingEnabled: Bool = true, readingStart: MinuteOfDay = 22 * 60, readingMinutes: Int = 20,
                readingTitle: String = "Read (book)", shutdownEnabled: Bool = true, shutdownTime: MinuteOfDay = 21 * 60 + 58,
                bedtime: MinuteOfDay = 22 * 60 + 30, wakeTime: MinuteOfDay = 7 * 60 + 35, morningPrepMinutes: Int = 20,
                protectSleep: Bool = true,
                typeUpEnabled: Bool = true, typeUpMinutes: Int = 25, typeUpExpiryDays: Int = 3,
                pushRoutineToGoogle: Bool = false, travel: TravelSettings = TravelSettings(), gym: GymPlan = GymPlan()) {
        self.enabled = enabled; self.hallName = hallName; self.meals = meals
        self.readingEnabled = readingEnabled; self.readingStart = readingStart; self.readingMinutes = readingMinutes
        self.readingTitle = readingTitle; self.shutdownEnabled = shutdownEnabled; self.shutdownTime = shutdownTime
        self.bedtime = bedtime; self.wakeTime = wakeTime; self.morningPrepMinutes = morningPrepMinutes
        self.protectSleep = protectSleep
        self.typeUpEnabled = typeUpEnabled; self.typeUpMinutes = typeUpMinutes; self.typeUpExpiryDays = typeUpExpiryDays
        self.pushRoutineToGoogle = pushRoutineToGoogle; self.travel = travel; self.gym = gym
    }

    /// Holland Hall (Exeter, catered): Mon–Fri breakfast 07:30–09:30 and dinner 17:30–19:30;
    /// Sat–Sun brunch 11:00–13:00 (early continental 08:00–10:30 on Saturday, off by default) and dinner 17:30–19:30.
    public static let hollandHallMeals: [MealWindow] = [
        MealWindow(id: "weekday-breakfast", kind: .breakfast, name: "Breakfast", weekdays: [2, 3, 4, 5, 6],
                   windowStart: 7 * 60 + 30, windowEnd: 9 * 60 + 30, preferredStart: 7 * 60 + 55),
        MealWindow(id: "weekday-dinner", kind: .dinner, name: "Dinner", weekdays: [2, 3, 4, 5, 6],
                   windowStart: 17 * 60 + 30, windowEnd: 19 * 60 + 30, preferredStart: 18 * 60),
        MealWindow(id: "saturday-continental", kind: .earlyContinental, name: "Early continental", weekdays: [7],
                   windowStart: 8 * 60, windowEnd: 10 * 60 + 30, preferredStart: 8 * 60 + 30, enabled: false),
        MealWindow(id: "weekend-brunch", kind: .brunch, name: "Brunch", weekdays: [1, 7],
                   windowStart: 11 * 60, windowEnd: 13 * 60, preferredStart: 11 * 60 + 30),
        MealWindow(id: "weekend-dinner", kind: .dinner, name: "Dinner", weekdays: [1, 7],
                   windowStart: 17 * 60 + 30, windowEnd: 19 * 60 + 30, preferredStart: 18 * 60),
    ]

    public static let hollandHall = RoutineSettings()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RoutineSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: key)) ?? fallback }
        enabled = v(.enabled, d.enabled)
        hallName = v(.hallName, d.hallName)
        meals = v(.meals, d.meals)
        readingEnabled = v(.readingEnabled, d.readingEnabled)
        readingStart = v(.readingStart, d.readingStart)
        readingMinutes = v(.readingMinutes, d.readingMinutes)
        readingTitle = v(.readingTitle, d.readingTitle)
        shutdownEnabled = v(.shutdownEnabled, d.shutdownEnabled)
        shutdownTime = v(.shutdownTime, d.shutdownTime)
        bedtime = v(.bedtime, d.bedtime)
        wakeTime = v(.wakeTime, d.wakeTime)
        morningPrepMinutes = v(.morningPrepMinutes, d.morningPrepMinutes)
        protectSleep = v(.protectSleep, d.protectSleep)
        typeUpEnabled = v(.typeUpEnabled, d.typeUpEnabled)
        typeUpMinutes = v(.typeUpMinutes, d.typeUpMinutes)
        typeUpExpiryDays = v(.typeUpExpiryDays, d.typeUpExpiryDays)
        pushRoutineToGoogle = v(.pushRoutineToGoogle, d.pushRoutineToGoogle)
        travel = v(.travel, d.travel)
        gym = v(.gym, d.gym)
    }

    /// Scheduling preferences with the routine applied: work stops at the shutdown,
    /// starts after waking, and the hall's meals replace the generic lunch/dinner breaks.
    public func adjusted(_ prefs: UserPrefs) -> UserPrefs {
        guard enabled else { return prefs }
        var p = prefs
        if shutdownEnabled { p.workCutoff = min(p.workCutoff, shutdownTime) }
        if protectSleep {
            p.dayStart = max(p.dayStart, wakeTime + morningPrepMinutes)
            p.dayEnd = min(p.dayEnd, bedtime)
        }
        p.dinner = nil
        return p
    }
}

extension UserPrefs {
    /// The routine in force (Holland Hall defaults until edited).
    public var effectiveRoutine: RoutineSettings { routine ?? .hollandHall }
}

/// One routine block on one day.
public struct RoutineBlock: Codable, Hashable, Sendable, Identifiable {
    /// "<meal id or kind>@yyyy-MM-dd": stable, so "ate it" ticks survive recomputation.
    public var id: String
    public var kind: RoutineKind
    public var title: String
    public var start: Date
    public var end: Date
    /// For meals: when the hall serves.
    public var window: DateInterval?
    /// Where it happens ("Holland Hall").
    public var location: String?
    /// True when no time in the window avoided classes.
    public var clashes: Bool

    public init(id: String, kind: RoutineKind, title: String, start: Date, end: Date, window: DateInterval? = nil,
                location: String? = nil, clashes: Bool = false) {
        self.id = id; self.kind = kind; self.title = title; self.start = start; self.end = end
        self.window = window; self.location = location; self.clashes = clashes
    }

    public var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

// MARK: - Locations

public enum PlaceKind: String, Codable, Sendable { case home, campus, elsewhere, unknown }

extension TravelSettings {
    /// Where an event happens. Timetabled teaching without a room still counts as campus.
    public func place(of event: CalendarEvent) -> PlaceKind {
        let loc = (event.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !loc.isEmpty {
            if homeKeywords.contains(where: { loc.contains($0.lowercased()) }) { return .home }
            if loc.contains("online") || loc.contains("teams") || loc.contains("zoom") { return .unknown }
            return .campus
        }
        if event.source == .timetable || event.source == .ele { return .campus }
        if LectureTracker.sessionKind(event.title) != .other { return .campus }
        return .unknown
    }
}

// MARK: - Planner

/// Lays the routine out on real days, around the timetable.
public struct RoutinePlanner: Sendable {
    public var settings: RoutineSettings
    public var calendar: DayCalendar

    public init(settings: RoutineSettings, calendar: DayCalendar = DayCalendar()) {
        self.settings = settings; self.calendar = calendar
    }

    public init(prefs: UserPrefs) {
        self.init(settings: prefs.effectiveRoutine, calendar: DayCalendar(timeZone: prefs.timeZone))
    }

    private func key(_ day: Date) -> String { calendar.format(day, "yyyy-MM-dd") }

    /// Timed busy events, each padded by the travel needed to get to the hall (or 0 for events at the hall).
    func busyForHome(_ events: [CalendarEvent]) -> [DateInterval] {
        let t = settings.travel
        return events.filter { $0.isBusy && !$0.isAllDay && $0.end > $0.start }.map { e in
            let pad: Int
            switch t.place(of: e) {
            case .home: pad = 0
            case .campus, .elsewhere: pad = t.travelMinutes
            case .unknown: pad = t.walkMinutes
            }
            return DateInterval(start: e.start.addingTimeInterval(-Double(pad) * 60), end: e.end.addingTimeInterval(Double(pad) * 60))
        }
    }

    /// Places one meal inside its window: the start nearest the preferred time that
    /// doesn't overlap a class (plus travel back to the hall). If every start clashes,
    /// the one with the least overlap is used and flagged.
    public func placeMeal(_ meal: MealWindow, on day: Date, events: [CalendarEvent]) -> RoutineBlock? {
        guard meal.enabled, meal.weekdays.contains(calendar.weekday(day)) else { return nil }
        // Not before wake-up plus getting ready.
        let ready = settings.protectSleep ? settings.wakeTime + settings.morningPrepMinutes : 0
        let windowStart = max(meal.windowStart, ready)
        let ws = calendar.date(minute: windowStart, of: day), we = calendar.date(minute: meal.windowEnd, of: day)
        guard we > ws else { return nil }
        let length = TimeInterval(min(meal.mealMinutes, meal.windowEnd - windowStart) * 60)
        let busy = IntervalMath.merge(busyForHome(events).filter { $0.end > ws && $0.start < we })
        let preferred = calendar.date(minute: min(max(meal.preferredStart, windowStart), meal.windowEnd), of: day)
        var best: (start: Date, overlap: Double, distance: Double)?
        var s = ws
        while s.addingTimeInterval(length) <= we {
            let slot = DateInterval(start: s, end: s.addingTimeInterval(length))
            let overlap = busy.reduce(0.0) { acc, b in
                let lo = max(b.start, slot.start), hi = min(b.end, slot.end)
                return acc + max(0, hi.timeIntervalSince(lo))
            }
            let distance = abs(s.timeIntervalSince(preferred))
            if best == nil || overlap < best!.overlap || (overlap == best!.overlap && distance < best!.distance) {
                best = (s, overlap, distance)
            }
            s = s.addingTimeInterval(5 * 60)
        }
        guard let b = best else { return nil }
        return RoutineBlock(id: "\(meal.id)@\(key(day))", kind: meal.kind, title: meal.name, start: b.start,
                            end: b.start.addingTimeInterval(length),
                            window: DateInterval(start: calendar.date(minute: meal.windowStart, of: day), end: we),
                            location: settings.hallName, clashes: b.overlap > 0)
    }

    /// Every routine block on the day containing `day` (meals, reading, shutdown, and the
    /// sleep window that starts that evening).
    public func blocks(on day: Date, events: [CalendarEvent]) -> [RoutineBlock] {
        guard settings.enabled else { return [] }
        let d = calendar.startOfDay(day)
        var out = settings.meals.compactMap { placeMeal($0, on: d, events: events) }
        if settings.shutdownEnabled {
            let s = calendar.date(minute: settings.shutdownTime, of: d)
            out.append(RoutineBlock(id: "shutdown@\(key(d))", kind: .shutdown, title: "Shutdown ritual", start: s,
                                    end: s.addingTimeInterval(120)))
        }
        if settings.readingEnabled {
            let s = calendar.date(minute: settings.readingStart, of: d)
            out.append(RoutineBlock(id: "reading@\(key(d))", kind: .reading, title: settings.readingTitle, start: s,
                                    end: s.addingTimeInterval(Double(settings.readingMinutes) * 60)))
        }
        if settings.protectSleep {
            let sleep = sleepInterval(startingOn: d)
            out.append(RoutineBlock(id: "sleep@\(key(d))", kind: .sleep, title: "Sleep", start: sleep.start, end: sleep.end))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Routine blocks for every day overlapping [start, end).
    public func blocks(from start: Date, to end: Date, events: [CalendarEvent]) -> [RoutineBlock] {
        // Include the evening before so its sleep window covers this morning.
        calendar.dayStarts(from: calendar.addingDays(-1, to: start), to: end)
            .flatMap { blocks(on: $0, events: events) }
            .filter { $0.end > start && $0.start < end }
    }

    /// Bedtime on `day` to wake time the next morning.
    public func sleepInterval(startingOn day: Date) -> DateInterval {
        let bed = calendar.date(minute: settings.bedtime, of: day)
        var wake = calendar.date(minute: settings.wakeTime, of: day)
        if wake <= bed { wake = calendar.date(minute: settings.wakeTime, of: calendar.addingDays(1, to: day)) }
        return DateInterval(start: bed, end: wake)
    }

    /// True when `date` is inside a sleep window.
    public func isSleeping(at date: Date) -> Bool {
        guard settings.enabled, settings.protectSleep else { return false }
        let d = calendar.startOfDay(date)
        return [calendar.addingDays(-1, to: d), d].contains { day in
            let s = sleepInterval(startingOn: day)
            return date >= s.start && date < s.end
        }
    }

    /// Travel to and from campus events, as busy time for work done at the hall. A short gap
    /// between two campus events (≤ `campusGapMinutes`) is not a trip home, so only walking
    /// time is blocked around it and the gap stays usable for on-campus work.
    public func travelIntervals(events: [CalendarEvent]) -> [DateInterval] {
        guard settings.enabled else { return [] }
        let t = settings.travel
        let campus = events.filter { $0.isBusy && !$0.isAllDay && $0.end > $0.start && t.place(of: $0) == .campus }
            .sorted { $0.start < $1.start }
        var out: [DateInterval] = []
        for (i, e) in campus.enumerated() {
            let prev = i > 0 ? campus[i - 1] : nil
            let next = i + 1 < campus.count ? campus[i + 1] : nil
            let shortBefore = prev.map { e.start.timeIntervalSince($0.end) <= Double(t.campusGapMinutes) * 60 } ?? false
            let shortAfter = next.map { $0.start.timeIntervalSince(e.end) <= Double(t.campusGapMinutes) * 60 } ?? false
            let before = Double(shortBefore ? t.walkMinutes : t.travelMinutes) * 60
            let after = Double(shortAfter ? t.walkMinutes : t.travelMinutes) * 60
            out.append(DateInterval(start: e.start.addingTimeInterval(-before), end: e.start))
            out.append(DateInterval(start: e.end, end: e.end.addingTimeInterval(after)))
        }
        return out
    }

    /// Everything the scheduler must keep free over [start, end): routine blocks and travel.
    public func busyIntervals(from start: Date, to end: Date, events: [CalendarEvent]) -> [DateInterval] {
        guard settings.enabled else { return [] }
        let routine = blocks(from: start, to: end, events: events).map(\.interval)
        return IntervalMath.merge(routine + travelIntervals(events: events).filter { $0.end > start && $0.start < end })
    }

    /// Where a piece of work at `interval` happens: on campus when it sits in a short gap
    /// between campus events, otherwise at the hall.
    public func locationHint(for interval: DateInterval, events: [CalendarEvent]) -> String {
        let t = settings.travel
        let campus = events.filter { $0.isBusy && !$0.isAllDay && t.place(of: $0) == .campus }
        let gap = Double(t.campusGapMinutes) * 60
        let before = campus.filter { $0.end <= interval.start }.max { $0.end < $1.end }
        let after = campus.filter { $0.start >= interval.end }.min { $0.start < $1.start }
        if let b = before, let a = after, calendar.isSameDay(b.end, a.start), a.start.timeIntervalSince(b.end) <= gap {
            return "\(t.campusStudySpot) (on campus)"
        }
        return settings.hallName
    }
}

extension RoutineBlock {
    /// "Dinner closes 19:30".
    public func closesLine(calendar: DayCalendar) -> String? {
        guard let w = window else { return nil }
        return "\(title) closes \(calendar.time(w.end))"
    }
}
