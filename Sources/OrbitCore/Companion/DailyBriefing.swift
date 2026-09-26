import Foundation

/// Weather from Open-Meteo (free, no key).
public struct WeatherToday: Codable, Hashable, Sendable {
    public var place: String
    public var currentC: Double?
    public var highC: Double
    public var lowC: Double
    public var rainChance: Int
    public var code: Int
    public var description: String { OpenMeteo.describe(code) }
    public var symbol: String { OpenMeteo.symbol(code) }

    /// "Light rain, 9–14°C, 70% chance of rain. Take a coat."
    public var line: String {
        var s = "\(description), \(Int(lowC.rounded()))–\(Int(highC.rounded()))°C"
        if rainChance >= 20 { s += ", \(rainChance)% chance of rain" }
        if rainChance >= 50 { s += ". Take a coat or umbrella" }
        return s + "."
    }
}

public enum OpenMeteo {
    public static let exeter = (latitude: 50.7236, longitude: -3.5275, name: "Exeter")

    public static func forecastURL(latitude: Double = exeter.latitude, longitude: Double = exeter.longitude) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(latitude)), .init(name: "longitude", value: String(longitude)),
            .init(name: "current", value: "temperature_2m,weather_code"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "timezone", value: "Europe/London"), .init(name: "forecast_days", value: "1"),
        ]
        return c.url!
    }

    struct Response: Decodable {
        struct Current: Decodable { var temperature_2m: Double?; var weather_code: Int? }
        struct Daily: Decodable {
            var weather_code: [Int]?; var temperature_2m_max: [Double]?; var temperature_2m_min: [Double]?
            var precipitation_probability_max: [Int?]?
        }
        var current: Current?
        var daily: Daily?
    }

    public static func parse(_ data: Data, place: String = exeter.name) -> WeatherToday? {
        guard let r = try? JSONDecoder().decode(Response.self, from: data), let d = r.daily,
              let hi = d.temperature_2m_max?.first, let lo = d.temperature_2m_min?.first else { return nil }
        return WeatherToday(place: place, currentC: r.current?.temperature_2m, highC: hi, lowC: lo,
                            rainChance: (d.precipitation_probability_max?.first ?? nil) ?? 0,
                            code: d.weather_code?.first ?? r.current?.weather_code ?? 0)
    }

    /// WMO weather codes.
    public static func describe(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55, 56, 57: "Drizzle"
        case 61, 66: "Light rain"
        case 63: "Rain"
        case 65, 67: "Heavy rain"
        case 71, 73, 75, 77: "Snow"
        case 80, 81: "Showers"
        case 82: "Heavy showers"
        case 85, 86: "Snow showers"
        case 95, 96, 99: "Thunderstorms"
        default: "Mixed"
        }
    }

    public static func symbol(_ code: Int) -> String {
        switch code {
        case 0, 1: "sun.max.fill"
        case 2: "cloud.sun.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.sun.fill"
        }
    }
}

