import XCTest
@testable import OrbitCore

/// Realistic Ed API responses (shapes as the edstem.org web app receives them; names and ids made up
/// apart from the public module codes and the pinned "Programme Maps" thread).
enum EdFixtures {
    static let user = """
    {"user":{"id":201774,"role":"user","name":"Student Example","email":"se123@exeter.ac.uk","username":null,
      "avatar":null,"features":{},"settings":{},"activated":true,"created_at":"2026-09-14T09:12:45.123456+01:00",
      "course_role":null,"secondary_emails":[],"has_password":false,"is_lti":false,"has_pats":false},
     "courses":[
      {"course":{"id":3101,"realm_id":41,"code":"BEE1022","name":"Economic Principles","year":"2026","session":"Term 1",
                 "status":"active","features":{},"settings":{},"created_at":"2026-08-01T10:00:00.000000+01:00","is_lab_regex_active":false},
       "role":{"user_id":201774,"course_id":3101,"lab_id":null,"role":"student","tutorial":null,"digest":true},
       "lab":null,"last_active":"2026-09-25T18:03:11.2+01:00"},
      {"course":{"id":3102,"code":"BEE1024 - Mathematics for Economists","name":"Mathematics for Economists","year":"2026",
                 "session":"Term 1","status":"active"},
       "role":{"role":"student"},"lab":null},
      {"course":{"id":2999,"code":"BEE1907","name":"Archived Course","year":"2025","session":"Term 2","status":"archived"},
       "role":{"role":"student"},"lab":null}
     ],
     "realms":[],"time":"2026-09-26T10:00:00.000000+01:00"}
    """

    static let threads = """
    {"threads":[
      {"id":90001,"user_id":5001,"course_id":3101,"original_id":null,"editor_id":5001,"accepted_id":null,"duplicate_id":null,
       "number":1,"type":"post","title":"Programme Maps","content":"<document version=\\"2.0\\"><paragraph>…</paragraph></document>",
       "document":"Programme maps for all BSc Economics pathways are on ELE under Programme Information.",
       "category":"General","subcategory":"","subsubcategory":"","flag_count":0,"star_count":3,"view_count":210,
       "unique_view_count":180,"vote_count":0,"reply_count":0,"unresolved_count":0,"is_locked":false,"is_pinned":true,
       "is_private":false,"is_endorsed":false,"is_answered":false,"is_student_answered":false,"is_staff_answered":false,
       "is_archived":false,"is_anonymous":false,"is_megathread":false,"anonymous_comments":false,"approved_status":"approved",
       "created_at":"2026-09-15T11:00:00.000000+01:00","updated_at":"2026-09-15T11:00:00.000000+01:00","deleted_at":null,
       "pinned_at":"2026-09-15T11:00:05.000000+01:00","anonymous_id":0,"vote":0,"is_seen":true,"is_starred":false,
       "is_watched":null,"glanced_at":"2026-09-20T12:00:00.000000+01:00","new_reply_count":0,"duplicate_title":null},
      {"id":90002,"user_id":201774,"course_id":3101,"number":7,"type":"question","title":"Is the week 2 problem set marked?",
       "document":"Do we hand in the problem set or is it just practice?","category":"Problem Sets","subcategory":"",
       "reply_count":1,"is_pinned":false,"is_private":false,"is_anonymous":false,"is_answered":true,"is_staff_answered":true,
       "created_at":"2026-09-24T20:14:51.912345+01:00","updated_at":"2026-09-25T09:02:13.100000+01:00",
       "is_watched":true,"new_reply_count":1},
      {"id":90003,"user_id":5002,"course_id":3101,"number":8,"type":"announcement","title":"Room change for Thursday's lecture",
       "document":"Thursday's lecture is moved to Forum Alumni Auditorium. Problem Set 2 is due Friday 2 October at 12:00 on ELE.",
       "category":"Lectures","subcategory":"","reply_count":0,"is_pinned":false,"is_anonymous":false,
       "created_at":"2026-09-25T16:30:00.000000+01:00","updated_at":"2026-09-25T16:30:00.000000+01:00"},
      {"id":90004,"user_id":201999,"course_id":3101,"number":9,"type":"post","title":"Anyone for football on Saturday?",
       "document":"Five-a-side at the sports park, all welcome.","category":"Social","subcategory":"","reply_count":4,
       "is_pinned":false,"is_anonymous":false,"created_at":"2026-09-25T19:00:00.000000+01:00","updated_at":"2026-09-25T21:00:00+01:00"}
     ],
     "users":[
      {"id":5001,"role":"user","name":"Shaun Grimshaw","avatar":null,"course_role":"admin","tutorials":{}},
      {"id":5002,"role":"user","name":"Dr A Lecturer","avatar":null,"course_role":"staff","tutorials":{}},
      {"id":201774,"role":"user","name":"Student Example","avatar":null,"course_role":"student","tutorials":{}},
      {"id":201999,"role":"user","name":"Another Student","avatar":null,"course_role":"student","tutorials":{}}
     ],
     "sort_key":"","page_size":30}
    """

