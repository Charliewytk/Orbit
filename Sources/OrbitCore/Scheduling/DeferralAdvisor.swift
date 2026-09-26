import Foundation

/// One "Move to later" for a task or block.
public struct DeferralRecord: Codable, Hashable, Sendable {
    public var movedAt: Date
    public var from: Date?
    public var to: Date
    /// True when Orbit pushed back and the user moved it anyway.
    public var overrodeWarning: Bool

    public init(movedAt: Date, from: Date?, to: Date, overrodeWarning: Bool = false) {
        self.movedAt = movedAt; self.from = from; self.to = to; self.overrodeWarning = overrodeWarning
    }
}

/// The thing being moved.
public struct DeferralItem: Hashable, Sendable {
    public var title: String
    /// Length of the block being moved (or the next chunk of the task).
    public var blockMinutes: Int
    /// Work left on the whole task.
    public var remainingMinutes: Int
    public var deadline: Date?
    public var origin: TaskOrigin
    /// When it is currently planned (nil for an unscheduled task).
    public var currentStart: Date?
    public var history: [DeferralRecord]

    public init(title: String, blockMinutes: Int, remainingMinutes: Int, deadline: Date? = nil,
                origin: TaskOrigin = .yours, currentStart: Date? = nil, history: [DeferralRecord] = []) {
        self.title = title; self.blockMinutes = max(5, blockMinutes); self.remainingMinutes = max(0, remainingMinutes)
        self.deadline = deadline; self.origin = origin; self.currentStart = currentStart; self.history = history
    }

    public var timesMoved: Int { history.count }
}

/// A quick option in the "Later" menu.
public struct DeferralOption: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case inAnHour, thisEvening, tomorrow, nextFreeSlot }
    public var kind: Kind
    public var label: String
    public var start: Date
    public var id: String { kind.rawValue }
}

/// Why Orbit is pushing back.
public enum DeferralReason: Hashable, Sendable {
    case movedRepeatedly(times: Int)
    case deadlineTight(deadline: Date, remainingMinutes: Int, freeMinutesBeforeDeadline: Int)
    case pastDeadline(deadline: Date)
    case dayFull(day: Date, bookedMinutes: Int)
    case slotBusy(start: Date)
}

public struct DeferralAssessment: Hashable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        /// Fine, just move it.
        case ok
        /// Show the reason, one tap to move anyway.
        case caution
        /// Show the reason and lead with the better slot; moving anyway needs a deliberate "Move anyway".
        case resist
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public var level: Level
    public var reasons: [DeferralReason]
    /// One line per reason, e.g. "You've moved this 3 times".
    public var messages: [String]
    /// A better slot, when there is one.
    public var suggestion: Date?
    public var suggestionLabel: String?
    public var target: Date

    public var headline: String? { messages.first }
}

/// Decides whether "Move to later" is a good idea and offers a better slot.
///
/// Pushes back when:
/// - the item has already been moved 3 times (2 for required uni work),
/// - the deadline is close relative to the work left (free time between the
///   new slot and the deadline is under 1.5× the remaining work; 2× for required),
/// - the target day is overloaded (booked time ≥ `maxFocusMinutesPerDay`, or no
///   free slot long enough), or the target slot itself clashes.
///
/// Required items push back one level harder. The user can always override.
public struct DeferralAdvisor: Sendable {
    public var prefs: UserPrefs
    public var finder: FreeSlotFinder
    public var calendar: DayCalendar { finder.calendar }

    public init(prefs: UserPrefs) {
        self.prefs = prefs
        self.finder = FreeSlotFinder(prefs: prefs)
    }

    // MARK: Options

