import Foundation
import SwiftData
import OrbitCore

/// The light ELE sync (every 15 minutes while the Mac is awake): everything on the
/// student's ELE that changes day to day — notifications, messages, announcements
/// and forum posts, grades and marker feedback, "My Assessments", the timeline —
/// plus a cheap per-course "what changed?" check that triggers the full course sync
/// (pages, files, homework) early when something moved. All through the logged-in
/// web session's AJAX (lib/ajax/service.php), with HTML fallbacks.
extension OrbitBrain {
    static let liveLog = "ele-live"

    /// Runs the light sync unless one is already running or the full sync is busy.
    func syncELELive() async {
        guard accounts.eleWebSignedIn, !running.contains(.ele), !eleLiveRunning else { return }
        eleLiveRunning = true
        defer { eleLiveRunning = false }
        academicLoadIfNeeded()
        let started = Date()
        let web = accounts.eleWeb
        var found: [ELEActivityItem] = []
        var steps: [String] = []
        do {
            try await web.prepare()

            // Dashboard: user id and the "My Assessments" block.
            if let html = try? await web.fetchText(URL(string: "\(Self.eleSite)/my/")!) {
                if let id = ELELive.userID(inHTML: html) { academic.state.userID = id }
                let year = ELEWebParser.academicYearStart(for: Date(), timeZone: prefs.timeZone)
                let rows = ELELive.myAssessments(fromDashboardHTML: html, academicYear: year)
                if !rows.isEmpty { academic.knowledge.myAssessments = rows }
                steps.append("dashboard (\(rows.count) assessment rows)")
            }
            let userID = academic.state.userID ?? 0

            // Notifications (grading, feedback, forum posts, submissions…).
            if let data = try await liveAJAX("message_popup_get_popup_notifications",
                                             ["useridto": userID, "newestfirst": true, "limit": 30, "offset": 0], web: web) {
                let n = try ELELive.notifications(fromAJAX: data)
                found += ELELive.activity(notifications: n)
                steps.append("\(n.count) notifications")
            }

            // Messages.
            if userID > 0, let data = try await liveAJAX("core_message_get_conversations",
                                                          ["userid": userID, "limitfrom": 0, "limitnum": 20], web: web) {
                let c = try ELELive.conversations(fromAJAX: data)
                found += ELELive.activity(conversations: c)
                steps.append("\(c.count) conversations")
            }

            // Timeline: anything newly due.
            let from = Int(Date().addingTimeInterval(-86400).timeIntervalSince1970)
            if let data = try await liveAJAX("core_calendar_get_action_events_by_timesort",
                                             ["timesortfrom": from, "limitnum": 50, "limittononsuspendedevents": true], web: web) {
                let events = try ELEWebParser.events(fromAJAX: data)
                let codes = academic.knowledge.moduleCodesByCourseID
                found += events.map { e in
                    ELEActivityItem(id: "timeline-\(e.id)-\(Int(e.timesort.timeIntervalSince1970))", kind: .newAssessment,
                                    moduleCode: e.courseID.flatMap { codes[$0] }, title: "On your timeline: \(e.name)",
                                    detail: "due \(Fmt.dayTime(e.timesort, DayCalendar(timeZone: prefs.timeZone)))",
                                    date: Date(), url: e.url, important: false)
                }
                steps.append("\(events.count) timeline events")
            }

            let courses = academic.knowledge.modules.values.compactMap { m in m.courseID.map { (id: $0, code: m.code) } }
            found += try await forumActivity(courses: courses, web: web, steps: &steps)
            found += try await gradeActivity(courses: courses, userID: userID, web: web, steps: &steps)
            let changed = try await courseUpdates(courses: courses, web: web, steps: &steps)

            let fresh = academic.knowledge.recordActivity(found)
            announceActivity(fresh)
            academic.state.lastLiveSync = Date()
            academic.lastELELiveSync = academic.state.lastLiveSync
            saveAcademic()
            academic.publish()
            OrbitLog.log(Self.liveLog, "done in \(Int(Date().timeIntervalSince(started)))s: \(steps.joined(separator: ", ")); \(fresh.count) new item(s)")

            // Something changed inside a course: run the full course sync now (at most every 10 minutes).
            let recent = academic.state.lastFullSyncTrigger.map { Date().timeIntervalSince($0) < 600 } ?? false
            if changed > 0 && !recent {
                academic.state.lastFullSyncTrigger = Date()
                OrbitLog.log(Self.liveLog, "\(changed) course item(s) changed → full ELE sync")
                await syncELE()
            }
        } catch let e where Self.isELESignInError(e) {
            OrbitLog.log(Self.liveLog, "ELE sign-in expired")
            accounts.markELENeedsSignIn()
        } catch {
            OrbitLog.log(Self.liveLog, "failed: \(error.localizedDescription)")
        }
    }

