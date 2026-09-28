import Foundation

/// Fixtures shaped like ELE (Moodle 4.x) responses for a first-year BSc Economics student.
enum ELEWebFixtures {
    static func course(_ id: Int, _ full: String, _ short: String, progress: Int = 0, cat: String = "Business School") -> String {
        """
        {"id":\(id),"fullname":"\(full)","shortname":"\(short)","idnumber":"","summary":"","summaryformat":1,
         "startdate":1789430400,"enddate":1812844800,"visible":true,"showactivitydates":true,"showcompletionconditions":true,
         "fullnamedisplay":"\(full)","viewurl":"https://ele.exeter.ac.uk/course/view.php?id=\(id)",
         "courseimage":"data:image/svg+xml;base64,AAAA","progress":\(progress),"hasprogress":true,"isfavourite":false,
         "hidden":false,"showshortname":false,"coursecategory":"\(cat)"}
        """
    }

    static let coursesJSON = """
    [{"error":false,"data":{"courses":[
    \(course(29450, "History of Economic Thought (BEE1032_A_1_202627)", "BEE1032_A_1_202627", progress: 4)),
    \(course(29460, "Economics I (BEE1036_A_1_202627)", "BEE1036_A_1_202627")),
    \(course(29470, "Introduction to Statistics (BEE1022_A_1_202627)", "BEE1022_A_1_202627")),
    \(course(29480, "Mathematics for Economists (BEE1024_A_1_202627)", "BEE1024_A_1_202627")),
    \(course(29490, "Business School Development (BSD1000_A_12_202627)", "BSD1000_A_12_202627")),
    \(course(1200, "Business School Student Information", "BUS_STUDENT_INFO", cat: "Info")),
    \(course(1300, "UEBS Careers &amp; Employability", "UEBS_CAREERS", cat: "Info")),
    \(course(1400, "University Library Skills", "UNI_LIBRARY", cat: "Info")),
    \(course(1500, "ECO BSc Economics Programme Page", "ECO_BSc_ECONOMICS", cat: "Info"))
    ],"nextoffset":9}}]
    """

    static let eventsJSON = """
    [{"error":false,"data":{"events":[
     {"id":880001,"name":"Economics I Problem Set 1 is due","description":"","location":"","categoryid":null,"groupid":null,
      "userid":null,"repeatid":null,"eventcount":null,"component":"mod_assign","modulename":"assign","activityname":"Economics I Problem Set 1",
      "instance":55501,"eventtype":"due","timestart":1792584000,"timeduration":0,"timesort":1792584000,"timeusermidnight":1792540800,
      "visible":1,"timemodified":1790000000,"course":{"id":29460,"fullname":"Economics I (BEE1036_A_1_202627)","shortname":"BEE1036_A_1_202627",
      "viewurl":"https://ele.exeter.ac.uk/course/view.php?id=29460"},
      "url":"https://ele.exeter.ac.uk/mod/assign/view.php?id=990001","action":{"name":"Add submission","url":"https://ele.exeter.ac.uk/mod/assign/view.php?id=990001&action=editsubmission","itemcount":1,"actionable":true}},
     {"id":880002,"name":"HET Essay submission is due","modulename":"assign","instance":55502,"eventtype":"due",
      "timestart":1794841200,"timesort":1794841200,"course":{"id":29450,"fullname":"History of Economic Thought (BEE1032_A_1_202627)","shortname":"BEE1032_A_1_202627"},
      "url":"https://ele.exeter.ac.uk/mod/assign/view.php?id=990002","action":{"name":"Add submission","itemcount":1,"actionable":true}},
     {"id":880003,"name":"Library quiz closes","modulename":"quiz","instance":66,"timesort":1792000000,
      "course":{"id":1400,"fullname":"University Library Skills","shortname":"UNI_LIBRARY"},"url":"https://ele.exeter.ac.uk/mod/quiz/view.php?id=4","action":null}
    ]}}]
    """

    static let expiredJSON = """
    [{"error":true,"exception":{"message":"Web service is not available (it doesn't exist or might be disabled)","errorcode":"servicerequireslogin","link":"https://ele.exeter.ac.uk/","moreinfourl":""}}]
    """

