import XCTest
@testable import OrbitCore

final class ELESyncTests: XCTestCase {
    /// Mutable fake ELE state, so a second sync can see changes.
    final class FakeELE: @unchecked Sendable {
        var essayDue = 1_792_000_000
        var extraAnnouncement = false
        var gradeQuizAgain = false

        func respond(_ fn: String, _ fields: [String: String]) -> String? {
            switch fn {
            case "core_webservice_get_site_info":
                return #"{"sitename":"ELE","userid":42,"fullname":"Charlie W","functions":[]}"#
            case "core_enrol_get_users_courses":
                return #"[{"id":5,"shortname":"BEM2031_2026","fullname":"BEM2031 - Business Analytics 2026/7","enddate":0},"#
                    + #"{"id":6,"shortname":"BEM2024","fullname":"BEM2024 Accounting 2026/7","enddate":0},"#
                    + #"{"id":8,"shortname":"OLD1000","fullname":"OLD1000 Last year","enddate":1700000000}]"#
            case "mod_assign_get_assignments": return UniFixtures.assignments(due: essayDue)
            case "mod_assign_get_submission_status": return #"{"lastattempt":{"submission":{"status":"new"},"graded":false}}"#
            case "mod_quiz_get_quizzes_by_courses": return UniFixtures.quizzes
            case "core_calendar_get_action_events_by_timesort":
                return #"{"events":[{"id":900,"name":"Group report is due","activityname":"Group report","modulename":"turnitintooltwo","#
                    + #""instance":77,"course":{"id":6,"shortname":"BEM2024"},"timesort":1793000000,"url":"https://ele.exeter.ac.uk/mod/turnitintooltwo/view.php?id=77"},"#
                    + #"{"id":901,"name":"Individual Essay is due","modulename":"assign","instance":11,"course":{"id":5},"timesort":1792000000}]}"#
            case "gradereport_user_get_grade_items": return UniFixtures.grades(courseID: Int(fields["courseid"] ?? "") ?? 0)
            case "core_course_get_contents": return fields["courseid"] == "5" ? UniFixtures.contents : "[]"
            case "mod_forum_get_forums_by_courses": return UniFixtures.forums
            case "mod_forum_get_forum_discussions": return UniFixtures.discussions(extra: extraAnnouncement)
            default: return nil
            }
        }
    }

    let now = Date(timeIntervalSince1970: 1_791_000_000) // late Oct 2026

    func makeSync(_ fake: FakeELE) -> (ELESync, UniStubTransport) {
        let t = UniStubTransport.moodle { fake.respond($0, $1) }
        let client = MoodleClient(credentials: MoodleCredentials(siteURL: URL(string: "https://ele.exeter.ac.uk")!, token: "tok"),
                                  http: HTTPClient(transport: t))
        var options = ELESync.Options()
        options.creditsByModule = ["BEM2031": 30]
        return (ELESync(client: client, options: options), t)
    }