    /// Forces the light sync now (UI "Refresh ELE").
    func refreshELELive() async { await syncELELive() }

    /// One AJAX call, remembering functions ELE doesn't allow (skipped for a day).
    private func liveAJAX(_ method: String, _ args: [String: Any], web: ELEWebSession) async throws -> Data? {
        if let at = academic.state.unavailable[method], Date().timeIntervalSince(at) < 86400 { return nil }
        do {
            let data = try await web.ajax(method, args: args)
            _ = try ELEWebParser.ajaxData(data)
            return data
        } catch let e where Self.isELESignInError(e) {
            throw e
        } catch let e as ELEWebError {
            academic.state.unavailable[method] = Date()
            OrbitLog.log(Self.liveLog, "\(method) not available: \(e.description)")
            return nil
        } catch {
            OrbitLog.log(Self.liveLog, "\(method) failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Forums

    private func forumActivity(courses: [(id: Int, code: String)], web: ELEWebSession, steps: inout [String]) async throws -> [ELEActivityItem] {
        guard !courses.isEmpty else { return [] }
        // The forum list changes rarely: refresh daily.
        if academic.state.forumsFetchedAt.map({ Date().timeIntervalSince($0) > 86400 }) ?? true,
           let data = try await liveAJAX("mod_forum_get_forums_by_courses", ["courseids": courses.map(\.id)], web: web) {
            academic.state.forums = try ELELive.forums(fromAJAX: data)
            academic.state.forumsFetchedAt = Date()
        }
        let codes = Dictionary(courses.map { ($0.id, $0.code) }, uniquingKeysWith: { a, _ in a })
        var out: [ELEActivityItem] = []
        // News forums every time; other forums too (capped) so discussions are seen.
        let forums = academic.state.forums.filter(\.isNews) + academic.state.forums.filter { !$0.isNews }.prefix(8)
        for forum in forums {
            guard let data = try await liveAJAX("mod_forum_get_forum_discussions",
                                                ["forumid": forum.id, "sortorder": -1, "page": 0, "perpage": 8], web: web) else { continue }
            let discussions = try ELELive.discussions(fromAJAX: data, forumID: forum.id)
            out += ELELive.activity(discussions: discussions, forum: forum, moduleCode: codes[forum.courseID])
        }
        steps.append("\(forums.count) forums")
        return out
    }

    // MARK: Grades and feedback

    private func gradeActivity(courses: [(id: Int, code: String)], userID: Int, web: ELEWebSession,
                               steps: inout [String]) async throws -> [ELEActivityItem] {
        var out: [ELEActivityItem] = []
        var feedbackCount = 0
        for course in courses {
            var items: [ELEGradeItem] = []
            var args: [String: Any] = ["courseid": course.id]
            if userID > 0 { args["userid"] = userID }
            if let data = try await liveAJAX("gradereport_user_get_grade_items", args, web: web) {
                items = try ELELive.gradeItems(fromAJAX: data)
            } else if let html = try? await web.fetchText(URL(string: "\(Self.eleSite)/grade/report/user/index.php?id=\(course.id)")!) {
                items = ELELive.gradeItems(fromReportHTML: html, courseID: course.id)
            }
            let graded = items.filter { $0.grade != nil || $0.percentage != nil }
            out += ELELive.activity(grades: graded, moduleCode: course.code)
            for g in graded {
                applyMark(g, moduleCode: course.code)
                feedbackCount += await ingestFeedback(g, moduleCode: course.code, userID: userID, web: web)
            }
        }
        steps.append("grades for \(courses.count) module(s), \(feedbackCount) new feedback")
        return out
    }

    /// Puts a released mark on the matching stored assessment (by its ELE link) if it has none.
    private func applyMark(_ g: ELEGradeItem, moduleCode: String) {
        guard let pct = g.percentage else { return }
        StudyHub.shared.recordGrade(moduleCode: moduleCode, title: g.name, mark: pct, date: g.gradedAt ?? Date())
        guard let cmid = g.cmid else { return }
        for a in context.all(StoredAssessment.self) where a.moduleCode == moduleCode && a.mark == nil {
            if let url = a.eleURL, url.contains("id=\(cmid)") {
                a.mark = pct
                context.saveQuietly()
                OrbitLog.log(Self.liveLog, "mark \(Int(pct))% for \(moduleCode) \(a.title)")
            }
        }
    }

    /// Feedback comments (gradebook + the assignment's feedback) → knowledge base and themes.
    private func ingestFeedback(_ g: ELEGradeItem, moduleCode: String, userID: Int, web: ELEWebSession) async -> Int {
        var comments = g.feedback
        if g.module == "assign", let assignID = g.instance {
            var args: [String: Any] = ["assignid": assignID]
            if userID > 0 { args["userid"] = userID }
            if let data = try? await liveAJAX("mod_assign_get_submission_status", args, web: web),
               let status = try? ELELive.submissionStatus(fromAJAX: data), !status.feedbackComments.isEmpty {
                comments = [comments, status.feedbackComments].filter { !$0.isEmpty }.joined(separator: "\n")
            }
        }
        comments = comments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comments.isEmpty else { return 0 }
        let feedback = AssessmentFeedback(id: "ele-\(g.courseID)-\(g.id)", moduleCode: moduleCode, assessmentTitle: g.name,
                                          mark: g.percentage, comments: comments, receivedAt: g.gradedAt)
        guard academic.knowledge.feedback.isNew(feedback) else { return 0 }
        academic.knowledge.addFeedback(feedback)
        let points = await FeedbackThemeExtractor.extract(feedback, router: router)
        academic.knowledge.feedback.ingest(feedback, points: points)
        _ = academic.knowledge.recordActivity([ELEActivityItem(id: "feedback-\(feedback.id)-\(feedback.fingerprint.prefix(6))",
                                                               kind: .feedback, moduleCode: moduleCode,
                                                               title: "Feedback on \(g.name)", detail: String(comments.prefix(300)),
                                                               date: g.gradedAt ?? Date(), important: true)])
        OrbitLog.log(Self.liveLog, "feedback on \(moduleCode) \(g.name): \(points.map(\.label).joined(separator: ", "))")
        return 1
    }

    // MARK: What changed in each course

    /// core_course_get_updates_since per course; changed items are flagged for re-download.
    /// Returns how many items changed.
    private func courseUpdates(courses: [(id: Int, code: String)], web: ELEWebSession, steps: inout [String]) async throws -> Int {
        var changed = 0
        for course in courses {
            let key = String(course.id)
            let since = academic.state.lastUpdatesCheck[key] ?? Date().addingTimeInterval(-3600)
            guard let data = try await liveAJAX("core_course_get_updates_since",
                                                ["courseid": course.id, "since": Int(since.timeIntervalSince1970)], web: web) else { break }
            let updates = try ELELive.updatedModules(fromAJAX: data)
            academic.state.lastUpdatesCheck[key] = Date()
            for (cmid, names) in updates {
                if names.contains(where: { ["contentfiles", "configuration", "introfiles"].contains($0) }) {
                    academic.state.resources.dirty.insert(cmid)
                }
                changed += 1
            }
        }
        steps.append("updates: \(changed) changed item(s)")
        return changed
    }
}
