import Foundation

/// What a backup zip contains (manifest.json at its root).
public struct BackupManifest: Codable, Hashable, Sendable {
    public var formatVersion: Int
    public var createdAt: Date
    public var appVersion: String
    public var hostName: String
    /// Relative paths inside the zip → bytes.
    public var files: [String: Int]
    /// Record counts per section ("tasks": 120).
    public var counts: [String: Int]
    public var includesTypedNotes: Bool
    public var includesKnowledgeBase: Bool

    public init(formatVersion: Int = 1, createdAt: Date, appVersion: String, hostName: String, files: [String: Int] = [:],
                counts: [String: Int] = [:], includesTypedNotes: Bool, includesKnowledgeBase: Bool) {
        self.formatVersion = formatVersion; self.createdAt = createdAt; self.appVersion = appVersion; self.hostName = hostName
        self.files = files; self.counts = counts; self.includesTypedNotes = includesTypedNotes
        self.includesKnowledgeBase = includesKnowledgeBase
    }
}

/// A backup file found in the destination folder.
public struct BackupFile: Hashable, Sendable {
    public var name: String
    public var date: Date
    public init(name: String, date: Date) { self.name = name; self.date = date }
}

/// Nightly backup timing, naming, destination choice and retention (14 dailies + 8 weeklies).
public struct BackupPlanner: Sendable {
    public var calendar: DayCalendar
    public var hour: Int
    public var keepDaily: Int
    public var keepWeekly: Int

    public init(calendar: DayCalendar = DayCalendar(), hour: Int = 3, keepDaily: Int = 14, keepWeekly: Int = 8) {
        self.calendar = calendar; self.hour = hour; self.keepDaily = keepDaily; self.keepWeekly = keepWeekly
    }

    public static let prefix = "Orbit Backup "

    /// "Orbit Backup 2026-09-26 0300.zip".
    public func fileName(for date: Date) -> String { "\(Self.prefix)\(calendar.format(date, "yyyy-MM-dd HHmm")).zip" }

    /// Parses a name made by `fileName(for:)`; other files are ignored.
    public func parse(_ name: String) -> BackupFile? {
        guard name.hasPrefix(Self.prefix), name.hasSuffix(".zip") else { return nil }
        let stamp = name.dropFirst(Self.prefix.count).dropLast(4)
        let parts = stamp.split(separator: " ")
        let ymd = parts.first?.split(separator: "-").compactMap { Int($0) } ?? []
        guard ymd.count == 3 else { return nil }
        var h = 0, m = 0
        if parts.count > 1, let hm = Int(parts[1]), parts[1].count == 4 { h = hm / 100; m = hm % 100 }
        guard let d = calendar.date(year: ymd[0], month: ymd[1], day: ymd[2], hour: h, minute: m) else { return nil }
        return BackupFile(name: name, date: d)
    }

    /// The most recent scheduled time at or before `now` (today 03:00, else yesterday's).
    public func lastScheduled(before now: Date) -> Date {
        let today = calendar.date(minute: hour * 60, of: now)
        return today <= now ? today : calendar.date(minute: hour * 60, of: calendar.addingDays(-1, to: now))
    }

    /// Due when no backup has been made since the last scheduled time (covers a missed 03:00 on next launch).
    public func isDue(now: Date, lastBackup: Date?) -> Bool {
        guard let last = lastBackup else { return true }
        return last < lastScheduled(before: now)
    }

    /// Files to delete: keeps the newest backup of each of the last `keepDaily` days, plus the
    /// newest backup of each of the `keepWeekly` most recent weeks older than those.
    public func toDelete(_ files: [BackupFile]) -> [BackupFile] {
        let sorted = files.sorted { $0.date > $1.date }
        var keep = Set<String>()
        var days: [String] = []
        var weeks: [Date] = []
        for f in sorted {
            let day = calendar.format(f.date, "yyyy-MM-dd")
            if days.contains(day) { continue }
            if days.count < keepDaily {
                days.append(day)
                keep.insert(f.name)
                continue
            }
            let week = calendar.startOfWeek(f.date)
            // Weeks already represented by a daily don't need a weekly.
            let dailyWeeks = Set(sorted.filter { keep.contains($0.name) }.map { calendar.startOfWeek($0.date) })
            if dailyWeeks.contains(week) || weeks.contains(week) { continue }
            if weeks.count < keepWeekly {
                weeks.append(week)
                keep.insert(f.name)
            }
        }
        return sorted.filter { !keep.contains($0.name) }
    }

    /// Picks where backups go: Google Drive for Desktop ("My Drive"), then OneDrive, then ~/Documents.
    /// `cloudStorage` lists the folder names in ~/Library/CloudStorage.
    public static func destination(home: String, cloudStorage: [String], exists: (String) -> Bool) -> (path: String, label: String) {
        let base = home + "/Library/CloudStorage/"
        for name in cloudStorage.sorted() where name.hasPrefix("GoogleDrive-") {
            for drive in ["My Drive", "Mon Drive", "Meine Ablage"] where exists(base + name + "/" + drive) {
                return (base + name + "/" + drive + "/Orbit Backups", "Google Drive")
            }
        }
        for name in cloudStorage.sorted() where name.hasPrefix("OneDrive") {
            return (base + name + "/Orbit Backups", "OneDrive")
        }
        return (home + "/Documents/Orbit Backups", "Documents")
    }
}