    static let thread = """
    {"thread":{"id":90002,"user_id":201774,"course_id":3101,"number":7,"type":"question","title":"Is the week 2 problem set marked?",
      "document":"Do we hand in the problem set or is it just practice?","category":"Problem Sets","reply_count":1,
      "is_pinned":false,"is_anonymous":false,"created_at":"2026-09-24T20:14:51.912345+01:00",
      "answers":[{"id":77001,"user_id":5002,"course_id":3101,"thread_id":90002,"parent_id":null,"type":"answer",
                  "document":"It's formative, but do hand it in by Friday so your tutor can give feedback.",
                  "is_anonymous":false,"created_at":"2026-09-25T09:02:13.100000+01:00","comments":[
                    {"id":77002,"user_id":201774,"type":"comment","document":"Thanks!","created_at":"2026-09-25T09:10:00+01:00","comments":[]}]}],
      "comments":[]},
     "users":[{"id":5002,"name":"Dr A Lecturer","course_role":"staff"},{"id":201774,"name":"Student Example","course_role":"student"}]}
    """
}

final class EdClientTests: XCTestCase {
    let now = ISO8601.parse("2026-09-26T09:00:00Z")!

    func testDecodesUserAndCourses() throws {
        let r = try EdClient.decodeUser(Data(EdFixtures.user.utf8))
        XCTAssertEqual(r.user.id, 201774)
        XCTAssertEqual(r.courses.count, 3)
        XCTAssertEqual(r.courses[0].course.moduleCode, "BEE1022")
        XCTAssertEqual(r.courses[1].course.moduleCode, "BEE1024")
        XCTAssertFalse(r.courses[2].course.isActive)
        XCTAssertEqual(r.courses[0].role?.role, "student")
    }

    func testDecodesThreads() throws {
        let r = try EdClient.decodeThreads(Data(EdFixtures.threads.utf8))
        XCTAssertEqual(r.threads.count, 4)
        XCTAssertEqual(r.threads[0].isPinned, true)
        XCTAssertEqual(r.threads[2].isAnnouncement, true)
        XCTAssertEqual(r.users?.first?.courseRole, "admin")
        XCTAssertTrue(r.users!.first!.isStaff)
        // Microsecond timestamps parse.
        XCTAssertEqual(r.threads[1].created!.timeIntervalSince1970, ISO8601.parse("2026-09-24T19:14:51Z")!.timeIntervalSince1970, accuracy: 1)
    }

    func testDecodesThreadWithReplies() throws {
        let r = try EdClient.decodeThread(Data(EdFixtures.thread.utf8))
        XCTAssertEqual(r.thread.allReplies.map(\.id), [77001, 77002])
    }

    func testDates() {
        XCTAssertNotNil(EdText.date("2026-09-25T16:30:00.000000+01:00"))
        XCTAssertNotNil(EdText.date("2026-09-25T21:00:00+01:00"))
        XCTAssertNotNil(EdText.date("2026-09-25T18:03:11.2+01:00"))
        XCTAssertNil(EdText.date("yesterday"))
    }