    func testFullSnapshot() async throws {
        let (sync, t) = makeSync(FakeELE())
        let (snap, changes) = try await sync.sync(now: now)

        XCTAssertEqual(snap.userID, 42)
        XCTAssertEqual(snap.modules.map(\.code), ["BEM2031", "BEM2024"]) // finished course dropped
        XCTAssertEqual(snap.modules.first?.credits, 30)
        XCTAssertEqual(snap.modules.first?.name, "Business Analytics")

        let essay = try XCTUnwrap(snap.assessments.first { $0.id == "ele-assign-11" })
        XCTAssertEqual(essay.moduleCode, "BEM2031")
        XCTAssertEqual(essay.kind, .essay)
        XCTAssertEqual(essay.weightPercent, 40)
        XCTAssertEqual(essay.wordCount, 2000)
        XCTAssertFalse(essay.submitted)

        let quiz = try XCTUnwrap(snap.assessments.first { $0.id == "ele-quiz-21" })
        XCTAssertEqual(quiz.mark, 72)
        XCTAssertEqual(quiz.weightPercent, 10) // from the gradebook weight

        let turnitin = try XCTUnwrap(snap.assessments.first { $0.id == "ele-turnitintooltwo-77" })
        XCTAssertEqual(turnitin.moduleCode, "BEM2024")
        XCTAssertEqual(turnitin.kind, .report)
        XCTAssertEqual(snap.assessments.count, 3) // the assign timeline event isn't duplicated

        XCTAssertEqual(snap.resources.map(\.id), ["ele-cm-301", "ele-cm-302"])
        XCTAssertEqual(snap.readingListURLs["BEM2031"], ["https://rl.talis.com/3/exeter/lists/ABC.html"])
        XCTAssertEqual(snap.sectionTopics["BEM2031"], ["Week 1: Regression"])
        XCTAssertEqual(snap.announcements.map(\.subject), ["Welcome"])
        XCTAssertEqual(snap.grades.map(\.percent), [72])
        XCTAssertTrue(snap.warnings.isEmpty, "\(snap.warnings)")

        XCTAssertTrue(changes.isInitial)
        XCTAssertEqual(changes.newAssessments.count, 3)
        XCTAssertFalse(t.functionsCalled.contains("core_course_get_updates_since"))

        // Snapshots round-trip through JSON for storage.
        let data = try HTTPClient.encoder.encode(snap)
        XCTAssertEqual(try HTTPClient.decoder.decode(ELESnapshot.self, from: data).assessments.count, 3)
    }

    func testSecondSyncReportsOnlyChanges() async throws {
        let fake = FakeELE()
        let (sync, _) = makeSync(fake)
        _ = try await sync.sync(now: now)

        fake.essayDue += 7 * 86400
        fake.extraAnnouncement = true
        let (_, changes) = try await sync.sync(now: now.addingTimeInterval(3600))
        XCTAssertFalse(changes.isInitial)
        XCTAssertTrue(changes.newAssessments.isEmpty)
        XCTAssertEqual(changes.changedDeadlines.map(\.assessment.id), ["ele-assign-11"])
        XCTAssertEqual(changes.changedDeadlines.first?.newDue, Date(timeIntervalSince1970: TimeInterval(fake.essayDue)))
        XCTAssertEqual(changes.newAnnouncements.map(\.subject), ["Essay deadline moved"])
        XCTAssertTrue(changes.newResources.isEmpty)
        XCTAssertTrue(changes.newGrades.isEmpty)
        XCTAssertFalse(changes.isEmpty)
    }

    func testDisabledFunctionsBecomeWarnings() async throws {
        let t = UniStubTransport.moodle { fn, _ in
            switch fn {
            case "core_webservice_get_site_info":
                return #"{"sitename":"ELE","userid":42,"fullname":"C","functions":[{"name":"core_enrol_get_users_courses"},{"name":"mod_assign_get_assignments"}]}"#
            case "core_enrol_get_users_courses": return #"[{"id":5,"shortname":"BEM2031","fullname":"BEM2031 Analytics"}]"#
            case "mod_assign_get_assignments": return UniFixtures.assignments(due: 1_792_000_000)
            default: return nil
            }
        }
        let client = MoodleClient(credentials: MoodleCredentials(siteURL: URL(string: "https://ele.exeter.ac.uk")!, token: "t"),
                                  http: HTTPClient(transport: t))
        let snap = try await ELESync(client: client).fetchSnapshot(now: now)
        XCTAssertEqual(snap.assessments.count, 1)
        XCTAssertFalse(snap.warnings.isEmpty)
        XCTAssertFalse(t.functionsCalled.contains("mod_quiz_get_quizzes_by_courses")) // skipped, not called
    }

    func testExpiredTokenIsNotSwallowed() async {
        let t = UniStubTransport { _, _ in (200, #"{"exception":"moodle_exception","errorcode":"invalidtoken","message":"Invalid token"}"#) }
        let client = MoodleClient(credentials: MoodleCredentials(siteURL: URL(string: "https://ele.exeter.ac.uk")!, token: "t"),
                                  http: HTTPClient(transport: t))
        do {
            _ = try await ELESync(client: client).sync(now: now)
            XCTFail("expected error")
        } catch {
            XCTAssertTrue((error as? MoodleError)?.needsReauthentication ?? false)
        }
    }
}
