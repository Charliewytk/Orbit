import Foundation

/// Something with a deadline worth nagging about.
public struct DeadlineItem: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case assessment, homework, task }

    public var id: String
    public var kind: Kind
    public var title: String
    public var moduleCode: String?
    public var due: Date
    /// Submitted / done.
    public var done: Bool
    /// The next concrete step, e.g. "Draft the conclusion (45 min)".
    public var nextStep: String?
    public var weightPercent: Double?

    public init(id: String, kind: Kind, title: String, moduleCode: String? = nil, due: Date, done: Bool = false,
                nextStep: String? = nil, weightPercent: Double? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.moduleCode = moduleCode; self.due = due
        self.done = done; self.nextStep = nextStep; self.weightPercent = weightPercent
    }
}

/// Minutes after midnight; quiet hours can wrap past midnight (23:00–08:00).
public struct QuietHours: Codable, Hashable, Sendable {
    public var start: MinuteOfDay
    public var end: MinuteOfDay
    public var enabled: Bool

    public init(start: MinuteOfDay = 23 * 60, end: MinuteOfDay = 8 * 60, enabled: Bool = true) {
        self.start = start; self.end = end; self.enabled = enabled
    }

    public func contains(_ minute: MinuteOfDay) -> Bool {
        guard enabled, start != end else { return false }
        return start < end ? (minute >= start && minute < end) : (minute >= start || minute < end)
    }
}

public struct DeadlineAlert: Codable, Hashable, Sendable, Identifiable {
    public enum Level: Int, Codable, CaseIterable, Comparable, Sendable {
        case h72 = 72, h24 = 24, h3 = 3, h1 = 1
        public var hours: Int { rawValue }
        public static func < (a: Level, b: Level) -> Bool { a.rawValue > b.rawValue } // later alerts are "greater"
    }

    /// De-duplication key: item, level and the due time (a moved deadline alerts again).
    public var id: String
    public var itemID: String
    public var level: Level
    public var fireAt: Date
    public var title: String
    public var body: String
}

/// Works out deadline notifications: 72 h, 24 h and 3 h before, plus 1 h if still
/// not submitted. Tone escalates; each alert names the next concrete step.
/// Alerts that would land in quiet hours move to the end of quiet hours, or to
/// just before quiet hours start if that would be after the deadline.
public struct DeadlineAlertPlanner: Sendable {
    public var quietHours: QuietHours
    public var timeZone: TimeZone
    public var levels: [DeadlineAlert.Level]

    public init(quietHours: QuietHours = QuietHours(), timeZone: TimeZone = TimeZone(identifier: "Europe/London")!,
                levels: [DeadlineAlert.Level] = DeadlineAlert.Level.allCases) {
        self.quietHours = quietHours; self.timeZone = timeZone; self.levels = levels
    }

    var cal: DayCalendar { DayCalendar(timeZone: timeZone) }

    public static func key(_ item: DeadlineItem, _ level: DeadlineAlert.Level) -> String {
        "deadline|\(item.id)|\(level.rawValue)|\(Int(item.due.timeIntervalSince1970))"
    }

    /// Nominal time moved out of quiet hours.
    public func fireTime(for due: Date, level: DeadlineAlert.Level) -> Date {
        let nominal = due.addingTimeInterval(-Double(level.hours) * 3600)
        let minute = cal.minuteOfDay(nominal)
        guard quietHours.contains(minute) else { return nominal }
        // End of this quiet stretch.
        let day = cal.startOfDay(nominal)
        let endDay = (quietHours.start > quietHours.end && minute >= quietHours.start) ? cal.addingDays(1, to: day) : day
        let quietEnd = cal.date(minute: quietHours.end, of: endDay)
        if quietEnd < due { return quietEnd }
        // Otherwise just before quiet hours began.
        let startDay = (quietHours.start > quietHours.end && minute < quietHours.end) ? cal.addingDays(-1, to: day) : day
        return cal.date(minute: quietHours.start, of: startDay).addingTimeInterval(-60)
    }

    /// Every alert for the items (for display / tests).
    public func schedule(_ items: [DeadlineItem]) -> [DeadlineAlert] {
        items.filter { !$0.done }.flatMap { item in
            levels.map { level in
                DeadlineAlert(id: Self.key(item, level), itemID: item.id, level: level,
                              fireAt: fireTime(for: item.due, level: level), title: title(item, level), body: body(item, level))
            }
        }.sorted { $0.fireAt < $1.fireAt }
    }

    /// Alerts to post now. Only the most urgent due alert per item fires; earlier
    /// levels that were skipped (item added late, Mac asleep) are marked as sent
    /// too via `alsoMarkSent`. Nothing fires during quiet hours or after the deadline.
    public func due(_ items: [DeadlineItem], now: Date, sent: Set<String>) -> (alerts: [DeadlineAlert], alsoMarkSent: [String]) {
        guard !quietHours.contains(cal.minuteOfDay(now)) else { return ([], []) }
        var alerts: [DeadlineAlert] = []
        var marks: [String] = []
        for item in items where !item.done && item.due > now {
            let ready = levels.filter { fireTime(for: item.due, level: $0) <= now }
                .filter { !sent.contains(Self.key(item, $0)) }
            guard let latest = ready.max() else { continue }
            // Nothing to send if a more urgent one already went out.
            if levels.contains(where: { $0 > latest && sent.contains(Self.key(item, $0)) }) {
                marks += ready.map { Self.key(item, $0) }
                continue
            }
            alerts.append(DeadlineAlert(id: Self.key(item, latest), itemID: item.id, level: latest, fireAt: now,
                                        title: title(item, latest), body: body(item, latest)))
            marks += ready.filter { $0 != latest }.map { Self.key(item, $0) }
        }
        return (alerts.sorted { $0.level > $1.level }, marks)
    }

    // MARK: Wording

    func name(_ item: DeadlineItem) -> String {
        (item.moduleCode.map { "\($0) " } ?? "") + item.title
    }

    public func title(_ item: DeadlineItem, _ level: DeadlineAlert.Level) -> String {
        switch level {
        case .h72: "Coming up: \(name(item))"
        case .h24: "Due tomorrow: \(name(item))"
        case .h3: "Due in 3 hours: \(name(item))"
        case .h1: "1 hour left: \(name(item))"
        }
    }

    public func body(_ item: DeadlineItem, _ level: DeadlineAlert.Level) -> String {
        let when = "Due \(cal.format(item.due, "EEE d MMM 'at' HH:mm"))."
        let step = item.nextStep.map { "Next step: \($0)." }
        let submit = item.kind == .assessment ? "Submit on ELE and check you get the receipt email." : "Finish it and tick it off."
        switch level {
        case .h72:
            return [when, step ?? "Plan when you'll work on it.", "You've got time; a block today keeps it calm."].joined(separator: " ")
        case .h24:
            return [when, step ?? "Block out time today to finish it."].joined(separator: " ")
        case .h3:
            return ["Due at \(cal.time(item.due)).", step ?? "Stop other work and finish this now.", item.kind == .assessment ? "Leave 30 minutes to submit." : nil]
                .compactMap { $0 }.joined(separator: " ")
        case .h1:
            return ["Due at \(cal.time(item.due)) and not marked as submitted.", submit].joined(separator: " ")
        }
    }
}