    func testImportance() throws {
        let r = try EdClient.decodeThreads(Data(EdFixtures.threads.utf8))
        let users = Dictionary(uniqueKeysWithValues: r.users!.map { ($0.id, $0) })
        func imp(_ i: Int) -> EdImportance { EdImportance.classify(r.threads[i], author: users[r.threads[i].userId!]) }
        XCTAssertTrue(imp(0).isImportant)                       // pinned, staff
        XCTAssertTrue(imp(0).reasons.contains("pinned"))
        XCTAssertEqual(imp(1).level, .normal)                   // student question in Problem Sets
        XCTAssertTrue(imp(2).isImportant)                       // announcement
        XCTAssertTrue(imp(2).keywords.contains("due"))
        XCTAssertTrue(imp(2).keywords.contains("moved to"))
        XCTAssertEqual(imp(3).level, .low)                      // Social
        XCTAssertEqual(EdImportance.matchedKeywords("The quiz is due"), ["quiz", "due"])
        XCTAssertEqual(EdImportance.matchedKeywords("Residual plots"), [], "whole words only")
    }

    func testSyncBaselinesThenFindsNewThings() throws {
        let user = try EdClient.decodeUser(Data(EdFixtures.user.utf8))
        let course = user.courses[0].course
        var state = EdState()
        state.userID = user.user.id
        var response = try EdClient.decodeThreads(Data(EdFixtures.threads.utf8))

        let first = EdSync.process(course: course, response: response, state: &state, now: now)
        XCTAssertTrue(first.allSatisfy(\.baseline))
        XCTAssertEqual(Set(first.map(\.threadID)), [90001, 90002, 90003, 90004])
        XCTAssertEqual(state.add(first).count, 4)

        // Next poll: a reply on my thread, a new staff post, the social thread pinned.
        response.threads[1].replyCount = 2
        response.threads[3].isPinned = true
        var staffPost = response.threads[2]
        staffPost.id = 90010
        staffPost.type = "post"
        staffPost.title = "Quiz 1 extension"
        staffPost.document = "The deadline for Quiz 1 is extended to Monday 5 October at 17:00."
        response.threads.insert(staffPost, at: 0)
        let second = EdSync.process(course: course, response: response, state: &state, now: now)
        let byID = Dictionary(uniqueKeysWithValues: second.map { ($0.id, $0) })
        XCTAssertEqual(byID["ed-thread-90010"]?.kind, .staffPost)
        XCTAssertEqual(byID["ed-thread-90010"]?.author, "Dr A Lecturer")
        XCTAssertTrue(byID["ed-thread-90010"]!.importance.isImportant)
        XCTAssertEqual(byID["ed-reply-90002-2"]?.kind, .reply)
        XCTAssertEqual(byID["ed-pinned-90004"]?.kind, .pinned)
        XCTAssertEqual(second.count, 3)
        XCTAssertEqual(byID["ed-thread-90010"]?.url, "https://edstem.org/us/courses/3101/discussion/90010")
        XCTAssertEqual(byID["ed-thread-90010"]?.moduleCode, "BEE1022")

        // Nothing changes: nothing new.
        XCTAssertTrue(EdSync.process(course: course, response: response, state: &state, now: now).isEmpty)
    }

    func testDeadlineMentions() throws {
        let user = try EdClient.decodeUser(Data(EdFixtures.user.utf8))
        var state = EdState()
        let response = try EdClient.decodeThreads(Data(EdFixtures.threads.utf8))
        let items = EdSync.process(course: user.courses[0].course, response: response, state: &state, now: now)
        let announcement = items.first { $0.threadID == 90003 }!
        let extractor = DateExtractor(now: now, timeZone: TimeZone(identifier: "Europe/London")!)
        let found = EdSync.deadlineMentions(in: announcement, extractor: extractor)
        XCTAssertEqual(found.count, 1)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let c = cal.dateComponents([.month, .day, .hour], from: found[0].date)
        XCTAssertEqual(c.month, 10)
        XCTAssertEqual(c.day, 2)
        XCTAssertEqual(c.hour, 12)
        // Student posts never make deadlines.
        let student = items.first { $0.threadID == 90002 }!
        XCTAssertTrue(EdSync.deadlineMentions(in: student, extractor: extractor).isEmpty)
    }