    static func activity(_ cmid: Int, _ mod: String, _ name: String, desc: String = "", hide: String = "File") -> String {
        """
        <li class="activity activity-wrapper \(mod) modtype_\(mod) hasinfo" id="module-\(cmid)" data-for="cmitem" data-id="\(cmid)" data-indexed="true">
          <div class="activity-item focus-control" data-activityname="\(name)" data-region="activity-card">
            <div class="activity-basis d-flex align-items-center">
              <div class="activity-instance d-flex flex-column"><div class="activitytitle media modtype_\(mod) position-relative align-self-start">
                <div class="activityiconcontainer content courseicon align-self-start me-3"><img src="https://ele.exeter.ac.uk/theme/image.php/boost/\(mod)/1/monologo" class="activityicon" alt=""></div>
                <div class="media-body align-self-center"><div class="activityname">
                  <a href="https://ele.exeter.ac.uk/mod/\(mod)/view.php?id=\(cmid)" class=" aalink stretched-link" onclick="">
                    <span class="instancename">\(name) <span class="accesshide " > \(hide)</span></span></a>
                </div></div></div></div>
              <div class="activity-information"><div data-region="completion-info"><button class="btn btn-sm">Mark as done</button></div></div>
            </div>
            \(desc.isEmpty ? "" : "<div class=\"activity-altcontent text-break d-flex\"><div class=\"no-overflow\"><p>\(desc)</p></div></div>")
          </div>
        </li>
        """
    }

    static func label(_ cmid: Int, _ html: String) -> String {
        """
        <li class="activity activity-wrapper label modtype_label" id="module-\(cmid)" data-for="cmitem" data-id="\(cmid)">
          <div class="activity-item focus-control activityinline" data-activityname="label" data-region="activity-card">
            <div class="activity-altcontent"><div class="no-overflow"><div class="no-overflow">\(html)</div></div></div>
          </div>
        </li>
        """
    }

    static func section(_ num: Int, id: Int, _ title: String, summary: String = "", _ activities: [String]) -> String {
        """
        <li id="section-\(num)" class="section course-section main clearfix" data-sectionid="\(id)" data-number="\(num)" data-for="section" data-id="\(id)" aria-labelledby="sectionid-\(id)-title">
          <div class="course-section-header d-flex" data-for="section_title" data-id="\(id)" data-number="\(num)">
            <h3 class="h4 sectionname course-content-item d-flex align-self-stretch align-items-center mb-0" id="sectionid-\(id)-title" data-for="section_title" data-id="\(id)" data-number="\(num)">
              <a href="https://ele.exeter.ac.uk/course/section.php?id=\(id)">\(title)</a></h3>
          </div>
          <div id="coursecontentcollapse\(num)" class="content course-content-item-content collapse show">
            <div class="summarytext"><div class="no-overflow">\(summary)</div></div>
            <ul class="section m-0 p-0 img-text  d-block " data-for="cmlist">
            \(activities.joined(separator: "\n"))
            </ul>
          </div>
        </li>
        """
    }

    static let assessmentTable = """
    <table class="table table-bordered">
      <thead><tr><th></th><th>Assessment 1</th><th>Assessment 2</th></tr></thead>
      <tbody>
        <tr><td><strong>Deadline</strong></td><td>16 November</td><td>TBA: week 1 of term2</td></tr>
        <tr><td><strong>Title</strong></td><td>essay</td><td>exam</td></tr>
        <tr><td>Formative/Summative</td><td>Summative</td><td>Summative</td></tr>
        <tr><td>Type</td><td>Essay</td><td>Written examination</td></tr>
        <tr><td>Format</td><td>Word or PDF file via ELE</td><td>In person, closed book</td></tr>
        <tr><td>Value</td><td>20%</td><td>80%</td></tr>
        <tr><td>Word Count/Time</td><td>1500 words + 10%</td><td>1&frac12; hours</td></tr>
        <tr><td>AI status</td><td>AI-assisted (declare use)</td><td>Not permitted</td></tr>
      </tbody>
    </table>
    """