    /// "In 1 hour", "This evening", "Tomorrow morning", and the next free slot that fits.
    public func options(for item: DeferralItem, now: Date, events: [CalendarEvent],
                        blocked: [DateInterval] = []) -> [DeferralOption] {
        var out: [DeferralOption] = []
        let inHour = IntervalMath.roundUp5(now.addingTimeInterval(3600))
        out.append(DeferralOption(kind: .inAnHour, label: "In 1 hour", start: inHour))
        let evening = calendar.date(minute: max(prefs.dinner?.upperBound ?? 19 * 60 + 15, 19 * 60), of: now)
        if evening > inHour, calendar.minuteOfDay(evening) + item.blockMinutes <= prefs.dayEnd {
            out.append(DeferralOption(kind: .thisEvening, label: "This evening", start: evening))
        }
        let tomorrow = calendar.addingDays(1, to: calendar.startOfDay(now))
        let tomorrowStart = firstFit(item.blockMinutes, from: calendar.date(minute: prefs.dayStart, of: tomorrow),
                                     to: calendar.endOfDay(tomorrow), events: events, blocked: blocked)
            ?? calendar.date(minute: prefs.dayStart + 60, of: tomorrow)
        out.append(DeferralOption(kind: .tomorrow, label: "Tomorrow \(calendar.time(tomorrowStart))", start: tomorrowStart))
        if let next = firstFit(item.blockMinutes, from: inHour, to: calendar.addingDays(7, to: now), events: events, blocked: blocked),
           !out.contains(where: { abs($0.start.timeIntervalSince(next)) < 1800 }) {
            out.append(DeferralOption(kind: .nextFreeSlot, label: "Next free: \(describe(next, now: now))", start: next))
        }
        return out
    }

    // MARK: Assessment

    public func assess(_ item: DeferralItem, to target: Date, now: Date, events: [CalendarEvent],
                       blocked: [DateInterval] = []) -> DeferralAssessment {
        let required = item.origin == .required
        var reasons: [DeferralReason] = []
        var score = 0

        // 1. Moved too often.
        let limit = required ? 2 : 3
        if item.timesMoved >= limit {
            reasons.append(.movedRepeatedly(times: item.timesMoved))
            score += item.timesMoved >= limit + 2 ? 2 : 1
        }

        // 2. Deadline pressure.
        if let deadline = item.deadline {
            let targetEnd = target.addingTimeInterval(TimeInterval(item.blockMinutes * 60))
            if targetEnd > deadline {
                reasons.append(.pastDeadline(deadline: deadline))
                score += 2
            } else {
                let free = freeMinutes(from: target, to: deadline, events: events, blocked: blocked)
                let factor = required ? 2.0 : 1.5
                let within48h = deadline.timeIntervalSince(now) < 48 * 3600
                if Double(free) < Double(item.remainingMinutes) * factor || (within48h && item.remainingMinutes >= 60) {
                    reasons.append(.deadlineTight(deadline: deadline, remainingMinutes: item.remainingMinutes,
                                                  freeMinutesBeforeDeadline: free))
                    score += free < item.remainingMinutes ? 2 : 1
                }
            }
        }

        // 3. Target day / slot.
        let booked = bookedMinutes(on: target, events: events, blocked: blocked)
        let dayFree = finder.freeSlots(on: target, events: events, blocked: blocked)
        let fitsDay = dayFree.contains { IntervalMath.minutes($0) >= item.blockMinutes }
        if booked >= prefs.maxFocusMinutesPerDay || !fitsDay {
            reasons.append(.dayFull(day: calendar.startOfDay(target), bookedMinutes: booked))
            score += 1
        } else if !slotIsFree(target, minutes: item.blockMinutes, events: events, blocked: blocked) {
            reasons.append(.slotBusy(start: target))
            score += 1
        }

        if required, score > 0 { score += 1 }
        let level: DeferralAssessment.Level = score == 0 ? .ok : score == 1 ? .caution : .resist
        let suggestion = level == .ok ? nil : betterSlot(for: item, target: target, now: now, events: events, blocked: blocked)
        return DeferralAssessment(level: level, reasons: reasons,
                                  messages: reasons.map { message($0, now: now, remaining: item.remainingMinutes) },
                                  suggestion: suggestion, suggestionLabel: suggestion.map { describe($0, now: now) },
                                  target: target)
    }

    /// Records a move on the history (call after the user confirms).
    public static func record(_ history: [DeferralRecord], from: Date?, to: Date, now: Date,
                              assessment: DeferralAssessment?) -> [DeferralRecord] {
        history + [DeferralRecord(movedAt: now, from: from, to: to, overrodeWarning: (assessment?.level ?? .ok) > .ok)]
    }

    // MARK: Helpers

