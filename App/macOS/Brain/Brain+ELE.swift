import Foundation
import SwiftData
import OrbitCore

extension OrbitBrain {
    /// ELE through the website session (normal path), else a legacy Moodle-app token, else the calendar export.
    func syncELE() async {
        guard begin(.ele) else { return }
        defer { end(.ele) }
        if accounts.eleWebSignedIn {
            await syncELEWeb()
        } else if let credentials = accounts.moodle {
            await syncMoodle(credentials)
        } else if let s = MacPrefs.string(MacPrefs.eleCalendarURL), let url = URL(string: s) {
            await syncELEFeed(url)
        }
    }

    private func syncMoodle(_ credentials: MoodleCredentials) async {
        do {
            var options = ELESync.Options()
            options.fetchReadingLists = true
            options.creditsByModule = Dictionary(context.all(StoredModule.self).filter(\.creditsEdited).map { ($0.id, $0.credits) },
                                                 uniquingKeysWith: { a, _ in a })
            let sync = ELESync(client: MoodleClient(credentials: credentials), options: options, lastSnapshot: eleSnapshot)
            let (snapshot, changes) = try await sync.sync(previous: eleSnapshot)
            eleSnapshot = snapshot
            local.save(snapshot, "ele-snapshot.json")
            apply(snapshot)
            if !changes.isInitial { announce(changes) }
            if !changes.isEmpty { scheduleReplan(after: 2) }
            let warn = snapshot.warnings.isEmpty ? "" : " (\(snapshot.warnings.count) warnings)"
            record(.ele, detail: "\(snapshot.modules.count) modules, \(snapshot.assessments.count) assessments\(warn)")
        } catch let error as MoodleError where error.needsReauthentication {
            // Advisory says: cookie session expiry → silent re-auth + alert + auto-retry.
            // Actual implementation uses Moodle mobile token (stored in KeychainBlob "ele"), not a browser cookie.
            // Token invalidation → user must re-sign in from Settings. No auto cookie renewal is wired.
            // This is tracked as a gap vs the requested “auto-renew on sign-in expiry” behaviour.
            record(.ele, error: "ELE sign-in expired. Reconnect ELE in Settings. (No auto cookie renewal — token must be re-issued.)")
            notify(id: "ele-signed-out-\(DayCalendar(timeZone: prefs.timeZone).format(Date(), "yyyy-MM-dd"))",
                   title: "ELE signed out", body: "Reconnect ELE in Settings to resume sync.", category: "ele")
        } catch {
            record(.ele, error: "ELE: \(error)")
        }
    }

    private func syncELEFeed(_ url: URL) async {
        do {
            let codes = context.all(StoredModule.self).map(\.id)
            let result = try await ELECalendarFeed(url: url).fetch(knownModuleCodes: codes)
            let index = context.indexed(StoredAssessment.self)
            for a in result.assessments {
                if let existing = index[a.id] { existing.apply(a) } else { context.insert(StoredAssessment(assessment: a)) }
            }
            let modules = context.indexed(StoredModule.self)
            for code in Set(result.assessments.map(\.moduleCode)) where !code.isEmpty && modules[code] == nil {
                context.insert(StoredModule(module: Module(code: code, name: code)))
            }
            context.saveQuietly()
            let covered = Set(result.events.map(\.calendarID)).union(["ele"])
            let cal = DayCalendar(timeZone: prefs.timeZone)
            applyEvents(result.events, covered: covered, from: cal.addingDays(-8, to: Date()), to: cal.addingDays(60, to: Date()))
            record(.ele, detail: "\(result.assessments.count) deadlines from the ELE calendar feed")
        } catch {
            record(.ele, error: "ELE calendar feed: \(error)")
        }
    }

    /// Copies an ELE snapshot into the synced store, keeping what the student edited.
    func apply(_ snapshot: ELESnapshot) {
        let modules = context.indexed(StoredModule.self)
        for m in snapshot.modules {
            if let existing = modules[m.code] { existing.apply(m) } else { context.insert(StoredModule(module: m)) }
        }
        let assessments = context.indexed(StoredAssessment.self)
        for a in snapshot.assessments {
            if let existing = assessments[a.id] { existing.apply(a) } else { context.insert(StoredAssessment(assessment: a)) }
        }
        for g in snapshot.grades where !g.isCourseTotal {
            if let id = g.assessmentID, let a = assessments[id], a.mark == nil { a.mark = g.percent }
        }
        let readings = context.indexed(StoredReading.self)
        for r in snapshot.readingItems {
            if let existing = readings[r.id] { existing.apply(r) } else { context.insert(StoredReading(reading: r)) }
        }
        let posts = context.indexed(StoredAnnouncement.self)
        for a in snapshot.announcements {
            if let existing = posts[a.id] { existing.apply(a) } else { context.insert(StoredAnnouncement(announcement: a)) }
        }
        context.saveQuietly()
    }

    func announce(_ changes: ELEChanges) {
        let cal = DayCalendar(timeZone: prefs.timeZone)
        for a in changes.newAssessments.prefix(5) {
            let due = a.due.map { " · due \(Fmt.dayTime($0, cal))" } ?? ""
            notify(id: "ele-new-\(a.id)", title: "📚 New on ELE: \(a.moduleCode)", body: "\(a.title)\(due)", category: "ele")
        }
        for c in changes.changedDeadlines.prefix(5) {
            let new = c.newDue.map { Fmt.dayTime($0, cal) } ?? "no date"
            notify(id: "ele-moved-\(c.assessment.id)-\(Int(c.newDue?.timeIntervalSince1970 ?? 0))",
                   title: "📅 Deadline changed: \(c.assessment.moduleCode)", body: "\(c.assessment.title) is now \(new)", category: "ele")
        }
        for g in changes.newGrades.prefix(5) where !g.isCourseTotal {
            notify(id: "ele-grade-\(g.id)-\(Int(g.percent))", title: "🎓 New mark: \(g.moduleCode)",
                   body: "\(g.itemName): \(Int(g.percent.rounded()))%", category: "ele")
        }
        for a in changes.newAnnouncements.prefix(3) {
            notify(id: "ele-post-\(a.id)", title: "📣 \(a.moduleCode)", body: a.subject, category: "ele")
        }
    }

    /// Revision topics for an exam: ELE section names, then lecture-note titles.
    func revisionTopics(moduleCode: String) -> [String] {
        var topics = RevisionPlanner.topics(fromSections: eleSnapshot?.sectionTopics[moduleCode] ?? [])
        if topics.count < 3 {
            topics += RevisionPlanner.topics(fromNotes: local.allNotes(), moduleCode: moduleCode)
                .filter { t in !topics.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
        }
        return topics
    }
}
