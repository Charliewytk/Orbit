import XCTest
@testable import OrbitCore

final class ELEActivityTests: XCTestCase {
    typealias F = AcademicFixtures

    func ajax(_ data: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: [["error": false, "data": data]])
    }

    func testNotifications() throws {
        let data = ajax(["notifications": [
            ["id": 11, "subject": "BEE1022: Your submission has been graded", "smallmessage": "<p>Feedback is available</p>",
             "contexturl": "https://ele.exeter.ac.uk/mod/assign/view.php?id=77", "timecreated": 1_790_000_000, "read": false,
             "component": "mod_assign"],
            ["id": 12, "subject": "New forum post", "fullmessage": "Hello", "timecreated": 1_790_000_100, "read": true],
        ], "unreadcount": 1])
        let n = try ELELive.notifications(fromAJAX: data)
        XCTAssertEqual(n.map(\.id), [11, 12])
        XCTAssertEqual(n[0].text, "Feedback is available")
        let items = ELELive.activity(notifications: n)
        XCTAssertEqual(items[0].kind, .grade)
        XCTAssertEqual(items[0].moduleCode, "BEE1022")
        XCTAssertTrue(items[0].important)
        XCTAssertFalse(items[1].important)
    }

    func testConversationsForumsGradesUpdates() throws {
        let conv = try ELELive.conversations(fromAJAX: ajax(["conversations": [
            ["id": 5, "name": "", "members": [["fullname": "Dr Smith"]], "unreadcount": 2,
             "messages": [["id": 900, "text": "<p>See you at 2</p>", "timecreated": 1_790_000_000]]],
        ]]))
        XCTAssertEqual(conv.first?.name, "Dr Smith")
        XCTAssertEqual(ELELive.activity(conversations: conv).first?.id, "message-5-900")

        let forums = try ELELive.forums(fromAJAX: ajax([["id": 3, "course": 9001, "cmid": 44, "name": "Announcements", "type": "news"]]))
        XCTAssertTrue(forums[0].isNews)
        let posts = try ELELive.discussions(fromAJAX: ajax(["discussions": [
            ["discussion": 70, "subject": "Room change", "message": "<p>Lecture moves to Streatham Court</p>",
             "userfullname": "Dr Smith", "created": 1_790_000_000, "timemodified": 1_790_000_500],
        ]]), forumID: 3)
        let post = ELELive.activity(discussions: posts, forum: forums[0], moduleCode: "BEE1022")
        XCTAssertEqual(post.first?.kind, .announcement)
        XCTAssertEqual(post.first?.title, "Announcement: Room change")

        let grades = try ELELive.gradeItems(fromAJAX: ajax(["usergrades": [["courseid": 9001, "gradeitems": [
            ["id": 1, "itemname": "Essay", "itemtype": "mod", "itemmodule": "assign", "cmid": 77, "gradeformatted": "68.00",
             "percentageformatted": "68.00 %", "feedback": "<p>Good structure; more critical analysis needed.</p>", "gradedategraded": 1_790_000_000],
            ["id": 2, "itemname": "Quiz", "itemtype": "mod", "gradeformatted": "-", "percentageformatted": "-"],
            ["id": 3, "itemname": "Course total", "itemtype": "course", "gradeformatted": "68"],
        ]]]]))
        XCTAssertEqual(grades.count, 2)
        XCTAssertEqual(grades[0].percentage, 68)
        XCTAssertEqual(grades[0].feedback, "Good structure; more critical analysis needed.")
        XCTAssertNil(grades[1].grade)
        let gradeItems = ELELive.activity(grades: grades, moduleCode: "BEE1022")
        XCTAssertEqual(gradeItems.count, 1)
        XCTAssertEqual(gradeItems[0].title, "Grade released: Essay")

        let updates = try ELELive.updatedModules(fromAJAX: ajax(["instances": [
            ["contextlevel": "module", "id": 5003, "updates": [["name": "contentfiles", "timeupdated": 1_790_000_000]]],
            ["contextlevel": "module", "id": 5004, "updates": []],
        ], "warnings": []]))
        XCTAssertEqual(updates, [5003: ["contentfiles"]])

        let status = try ELELive.submissionStatus(fromAJAX: ajax([
            "lastattempt": ["submission": ["status": "submitted"], "gradingstatus": "graded"],
            "feedback": ["gradefordisplay": "68.00 / 100.00", "gradeddate": 1_790_000_000,
                         "plugins": [["type": "comments", "editorfields": [["text": "<p>Use more evidence.</p>"]]],
                                     ["type": "file", "fileareas": [["files": [["filename": "marked.pdf"]]]]]]],
        ]))
        XCTAssertEqual(status.status, "submitted")
        XCTAssertEqual(status.feedbackComments, "Use more evidence.")
        XCTAssertTrue(status.hasFeedbackFiles)
    }

    func testGradeReportHTMLAndUserID() {
        let html = """
        <table class="user-grade"><tr><th class="level2 column-itemname"><a href="https://ele.exeter.ac.uk/mod/assign/view.php?id=77">Essay</a></th>
        <td class="column-grade">68.00</td><td class="column-percentage">68.00 %</td><td class="column-feedback">Well argued</td></tr>
        <tr><th class="column-itemname">Course total</th><td class="column-grade">68</td></tr></table>
        <div data-userid="4321"></div>
        """
        let items = ELELive.gradeItems(fromReportHTML: html, courseID: 9001)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].cmid, 77)
        XCTAssertEqual(items[0].percentage, 68)
        XCTAssertEqual(items[0].feedback, "Well argued")
        XCTAssertEqual(ELELive.userID(inHTML: html), 4321)
    }

    func testMyAssessmentsBlock() {
        let html = """
        <section class="block_myassessments block"><h5>My Assessments</h5>
        <table><tr><th>Module</th><th>Assessment</th><th>Deadline</th><th>Status</th></tr>
        <tr><td>BEE1022</td><td><a href="https://ele.exeter.ac.uk/mod/assign/view.php?id=77">Data project</a></td><td>8 October 2026 12:00</td><td>Not submitted</td></tr>
        <tr><td>BEE1032</td><td>Essay</td><td>16 November 3pm</td><td>Submitted</td></tr></table></section>
        <section class="block_other">Other</section>
        """
        let rows = ELELive.myAssessments(fromDashboardHTML: html, academicYear: 2026)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].moduleCode, "BEE1022")
        XCTAssertEqual(rows[0].title, "Data project")
        XCTAssertEqual(rows[0].due, F.d(2026, 10, 8, 12))
        XCTAssertEqual(rows[0].status?.lowercased(), "not submitted")
        XCTAssertEqual(rows[1].due, F.d(2026, 11, 16, 15))
    }

    func testFeedDiffAndDedupe() {
        let old = F.snapshot()
        var new = F.snapshot()
        new.fetchedAt = F.d(2026, 9, 29, 9)
        var content = new.contents["BEE1022"]!
        content.sections[2].items.append(ELEWebItem(cmid: 5030, name: "Problem set 2", kind: .resource, role: .handout,
                                                    url: "https://ele.exeter.ac.uk/mod/resource/view.php?id=5030"))
        new.contents["BEE1022"] = ELEWebCourseContent(courseID: 9001, moduleCode: "BEE1022", sections: content.sections)
        let items = ELEActivityFeed.changes(from: old, to: new)
        let file = items.first { $0.id == "cm-5030-new" }
        XCTAssertEqual(file?.title, "New file in week 2: Problem set 2")
        XCTAssertEqual(file?.important, true)
        XCTAssertTrue(items.contains { $0.kind == .weekUpdated })
        var feed = ELEActivityFeed()
        XCTAssertEqual(feed.add(items).count, items.count)
        XCTAssertTrue(feed.add(items).isEmpty, "seen items aren't re-announced")
        XCTAssertTrue(ELEActivityFeed.changes(from: nil, to: new).isEmpty)

        var kb = F.knowledge()
        let fresh = kb.recordActivity([ELEActivityItem(id: "forum-1", kind: .announcement, moduleCode: "BEE1022",
                                                       title: "Announcement: Room change",
                                                       detail: "Thursday's lecture moves to Streatham Court lecture theatre B.",
                                                       date: F.d(2026, 9, 24))])
        XCTAssertEqual(fresh.count, 1)
        XCTAssertEqual(kb.search("Streatham Court").first?.document.kind, .announcement)
    }

    func testFeedbackIntoKnowledge() {
        var kb = F.knowledge()
        let fb = AssessmentFeedback(id: "fb-1", moduleCode: "BEE1022", assessmentTitle: "Essay", mark: 62,
                                    comments: "Needs more critical analysis. Referencing was inconsistent.")
        kb.addFeedback(fb)
        kb.feedback.ingest(fb, points: FeedbackThemeExtractor.heuristic(fb.comments))
        XCTAssertEqual(kb.search("referencing", kinds: [.feedback]).first?.document.id, "feedback-fb-1")
        XCTAssertFalse(kb.feedbackReminders(moduleCode: "BEE1022").isEmpty)
    }
}
