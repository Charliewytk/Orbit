import Foundation
import SwiftData
import OrbitCore

/// ELE sync through the logged-in website session (see `ELEWebSession`).
extension OrbitBrain {
    static let eleSite = "https://ele.exeter.ac.uk"

    func syncELEWeb() async {
        let web = accounts.eleWeb
        let previous = local.load(ELEWebSnapshot.self, "ele-web-snapshot.json")
        do {
            let snap = try await fetchELEWeb(web, previous: previous)
            applyELEWeb(snap, previous: previous)
            let warn = snap.warnings.isEmpty ? "" : " (\(snap.warnings.count) warnings)"
            record(.ele, detail: "\(snap.modules.count) modules, \(snap.assessments.count) assessments\(warn)")
            accounts.eleSyncSucceeded(modules: snap.modules.count, assessments: snap.assessments.count)
        } catch let error where Self.isELESignInError(error) {
            accounts.markELENeedsSignIn()
            record(.ele, error: "ELE sign-in expired. Click “Sign in to ELE again” in Settings.")
        } catch {
            record(.ele, error: "ELE: \(error.localizedDescription)")
        }
    }

    static func isELESignInError(_ error: Error) -> Bool {
        if case ELEWebSession.SessionError.notSignedIn = error { return true }
        if let e = error as? ELEWebError, e == .sessionExpired { return true }
        return false
    }

    // MARK: Fetch

    private func fetchELEWeb(_ web: ELEWebSession, previous: ELEWebSnapshot?) async throws -> ELEWebSnapshot {
        try await web.prepare(force: true)
        var snap = ELEWebSnapshot(fetchedAt: Date())

        // Courses: in progress first, all as a fallback (then only the latest academic year).
        func courses(_ classification: String) async throws -> [ELEWebCourse] {
            let data = try await web.ajax("core_course_get_enrolled_courses_by_timeline_classification",
                                          args: ["offset": 0, "limit": 0, "classification": classification, "sort": "fullname"])
            return try ELEWebParser.courses(fromAJAX: data)
        }
        var all = try await courses("inprogress")
        if !all.contains(where: \.isModule) {
            all = try await courses("all")
            let latest = all.compactMap(\.academicYearStart).max()
            all = all.filter { !$0.isModule || $0.academicYearStart == nil || $0.academicYearStart == latest }
        }
        let split = ELEWebSnapshot.split(all)
        snap.modules = split.modules
        snap.resourceCourses = split.resources

        // Timeline deadlines (last week onwards).
        do {
            let from = Int(Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970)
            let data = try await web.ajax("core_calendar_get_action_events_by_timesort",
                                          args: ["timesortfrom": from, "limitnum": 50, "limittononsuspendedevents": true])
            snap.events = try ELEWebParser.events(fromAJAX: data)
        } catch let e where Self.isELESignInError(e) { throw e } catch {
            snap.warnings.append("Timeline: \(error.localizedDescription)")
        }

        var tableAssessments: [ELEWebAssessment] = []
        for course in snap.modules {
            guard let code = course.moduleCode else { continue }
            let year = course.academicYearStart ?? ELEWebParser.academicYearStart(for: Date(), timeZone: prefs.timeZone)
            let sections: [ELEWebSection]
            do {
                sections = try await courseSections(course, academicYear: year, web: web)
            } catch let e where Self.isELESignInError(e) { throw e } catch {
                snap.warnings.append("\(code) course page: \(error.localizedDescription)")
                continue
            }
            let content = ELEWebCourseContent(courseID: course.id, moduleCode: code, sections: sections)
            snap.contents[code] = content

            for section in content.assessmentSections {
                let briefs = try await briefTexts(section, web: web, previous: previous, into: &snap)
                let context = ELEAssessmentExtractor.Context(moduleCode: code, academicYear: year,
                                                             sectionURL: section.url ?? course.viewURL, timeZone: prefs.timeZone)
                var found = ELEAssessmentExtractor.extract(sectionHTML: section.html ?? "", briefs: briefs, context: context)
                if found.isEmpty, !briefs.isEmpty || !section.summary.isEmpty {
                    let text = ([section.title, section.summary] + section.items.map { "\($0.name) \($0.text)" }).joined(separator: "\n")
                    found = await ELEAssessmentExtractor.extractWithLLM(router: router, sectionText: text, briefs: briefs, context: context)
                }
                for var a in found {
                    if tableAssessments.contains(where: { $0.assessment.id == a.assessment.id }) {
                        a.assessment.id += "-s\(section.id ?? section.number ?? 0)"
                    }
                    tableAssessments.append(a)
                }
            }
        }
        let timeline = ELEWebParser.assessments(fromEvents: snap.events, courses: snap.modules)
        snap.assessments = ELEAssessmentExtractor.merge(table: tableAssessments, events: timeline)
        return snap
    }