/// The wake-up briefing: notification, Home card and full screen all read this.
public struct DailyBriefing: Codable, Hashable, Sendable {
    public struct NewItem: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var source: String
        public var title: String
        public var moduleCode: String?
        public var url: String?
        public init(id: String, source: String, title: String, moduleCode: String? = nil, url: String? = nil) {
            self.id = id; self.source = source; self.title = title; self.moduleCode = moduleCode; self.url = url
        }
    }

    public var day: Date
    public var generatedAt: Date
    public var weather: WeatherToday?
    public var brief: MorningBrief
    public var newOnELE: [NewItem]
    public var keyEmail: EmailDigest?
    public var streakDays: Int
    public var flashcardStreak: Int
    public var news: [LinkedStory]
    /// Filled on Saturdays.
    public var weeklyReview: WeekRecap?
    public var groupTasksDue: [String]
    public var examLine: String?

    public init(day: Date, generatedAt: Date, weather: WeatherToday?, brief: MorningBrief, newOnELE: [NewItem],
                keyEmail: EmailDigest?, streakDays: Int, flashcardStreak: Int, news: [LinkedStory],
                weeklyReview: WeekRecap?, groupTasksDue: [String], examLine: String?) {
        self.day = day; self.generatedAt = generatedAt; self.weather = weather; self.brief = brief
        self.newOnELE = newOnELE; self.keyEmail = keyEmail; self.streakDays = streakDays
        self.flashcardStreak = flashcardStreak; self.news = news; self.weeklyReview = weeklyReview
        self.groupTasksDue = groupTasksDue; self.examLine = examLine
    }

    public var isSaturday: Bool { brief.calendar.weekday(day) == 7 }

    public var notificationTitle: String {
        let cal = brief.calendar
        return "Good morning — \(cal.format(day, "EEEE d MMM"))"
    }

    /// Short body for the notification.
    public var notificationBody: String {
        var parts: [String] = []
        if let w = weather { parts.append(w.line) }
        let cal = brief.calendar
        if let first = brief.events.first { parts.append("First: \(first.title) at \(cal.time(first.start)).") }
        else { parts.append("No lectures or events today.") }
        if !brief.dueSoon.isEmpty { parts.append("\(brief.dueSoon.count) due this week.") }
        if !newOnELE.isEmpty { parts.append("\(newOnELE.count) new on ELE/Ed.") }
        if streakDays > 1 { parts.append("\(streakDays)-day streak.") }
        if weeklyReview != nil { parts.append("Weekly review inside.") }
        return parts.joined(separator: " ")
    }

    /// Plain text for the assistant, the briefing screen's fallback and a narration prompt.
    public func plainText() -> String {
        var lines: [String] = []
        if let w = weather { lines.append("Weather in \(w.place): \(w.line)") }
        lines.append(brief.plainSummary())
        if let e = examLine { lines.append(e) }
        if !groupTasksDue.isEmpty { lines.append("Group work: " + groupTasksDue.joined(separator: "; ") + ".") }
        if !newOnELE.isEmpty { lines.append("New on ELE/Ed: " + newOnELE.prefix(6).map { "\($0.source): \($0.title)" }.joined(separator: "; ") + ".") }
        if let k = keyEmail { lines.append("Key email: \(k.subject) from \(k.from)" + (k.summary.isEmpty ? "." : ": \(k.summary)")) }
        lines.append("Streak: \(streakDays) day\(streakDays == 1 ? "" : "s").")
        for n in news { lines.append("News (\(n.story.source)): \(n.story.title). \(n.angle)") }
        if let r = weeklyReview { lines.append("Weekly review:\n" + r.plainText()) }
        return lines.joined(separator: "\n")
    }

    /// The one email most worth reading today.
    public static func keyEmail(_ emails: [EmailDigest], now: Date) -> EmailDigest? {
        let rank: [EmailCategory: Double] = [.urgent: 3, .needsReply: 2, .hasDate: 1.5, .uni: 1]
        return emails.filter { $0.category != .ignore && now.timeIntervalSince($0.date) < 2 * 86400 }
            .max { a, b in
                let sa = (rank[a.category] ?? 0) + a.importance, sb = (rank[b.category] ?? 0) + b.importance
                return sa != sb ? sa < sb : a.date < b.date
            }
    }
}

/// When the briefing fires. Default 07:35 every day (weekends are work days).
public struct BriefingSchedule: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var minute: MinuteOfDay
    public init(enabled: Bool = true, minute: MinuteOfDay = 7 * 60 + 35) { self.enabled = enabled; self.minute = minute }

    public func fireDate(on day: Date, calendar: DayCalendar) -> Date { calendar.date(minute: minute, of: day) }

    /// True once today's time has passed and the briefing hasn't been made for today.
    public func isDue(now: Date, lastDay: Date?, calendar: DayCalendar) -> Bool {
        guard enabled, now >= fireDate(on: now, calendar: calendar) else { return false }
        return lastDay.map { !calendar.isSameDay($0, now) } ?? true
    }

    public func next(after now: Date, calendar: DayCalendar) -> Date {
        let today = fireDate(on: now, calendar: calendar)
        return today > now ? today : fireDate(on: calendar.addingDays(1, to: now), calendar: calendar)
    }
}
