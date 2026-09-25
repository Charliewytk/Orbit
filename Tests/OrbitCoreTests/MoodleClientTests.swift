import XCTest
@testable import OrbitCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Canned HTTP for the Uni tests. Moodle calls are routed by `wsfunction`.
final class UniStubTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, [String: String]) throws -> (Int, String)
    private let lock = NSLock()
    private var _requests: [(URLRequest, [String: String])] = []
    let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    /// Answers Moodle REST calls from `responses[wsfunction]`; unknown functions get an access exception.
    static func moodle(_ responses: @escaping @Sendable (String, [String: String]) -> String?) -> UniStubTransport {
        UniStubTransport { _, fields in
            let fn = fields["wsfunction"] ?? ""
            if let body = responses(fn, fields) { return (200, body) }
            return (200, #"{"exception":"webservice_access_exception","errorcode":"accessexception","message":"Access control exception"}"#)
        }
    }

    var requests: [(URLRequest, [String: String])] { lock.lock(); defer { lock.unlock() }; return _requests }
    var functionsCalled: [String] { requests.compactMap { $0.1["wsfunction"] } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let fields = Self.formFields(request)
        lock.lock(); _requests.append((request, fields)); lock.unlock()
        let (status, body) = try handler(request, fields)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    static func formFields(_ r: URLRequest) -> [String: String] {
        guard let body = r.httpBody, r.value(forHTTPHeaderField: "Content-Type")?.contains("form") == true else { return [:] }
        var out: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            out[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        return out
    }
}

final class MoodleClientTests: XCTestCase {
    let creds = MoodleCredentials(siteURL: URL(string: "https://ele.exeter.ac.uk/")!, token: "tok")

    func client(_ t: UniStubTransport) -> MoodleClient { MoodleClient(credentials: creds, http: HTTPClient(transport: t)) }

    func testSendsTokenFunctionAndArrayParams() async throws {
        let t = UniStubTransport.moodle { fn, _ in fn == "mod_assign_get_assignments" ? #"{"courses":[],"warnings":[]}"# : nil }
        _ = try await client(t).assignments(courseIDs: [5, 9])
        let (req, fields) = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://ele.exeter.ac.uk/webservice/rest/server.php")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(fields["wstoken"], "tok")
        XCTAssertEqual(fields["moodlewsrestformat"], "json")
        XCTAssertEqual(fields["courseids[0]"], "5")
        XCTAssertEqual(fields["courseids[1]"], "9")
    }

    func testNestedParamEncoding() {
        let p: MoodleParam = .list([.dict(["name": "a", "value": 1])])
        XCTAssertEqual(p.fields("options").map { "\($0.0)=\($0.1)" }, ["options[0][name]=a", "options[0][value]=1"])
    }

    func testExceptionWithHTTP200Throws() async {
        let t = UniStubTransport { _, _ in (200, #"{"exception":"moodle_exception","errorcode":"invalidtoken","message":"Invalid token - token not found"}"#) }
        do {
            _ = try await client(t).siteInfo()
            XCTFail("expected error")
        } catch let e as MoodleError {
            XCTAssertEqual(e, .exception(errorCode: "invalidtoken", message: "Invalid token - token not found"))
            XCTAssertTrue(e.needsReauthentication)
        } catch { XCTFail("wrong error \(error)") }
    }

    func testSiteInfoAndCourses() async throws {
        let t = UniStubTransport.moodle { fn, fields in
            switch fn {
            case "core_webservice_get_site_info":
                return #"{"sitename":"ELE &amp; more","userid":42,"fullname":"Charlie W","functions":[{"name":"core_enrol_get_users_courses","version":"1"}]}"#
            case "core_enrol_get_users_courses":
                XCTAssertEqual(fields["userid"], "42")
                return #"[{"id":5,"shortname":"BEM2031_2026","fullname":"BEM2031 - Business Analytics 2026/7","visible":1,"startdate":1790000000,"enddate":0},{"id":7,"shortname":"UG Hub","fullname":"Business School Student Hub","hidden":false}]"#
            default: return nil
            }
        }
        let info = try await client(t).siteInfo()
        XCTAssertEqual(info.userID, 42)
        XCTAssertEqual(info.siteName, "ELE & more")
        XCTAssertTrue(info.allows("core_enrol_get_users_courses"))
        XCTAssertFalse(info.allows("mod_quiz_get_quizzes_by_courses"))

        let courses = try await client(t).courses(userID: 42)
        XCTAssertEqual(courses.map(\.moduleCode), ["BEM2031", nil])
        XCTAssertEqual(courses[0].moduleName, "Business Analytics")
        XCTAssertNil(courses[0].endDate)
        let module = ELEMapping.module(courses[0])
        XCTAssertEqual(module.code, "BEM2031")
        XCTAssertEqual(module.eleCourseID, 5)
        XCTAssertEqual(ELEMapping.module(courses[1]).code, "UG Hub")
    }

    func testContentsDetectsReadingListsAndResources() async throws {
        let t = UniStubTransport.moodle { fn, _ in
            fn == "core_course_get_contents" ? UniFixtures.contents : nil
        }
        let sections = try await client(t).contents(courseID: 5)
        XCTAssertEqual(sections.count, 2)
        let list = try XCTUnwrap(sections[0].modules.first)
        XCTAssertTrue(list.isReadingList)
        XCTAssertEqual(list.externalURL, "https://rl.talis.com/3/exeter/lists/ABC.html")
        let resources = sections.flatMap { s in s.modules.compactMap { ELEMapping.resource($0, section: s, courseID: 5, moduleCode: "BEM2031") } }
        XCTAssertEqual(resources.map(\.kind), [.readingList, .file])
        XCTAssertEqual(resources[1].section, "Week 1: Regression")
        XCTAssertEqual(client(t).authenticatedFileURL(resources[1].targetURL!)?.absoluteString,
                       "https://ele.exeter.ac.uk/webservice/pluginfile.php/1/l1.pdf?forcedownload=1&token=tok")
    }

    func testAssignmentMappingAndSubmissionStatus() async throws {
        let t = UniStubTransport.moodle { fn, _ in
            switch fn {
            case "mod_assign_get_assignments": return UniFixtures.assignments(due: 1_792_000_000)
            case "mod_assign_get_submission_status":
                return #"{"lastattempt":{"submission":{"status":"submitted"},"graded":true},"feedback":{"grade":{"grade":"68.00000"}}}"#
            default: return nil
            }
        }
        let c = client(t)
        let assigns = try await c.assignments(courseIDs: [5])
        XCTAssertEqual(assigns.count, 1)
        let status = try await c.submissionStatus(assignID: 11)
        XCTAssertTrue(status.submitted)
        let a = ELEMapping.assessment(assigns[0], moduleCode: "BEM2031", status: status, siteURL: "https://ele.exeter.ac.uk")
        XCTAssertEqual(a.id, "ele-assign-11")
        XCTAssertEqual(a.kind, .essay)
        XCTAssertEqual(a.weightPercent, 40)
        XCTAssertEqual(a.wordCount, 2000)
        XCTAssertEqual(a.mark, 68)
        XCTAssertTrue(a.submitted)
        XCTAssertEqual(a.due, Date(timeIntervalSince1970: 1_792_000_000))
        XCTAssertEqual(a.eleURL, "https://ele.exeter.ac.uk/mod/assign/view.php?id=101")
    }

    func testGradeItemsQuizzesAndForums() async throws {
        let t = UniStubTransport.moodle { fn, _ in
            switch fn {
            case "gradereport_user_get_grade_items": return UniFixtures.grades(courseID: 6)
            case "mod_quiz_get_quizzes_by_courses": return UniFixtures.quizzes
            case "mod_forum_get_forums_by_courses": return UniFixtures.forums
            case "mod_forum_get_forum_discussions": return UniFixtures.discussions(extra: false)
            default: return nil
            }
        }
        let c = client(t)
        let items = try await c.gradeItems(courseID: 6, userID: 42)
        let grade = try XCTUnwrap(ELEMapping.grade(items[0], courseID: 6, moduleCode: "BEM2024"))
        XCTAssertEqual(grade.percent, 72)
        XCTAssertEqual(grade.assessmentID, "ele-quiz-21")
        XCTAssertEqual(grade.weightPercent ?? 0, 10, accuracy: 0.001)
        XCTAssertNil(ELEMapping.grade(items[1], courseID: 6, moduleCode: "BEM2024")) // not released

        let quizzes = try await c.quizzes(courseIDs: [6])
        XCTAssertEqual(quizzes.first?.timeClose, Date(timeIntervalSince1970: 1_791_500_000))

        let forums = try await c.forums(courseIDs: [5])
        XCTAssertEqual(forums.filter(\.isAnnouncements).map(\.id), [61])
        let posts = try await c.discussions(forumID: 61)
        let ann = ELEMapping.announcement(posts[0], forum: forums[0], moduleCode: "BEM2031", siteURL: "https://ele.exeter.ac.uk")
        XCTAssertEqual(ann.message, "Hello & welcome to the module.")
        XCTAssertEqual(ann.url, "https://ele.exeter.ac.uk/mod/forum/discuss.php?d=501")
    }

    func testDiscussionsFallBackToPaginatedFunction() async throws {
        let t = UniStubTransport.moodle { fn, _ in
            fn == "mod_forum_get_forum_discussions_paginated" ? UniFixtures.discussions(extra: false) : nil
        }
        let posts = try await client(t).discussions(forumID: 61)
        XCTAssertEqual(posts.map(\.id), [501])
        XCTAssertEqual(t.functionsCalled, ["mod_forum_get_forum_discussions", "mod_forum_get_forum_discussions_paginated"])
    }
}

/// Canned Moodle responses shared by the Moodle/ELE tests.
enum UniFixtures {
    static let contents = #"""
    [{"id":1,"name":"General","section":0,"summary":"","modules":[
       {"id":301,"name":"Module reading list","modname":"url","url":"https://ele.exeter.ac.uk/mod/url/view.php?id=301","visible":1,
        "contents":[{"type":"url","filename":"Reading list","fileurl":"https://rl.talis.com/3/exeter/lists/ABC.html"}]}]},
     {"id":2,"name":"Week 1: Regression","section":1,"summary":"<p>Intro</p>","modules":[
       {"id":302,"name":"Lecture 1 slides","modname":"resource","url":"https://ele.exeter.ac.uk/mod/resource/view.php?id=302",
        "contents":[{"type":"file","filename":"l1.pdf","fileurl":"https://ele.exeter.ac.uk/webservice/pluginfile.php/1/l1.pdf?forcedownload=1","timemodified":1790000000}]},
       {"id":303,"name":"Essay submission","modname":"assign","instance":11}]}]
    """#

    static func assignments(due: Int) -> String {
        #"{"courses":[{"id":5,"assignments":[{"id":11,"cmid":101,"course":5,"name":"Individual Essay (40%)","duedate":\#(due),"cutoffdate":0,"#
            + #""intro":"<p>Write a <strong>2,000-word</strong> essay on&nbsp;analytics.</p>","grade":100}]}],"warnings":[]}"#
    }

    static let quizzes = #"{"quizzes":[{"id":21,"course":6,"coursemodule":201,"name":"Week 3 quiz","intro":"","timeclose":1791500000,"grade":10}]}"#

    static func grades(courseID: Int) -> String {
        if courseID == 6 {
            return #"{"usergrades":[{"courseid":6,"gradeitems":[{"id":3,"itemname":"Week 3 quiz","itemtype":"mod","itemmodule":"quiz","iteminstance":21,"graderaw":7.2,"grademin":0,"grademax":10,"weightraw":0.1},{"id":4,"itemname":null,"itemtype":"course","graderaw":null,"grademin":0,"grademax":100}]}]}"#
        }
        return #"{"usergrades":[{"courseid":5,"gradeitems":[{"id":1,"itemname":"Individual Essay (40%)","itemtype":"mod","itemmodule":"assign","iteminstance":11,"graderaw":null,"grademin":0,"grademax":100,"weightraw":0.4}]}]}"#
    }

    static let forums = #"[{"id":61,"course":5,"type":"news","name":"Announcements","cmid":401},{"id":62,"course":5,"type":"general","name":"Q&A"}]"#

    static func discussions(extra: Bool) -> String {
        let first = #"{"id":1001,"discussion":501,"subject":"Welcome","message":"<p>Hello &amp; welcome to the module.</p>","userfullname":"Dr Smith","created":1790000000,"pinned":false}"#
        let second = #"{"id":1002,"discussion":502,"subject":"Essay deadline moved","message":"<p>Now due a week later.</p>","userfullname":"Dr Smith","created":1790500000,"pinned":true}"#
        return #"{"discussions":["# + (extra ? second + "," : "") + first + "]}"
    }
}