    /// Course page sections: the HTML page, section pages for sections shown
    /// collapsed, and the courseformat state as a last resort.
    private func courseSections(_ course: ELEWebCourse, academicYear: Int, web: ELEWebSession) async throws -> [ELEWebSection] {
        var sections: [ELEWebSection] = []
        var htmlError: Error?
        do {
            let html = try await web.fetchText(URL(string: "\(Self.eleSite)/course/view.php?id=\(course.id)")!)
            sections = ELEWebParser.sections(fromCourseHTML: html, academicYear: academicYear)
        } catch let e where Self.isELESignInError(e) { throw e } catch { htmlError = error }

        // Sections without items on the main page (one-section-per-page or lazy-loaded).
        var fetched = 0
        for i in sections.indices where sections[i].items.isEmpty && fetched < 25 {
            guard [.week, .assessment, .pastPapers, .exemplars, .readingList].contains(sections[i].kind) else { continue }
            let link = sections[i].url ?? sections[i].number.map { "\(Self.eleSite)/course/view.php?id=\(course.id)&section=\($0)" }
            guard let link, let url = URL(string: link) else { continue }
            fetched += 1
            guard let html = try? await web.fetchText(url) else { continue }
            let parsed = ELEWebParser.sections(fromCourseHTML: html, academicYear: academicYear)
            let match = parsed.first { ($0.id != nil && $0.id == sections[i].id) || ($0.number != nil && $0.number == sections[i].number) }
                ?? (parsed.count == 1 ? parsed.first : nil)
            if let match {
                sections[i].items = match.items
                if sections[i].summary.isEmpty { sections[i].summary = match.summary }
                if sections[i].kind == .assessment, match.html != nil { sections[i].html = match.html }
            }
        }

        if sections.isEmpty {
            do {
                let data = try await web.ajax("core_courseformat_get_state", args: ["courseid": course.id])
                sections = try ELEWebParser.sections(fromCourseState: data, academicYear: academicYear)
                // The state has no section summaries; fetch the assessment sections' pages for their tables.
                for i in sections.indices where sections[i].kind == .assessment {
                    guard let link = sections[i].url, let url = URL(string: link),
                          let html = try? await web.fetchText(url) else { continue }
                    sections[i].html = html
                    sections[i].summary = UniHTML.text(html).prefix(4000).description
                }
            } catch let e where Self.isELESignInError(e) { throw e } catch {
                throw htmlError ?? error
            }
        }
        return sections
    }