    /// A slot that fits, isn't on an overloaded day, and (with a deadline) leaves enough time.
    /// With deadline pressure it looks from now; otherwise from the requested target.
    func betterSlot(for item: DeferralItem, target: Date, now: Date, events: [CalendarEvent],
                    blocked: [DateInterval]) -> Date? {
        let pressured = item.deadline.map { freeMinutes(from: target, to: $0, events: events, blocked: blocked)
            < Int(Double(item.remainingMinutes) * 1.5) } ?? false
        let from = pressured ? IntervalMath.roundUp5(now.addingTimeInterval(15 * 60)) : max(target, now)
        let horizon = item.deadline.map { $0.addingTimeInterval(-TimeInterval(item.blockMinutes * 60)) }
            ?? calendar.addingDays(14, to: from)
        guard horizon > from else { return nil }
        for day in finder.freeSlots(from: from, to: horizon.addingTimeInterval(TimeInterval(item.blockMinutes * 60)),
                                    events: events, blocked: blocked) where day.isWorkDay {
            guard bookedMinutes(on: day.day, events: events, blocked: blocked) < prefs.maxFocusMinutesPerDay else { continue }
            if let slot = day.slots.first(where: { IntervalMath.minutes($0) >= item.blockMinutes }),
               abs(slot.start.timeIntervalSince(target)) >= 15 * 60 {
                return slot.start
            }
        }
        return nil
    }

    func firstFit(_ minutes: Int, from: Date, to: Date, events: [CalendarEvent], blocked: [DateInterval]) -> Date? {
        finder.freeSlots(from: from, to: to, events: events, blocked: blocked)
            .flatMap(\.slots).first { IntervalMath.minutes($0) >= minutes }?.start
    }

    func freeMinutes(from: Date, to: Date, events: [CalendarEvent], blocked: [DateInterval]) -> Int {
        guard to > from else { return 0 }
        return finder.freeSlots(from: from, to: to, events: events, blocked: blocked).reduce(0) { $0 + $1.totalMinutes }
    }

    /// Busy minutes inside the working window of `day` (events + blocks, no buffers).
    public func bookedMinutes(on day: Date, events: [CalendarEvent], blocked: [DateInterval] = []) -> Int {
        guard let window = finder.workingWindow(for: day) else { return 0 }
        let busy = IntervalMath.merge(events.filter { $0.isBusy && !$0.isAllDay }.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
                                      + blocked)
        return busy.reduce(0) { total, i in
            let s = max(i.start, window.start), e = min(i.end, window.end)
            return total + (e > s ? Int(e.timeIntervalSince(s) / 60) : 0)
        }
    }

    func slotIsFree(_ start: Date, minutes: Int, events: [CalendarEvent], blocked: [DateInterval]) -> Bool {
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        return finder.freeSlots(on: start, events: events, blocked: blocked).contains { $0.start <= start && $0.end >= end }
    }

    func message(_ reason: DeferralReason, now: Date, remaining: Int) -> String {
        switch reason {
        case .movedRepeatedly(let n):
            return "You've moved this \(n) time\(n == 1 ? "" : "s")"
        case .deadlineTight(let deadline, let left, let free):
            let due = "Due \(relativeDay(deadline, now: now))"
            return free < left ? "\(due), \(Self.hours(left)) left of work but only \(Self.hours(free)) free before then"
                : "\(due), \(Self.hours(left)) left of work"
        case .pastDeadline(let deadline):
            return "That's after the deadline (\(relativeDay(deadline, now: now)) \(calendar.time(deadline)))"
        case .dayFull(let day, let booked):
            let name = relativeDay(day, now: now)
            return "\(name.prefix(1).uppercased() + name.dropFirst()) is full: \(Self.hours(booked)) booked"
        case .slotBusy(let start):
            return "You're busy at \(calendar.time(start))"
        }
    }

    /// "today", "tomorrow", "Thursday", "Mon 12 Oct".
    func relativeDay(_ date: Date, now: Date) -> String {
        switch calendar.days(from: now, to: date) {
        case 0: return "today"
        case 1: return "tomorrow"
        case 2...6: return calendar.format(date, "EEEE")
        default: return calendar.shortDay(date)
        }
    }

    func describe(_ date: Date, now: Date) -> String {
        let day = relativeDay(date, now: now)
        return "\(day) \(calendar.time(date))"
    }

    /// 90 → "1.5h", 120 → "2h", 45 → "45m".
    static func hours(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = Double(minutes) / 60
        return h == h.rounded() ? "\(Int(h))h" : String(format: "%.1fh", h)
    }
}