    func testConversions() throws {
        let user = try EdClient.decodeUser(Data(EdFixtures.user.utf8))
        var state = EdState()
        let response = try EdClient.decodeThreads(Data(EdFixtures.threads.utf8))
        let items = EdSync.process(course: user.courses[0].course, response: response, state: &state, now: now)
        let pinned = items.first { $0.threadID == 90001 }!
        let activity = EdSync.activityItem(pinned)
        XCTAssertEqual(activity.id, "ed-thread-90001")
        XCTAssertEqual(activity.kind, .forumPost)
        XCTAssertFalse(activity.important, "baseline items don't notify")
        let doc = try XCTUnwrap(EdSync.document(pinned))
        XCTAssertEqual(doc.id, "ed-90001")
        XCTAssertEqual(doc.kind, .announcement)
        XCTAssertTrue(doc.text.contains("Shaun Grimshaw"))
        XCTAssertNil(EdSync.document(items.first { $0.threadID == 90004 }!))

        state.add(items)
        let text = EdSync.text(state.recent(moduleCode: "BEE1022"), timeZone: TimeZone(identifier: "Europe/London")!)
        XCTAssertTrue(text.contains("Room change"))
        XCTAssertTrue(text.contains("[important"))
    }

    func testStateRoundTrip() throws {
        var state = EdState()
        state.userID = 1
        state.marks[5] = EdThreadMark(replyCount: 2, pinned: true, updatedAt: nil)
        state.baselined = [3101]
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(EdState.self, from: data)
        XCTAssertEqual(back.marks[5]?.replyCount, 2)
        XCTAssertEqual(back.baselined, [3101])
        XCTAssertNotNil(try? JSONDecoder().decode(EdState.self, from: Data("{}".utf8)))
    }

    func testClientSendsTokenAndMapsAuthErrors() async throws {
        let stub = FeatureStubTransport { req in
            if req.url!.path.hasSuffix("/user") { return (200, EdFixtures.user) }
            return (401, #"{"code":"bad_token"}"#)
        }
        let client = EdClient(token: "test-token", http: HTTPClient(transport: stub))
        let me = try await client.user()
        XCTAssertEqual(me.user.name, "Student Example")
        XCTAssertEqual(stub.requests[0].url?.absoluteString, "https://us.edstem.org/api/user")
        XCTAssertEqual(stub.requests[0].value(forHTTPHeaderField: "x-token"), "test-token")
        do {
            _ = try await client.threads(courseID: 3101)
            XCTFail("expected unauthorized")
        } catch let e as EdError {
            XCTAssertEqual(e, .unauthorized)
        }
        XCTAssertEqual(stub.requests[1].url?.query, "limit=30&offset=0&sort=new")

        let api = EdClient(token: "pat", tokenKind: .apiToken, http: HTTPClient(transport: stub))
        _ = try await api.user()
        XCTAssertEqual(stub.requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer pat")
    }
}

final class EdRegionTests: XCTestCase {
    func testDefaultIsUSForExeter() {
        XCTAssertEqual(EdRegion.default, .us)
        XCTAssertEqual(EdRegion.us.loginURL.absoluteString, "https://edstem.org/us/login")
        XCTAssertEqual(EdRegion.us.dashboardURL.absoluteString, "https://edstem.org/us/dashboard")
        XCTAssertEqual(EdRegion.us.apiBase.absoluteString, "https://us.edstem.org/api/")
        XCTAssertEqual(EdRegion.eu.loginURL.absoluteString, "https://edstem.org/eu/login")
    }
}