    static let briefText = """
    BEE1032 History of Economic Thought
    Essay Assessment Brief -- questions, deadline (3pm 16 November, as word or pdf file), marking criteria.
    Answer ONE of the following questions in no more than 1500 words.
    1. Was Adam Smith a free-market economist?
    """

    static let courseHTML = """
    <!DOCTYPE html><html><head><title>Course: History of Economic Thought</title>
    <script>M.cfg = {"wwwroot":"https:\\/\\/ele.exeter.ac.uk","sesskey":"AbC123xyZ9","sessiontimeout":"28800"};</script></head>
    <body id="page-course-view-topics"><div class="course-content"><ul class="topics" data-for="course_sectionlist">
    \(section(0, id: 700, "General", summary: "<p>Welcome to BEE1032.</p>", [activity(990010, "forum", "Announcements", hide: "Forum")]))
    \(section(1, id: 701, "Assessment (including essay due in 16 November)", summary: assessmentTable, [
        activity(990020, "resource", "Essay Assessment Brief -- questions, deadline (3pm 16 November, as word or pdf file)"),
        activity(990002, "assign", "HET Essay submission", hide: "Assignment"),
    ]))
    \(section(2, id: 702, "Access Your Reading List", [activity(990030, "lti", "BEE1032 Reading List", hide: "External tool")]))
    \(section(3, id: 703, "Recap Recordings", [activity(990040, "url", "Lecture recordings (Panopto)", hide: "URL")]))
    \(section(4, id: 704, "Week 1 W/c 21 September", [
        activity(990101, "resource", "Week 1 lecture slides"),
        activity(990102, "resource", "Week 1 handout"),
        label(990103, "<p><strong>Tutorial: </strong>What is economic thought?</p>"),
        label(990104, "<p>Reading for week 1: Heilbroner, The Worldly Philosophers, ch. 1</p>"),
        activity(990105, "resource", "guide to reading, week 1"),
    ]))
    \(section(6, id: 706, "Week 3 W/c 5 October", [
        activity(990301, "resource", "Week 3 slides: Adam Smith"),
        label(990302, "<p>Tutorial: Smith on the division of labour</p><p>Reading for week 3: Smith, Wealth of Nations, Book I ch. 1-3</p>"),
    ]))
    \(section(15, id: 715, "Week 12 W/c 7 December", []))
    \(section(16, id: 716, "Past papers", [activity(990901, "resource", "BEE1032 exam 2025-26")]))
    \(section(17, id: 717, "GOOD ANSWERS FROM LAST YEAR", [activity(990902, "folder", "First-class essays 2025", hide: "Folder")]))
    </ul></div></body></html>
    """

    static let courseStateJSON: String = {
        let state = """
        {"course":{"id":"29450","numsections":17},"section":[
          {"id":"701","section":1,"number":1,"title":"Assessment (including essay due in 16 November)","cmlist":["990020"],"sectionurl":"https://ele.exeter.ac.uk/course/section.php?id=701"},
          {"id":"704","section":4,"number":4,"title":"Week 1 W/c 21 September","cmlist":["990101","990104"],"sectionurl":"https://ele.exeter.ac.uk/course/section.php?id=704"}],
         "cm":[{"id":"990020","name":"Essay Assessment Brief","module":"resource","sectionid":"701","url":"https://ele.exeter.ac.uk/mod/resource/view.php?id=990020"},
               {"id":"990101","name":"Week 1 lecture slides","module":"resource","sectionid":"704","url":"https://ele.exeter.ac.uk/mod/resource/view.php?id=990101"},
               {"id":"990104","name":"Reading for week 1: Heilbroner, ch. 1","module":"label","sectionid":"704"}]}
        """
        let escaped = String(data: try! JSONSerialization.data(withJSONObject: [state], options: []), encoding: .utf8)!
        // escaped is ["…"]; take the string literal inside.
        let literal = escaped.dropFirst().dropLast()
        return "[{\"error\":false,\"data\":\(literal)}]"
    }()
}
