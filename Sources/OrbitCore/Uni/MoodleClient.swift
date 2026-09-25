import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to Moodle's REST web services with a mobile-app token:
/// `POST {site}/webservice/rest/server.php` with `wstoken`, `wsfunction`,
/// `moodlewsrestformat=json` and the function's parameters.
/// Moodle reports failures as `{exception, errorcode, message}` with HTTP 200;
/// these are thrown as `MoodleError.exception`.
public struct MoodleClient: Sendable {
    public var credentials: MoodleCredentials
    public var http: HTTPClient

    public init(credentials: MoodleCredentials, http: HTTPClient = HTTPClient(timeout: 60)) {
        self.credentials = credentials; self.http = http
    }

    public var siteURL: URL { MoodleAuth.siteRoot(credentials.siteURL) }

    /// Calls any web-service function and returns the raw JSON.
    public func call(_ function: String, _ params: [String: MoodleParam] = [:]) async throws -> MoodleJSON {
        var fields = [("wstoken", credentials.token), ("wsfunction", function), ("moodlewsrestformat", "json")]
        for key in params.keys.sorted() { fields += params[key]!.fields(key) }
        let data = try await http.data("POST", siteURL.appendingPathComponent("webservice/rest/server.php"),
                                       headers: ["Content-Type": "application/x-www-form-urlencoded",
                                                 "Accept": "application/json"],
                                       body: Data(FormEncoding.encode(fields).utf8))
        // Some functions return `null` (an empty body) on success.
        guard !data.isEmpty else { return .null }
        let json: MoodleJSON
        do { json = try MoodleJSON.parse(data) } catch {
            throw MoodleError.unexpectedResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
        if let error = MoodleError.exception(from: json) { throw error }
        return json
    }

    // MARK: Site and courses

    public func siteInfo() async throws -> MoodleSiteInfo {
        MoodleSiteInfo(json: try await call("core_webservice_get_site_info"))
    }

    public func courses(userID: Int) async throws -> [MoodleCourse] {
        try await call("core_enrol_get_users_courses", ["userid": .int(userID)]).array.map(MoodleCourse.init(json:))
    }

    /// Sections and activities on a course page.
    public func contents(courseID: Int) async throws -> [MoodleSection] {
        try await call("core_course_get_contents", ["courseid": .int(courseID)]).array.map(MoodleSection.init(json:))
    }

    /// What changed in a course since a date (optional function on some sites).
    public func updatesSince(courseID: Int, since: Date) async throws -> [MoodleCourseUpdate] {
        let params: [String: MoodleParam] = ["courseid": .int(courseID), "since": .int(Int(since.timeIntervalSince1970))]
        return try await call("core_course_get_updates_since", params)["instances"].array.map(MoodleCourseUpdate.init(json:))
    }

    // MARK: Assessments

    public func assignments(courseIDs: [Int]) async throws -> [MoodleAssignment] {
        guard !courseIDs.isEmpty else { return [] }
        let json = try await call("mod_assign_get_assignments", ["courseids": .ints(courseIDs)])
        return json["courses"].array.flatMap { course in
            course["assignments"].array.map { MoodleAssignment(json: $0, courseID: course["id"].int) }
        }
    }

    public func submissionStatus(assignID: Int) async throws -> MoodleSubmissionStatus {
        MoodleSubmissionStatus(json: try await call("mod_assign_get_submission_status", ["assignid": .int(assignID)]))
    }

    public func quizzes(courseIDs: [Int]) async throws -> [MoodleQuiz] {
        guard !courseIDs.isEmpty else { return [] }
        return try await call("mod_quiz_get_quizzes_by_courses", ["courseids": .ints(courseIDs)])["quizzes"].array
            .map(MoodleQuiz.init(json:))
    }

    /// The ELE timeline: upcoming things to do, across all courses.
    public func actionEvents(from: Date, to: Date? = nil, limit: Int = 50) async throws -> [MoodleActionEvent] {
        var params: [String: MoodleParam] = ["timesortfrom": .int(Int(from.timeIntervalSince1970)), "limitnum": .int(limit)]
        if let to { params["timesortto"] = .int(Int(to.timeIntervalSince1970)) }
        return try await call("core_calendar_get_action_events_by_timesort", params)["events"].array
            .map(MoodleActionEvent.init(json:))
    }

    public func gradeItems(courseID: Int, userID: Int) async throws -> [MoodleGradeItem] {
        let json = try await call("gradereport_user_get_grade_items", ["courseid": .int(courseID), "userid": .int(userID)])
        return json["usergrades"].array.flatMap { $0["gradeitems"].array.map(MoodleGradeItem.init(json:)) }
    }

    // MARK: Forums

    public func forums(courseIDs: [Int]) async throws -> [MoodleForum] {
        guard !courseIDs.isEmpty else { return [] }
        return try await call("mod_forum_get_forums_by_courses", ["courseids": .ints(courseIDs)]).array
            .map(MoodleForum.init(json:))
    }

    /// Latest discussions in a forum. Falls back to the pre-3.7 paginated function.
    public func discussions(forumID: Int, perPage: Int = 10) async throws -> [MoodleDiscussion] {
        do {
            return try await call("mod_forum_get_forum_discussions",
                                  ["forumid": .int(forumID), "page": 0, "perpage": .int(perPage)])["discussions"].array
                .map(MoodleDiscussion.init(json:))
        } catch let error as MoodleError where error.isFunctionUnavailable {
            return try await call("mod_forum_get_forum_discussions_paginated",
                                  ["forumid": .int(forumID), "page": 0, "perpage": .int(perPage),
                                   "sortby": "timemodified", "sortdirection": "DESC"])["discussions"].array
                .map(MoodleDiscussion.init(json:))
        }
    }

    // MARK: Links

    /// Adds the token to a `pluginfile.php` URL from course contents so files can be downloaded.
    public func authenticatedFileURL(_ fileURL: String) -> URL? {
        guard var comps = URLComponents(string: fileURL) else { return nil }
        comps.queryItems = (comps.queryItems ?? []).filter { $0.name != "token" } + [URLQueryItem(name: "token", value: credentials.token)]
        return comps.url
    }

    /// A one-time URL that opens `page` already logged in (for a WKWebView).
    /// Needs the private token from SSO; Moodle rate-limits this to one key every few minutes.
    public func autoLoginURL(to page: URL, userID: Int) async throws -> URL {
        guard let privateToken = credentials.privateToken else {
            throw MoodleError.unexpectedResponse("No private token: sign in with SSO to open ELE pages automatically.")
        }
        let json = try await call("tool_mobile_get_autologin_key", ["privatetoken": .value(privateToken)])
        guard let base = json["autologinurl"].string, let key = json["key"].string,
              var comps = URLComponents(string: base) else { throw MoodleError.unexpectedResponse("\(json)") }
        comps.queryItems = [URLQueryItem(name: "userid", value: String(userID)), URLQueryItem(name: "key", value: key),
                            URLQueryItem(name: "urltogo", value: page.absoluteString)]
        return comps.url!
    }

    public func viewURL(module: String, cmid: Int) -> String { "\(siteURL.absoluteString)/mod/\(module)/view.php?id=\(cmid)" }
    public func courseURL(_ courseID: Int) -> String { "\(siteURL.absoluteString)/course/view.php?id=\(courseID)" }
    public func discussionURL(_ discussionID: Int) -> String { "\(siteURL.absoluteString)/mod/forum/discuss.php?d=\(discussionID)" }
}