    /// Text of the assessment briefs (DOCX/PDF/pages) in a section, downloaded once and cached in the snapshot.
    private func briefTexts(_ section: ELEWebSection, web: ELEWebSession, previous: ELEWebSnapshot?,
                            into snap: inout ELEWebSnapshot) async throws -> [String] {
        var out: [String] = []
        for item in section.items where item.role == .assessmentBrief && [.resource, .page].contains(item.kind) {
            guard let cmid = item.cmid else { continue }
            if let cached = previous?.briefTexts[cmid] {
                snap.briefTexts[cmid] = cached
                out.append(cached)
                continue
            }
            guard let url = ELEWebParser.downloadURL(for: item) else { continue }
            do {
                var text: String?
                if item.kind == .page {
                    text = UniHTML.text(try await web.fetchText(url))
                } else {
                    var file = try await web.fetchData(url)
                    // Resources shown "embedded" return a page that links the file.
                    if file.contentType.contains("text/html"),
                       let link = ELEWebParser.pluginFileURL(inHTML: String(decoding: file.data, as: UTF8.self)) {
                        file = try await web.fetchData(link)
                    }
                    text = ELEDocumentText.text(from: file.data, contentType: file.contentType, url: file.finalURL)
                }
                if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    let clipped = String(t.prefix(20_000))
                    snap.briefTexts[cmid] = clipped
                    out.append(clipped)
                }
            } catch let e where Self.isELESignInError(e) { throw e } catch {
                snap.warnings.append("Brief “\(item.name)”: \(error.localizedDescription)")
            }
        }
        // The item names themselves often carry the deadline ("… deadline (3pm 16 November …)").
        out.append(section.items.map(\.name).joined(separator: "\n"))
        return out
    }

    // MARK: Apply

    private func applyELEWeb(_ snap: ELEWebSnapshot, previous: ELEWebSnapshot?) {
        let credits = Dictionary(context.all(StoredModule.self).filter(\.creditsEdited).map { ($0.id, $0.credits) },
                                 uniquingKeysWith: { a, _ in a })
        let converted = snap.eleSnapshot(credits: credits, previous: eleSnapshot)
        eleSnapshot = converted
        local.save(converted, "ele-snapshot.json")
        local.save(snap, "ele-web-snapshot.json")
        apply(converted)

        let modules = context.indexed(StoredModule.self)
        for (code, content) in snap.contents { modules[code]?.setWeeks(content.weeks) }
        let stored = context.indexed(StoredAssessment.self)
        for a in snap.assessments {
            let details = a.details
            stored[a.assessment.id]?.details = details.isEmpty ? nil : details
        }
        context.saveQuietly()

        autoPlanELE(snap.assessments.map(\.assessment))

        let changes = ELEWebChanges.diff(from: previous, to: snap)
        guard !changes.isInitial else { return }
        announce(changes.base)
        for w in changes.updatedWeeks.prefix(3) {
            notify(id: "ele-week-\(w.moduleCode)-\(w.week)-\(Int(snap.fetchedAt.timeIntervalSince1970 / 86400))",
                   title: "📚 \(w.moduleCode) week \(w.week) updated", body: w.title, category: "ele")
        }
        for a in changes.changedAssessments.prefix(3) {
            notify(id: "ele-changed-\(a.assessment.id)-\(Int(a.assessment.weightPercent))-\(a.assessment.wordCount ?? 0)",
                   title: "✏️ Assessment updated: \(a.assessment.moduleCode)",
                   body: "\(a.assessment.title): \(Int(a.assessment.weightPercent))%\(a.assessment.wordCount.map { ", \($0) words" } ?? "")",
                   category: "ele")
        }
        if !changes.isEmpty { scheduleReplan(after: 2) }
    }

    /// Plans every dated, summative, not-yet-planned assessment (e.g. tasks for
    /// the BEE1032 essay working back from 16 Nov 15:00).
    func autoPlanELE(_ assessments: [Assessment]) {
        let now = Date()
        let stored = context.indexed(StoredAssessment.self)
        let taskAssessmentIDs = Set(context.all(StoredTask.self).compactMap(\.assessmentID))
        var planned = 0
        for a in assessments {
            guard let s = stored[a.id], s.plannedAt == nil, !s.submitted, s.mark == nil,
                  let due = s.due, due > now, s.weightPercent > 0, !taskAssessmentIDs.contains(a.id) else { continue }
            let value = s.value
            let topics = value.kind == .exam ? revisionTopics(moduleCode: value.moduleCode) : []
            var tasks = StudyCoach(prefs: prefs).planAssessment(value, now: now, topics: topics)
            for i in tasks.indices {
                tasks[i].assessmentID = value.id
                tasks[i].moduleCode = tasks[i].moduleCode ?? value.moduleCode
                tasks[i].source = .ele
                context.insert(StoredTask(task: tasks[i]))
            }
            s.plannedAt = now
            planned += 1
        }
        guard planned > 0 else { return }
        context.saveQuietly()
        tasksChanged()
    }
}
