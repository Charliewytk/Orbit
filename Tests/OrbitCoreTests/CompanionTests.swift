import XCTest
@testable import OrbitCore

final class CompanionTests: XCTestCase {
    let cal = DayCalendar()
    func day(_ d: Int, _ m: Int = 10, _ h: Int = 9, _ y: Int = 2026) -> Date { cal.date(year: y, month: m, day: d, hour: h)! }

    // MARK: Grades

    func testGradeRequirementsAndProjection() {
        var book = GradeBook()
        let mods = [Module(code: "BEE1025", name: "Macroeconomics", credits: 15), Module(code: "BEE1026", name: "Microeconomics", credits: 15)]
        let a = [
            Assessment(id: "e1", moduleCode: "BEE1025", title: "Essay", weightPercent: 40, mark: 65),
            Assessment(id: "x1", moduleCode: "BEE1025", title: "Exam", kind: .exam, weightPercent: 60),
            Assessment(id: "t1", moduleCode: "BEE1026", title: "Test", weightPercent: 50, mark: 80),
            Assessment(id: "x2", moduleCode: "BEE1026", title: "Exam", kind: .exam, weightPercent: 50),
        ]
        book.merge(modules: mods, assessments: a)
        let p = GradePredictor.project(book)
        let macro = p.modules.first { $0.code == "BEE1025" }!
        // 70*100 - 65*40 = 4400 over 60 → 73.3
        XCTAssertEqual(macro.requiredByTarget[70]!, 73.33, accuracy: 0.01)
        XCTAssertEqual(macro.requiredByTarget[80]!, 90, accuracy: 0.01)
        XCTAssertEqual(macro.requirements.first { $0.target == 70 }?.required, 73.3)
        XCTAssertEqual(p.yearAverage!, 72.5, accuracy: 0.01)
        XCTAssertEqual(p.yearProjected!, 72.5, accuracy: 0.01)
        XCTAssertEqual(p.classification, "First")
        // Year: secured 15*26 + 15*40 = 990; open 15*.6+15*.5 = 16.5; (70*30-990)/16.5 = 67.27
        XCTAssertEqual(p.yearRequired[70]!, 67.27, accuracy: 0.01)
    }

    func testEditedRowsSurviveSync() {
        var book = GradeBook()
        let mods = [Module(code: "BEE1025", name: "Macro")]
        book.merge(modules: mods, assessments: [Assessment(id: "e1", moduleCode: "BEE1025", title: "Essay", weightPercent: 40)])
        book.edit(module: "BEE1025", item: "e1", weight: 30, mark: .some(68))
        book.merge(modules: mods, assessments: [Assessment(id: "e1", moduleCode: "BEE1025", title: "Essay", weightPercent: 40)])
        XCTAssertEqual(book.modules[0].items[0].weight, 30)
        XCTAssertEqual(book.modules[0].items[0].mark, 68)
    }

    // MARK: Lectures

    func testDetectsPanoptoEchoAndCaptions() {
        let html = """
        <iframe title="Lecture 3: IS-LM" src="https://exeter.cloud.panopto.eu/Panopto/Pages/Embed.aspx?id=0a1b2c3d-1111-2222-3333-444455556666&amp;autoplay=false"></iframe>
        <a href="https://echo360.org.uk/media/9f8e7d6c-aaaa-bbbb-cccc-ddddeeeeffff/public">Week 2 recording</a>
        <a href="https://ele.exeter.ac.uk/pluginfile.php/1/captions.vtt">Captions</a>
        """
        let found = RecordingDetector.detect(html: html, pageTitle: "BEE1025", moduleCode: "BEE1025")
        XCTAssertEqual(found.count, 2)
        let p = found.first { $0.platform == .panopto }!
        XCTAssertEqual(p.id, "panopto:0a1b2c3d-1111-2222-3333-444455556666")
        XCTAssertEqual(p.title, "Lecture 3: IS-LM")
        XCTAssertEqual(p.captionURLs.count, 1)
        XCTAssertTrue(p.panoptoCaptionURL!.contains("GenerateSRT.ashx?id=0a1b2c3d"))
        XCTAssertEqual(found.first { $0.platform == .echo360 }?.title, "Week 2 recording")
    }

    func testCaptionParsing() {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\n<v Lecturer>Today we look at inflation.\n\n00:00:03.000 --> 00:00:05,000\nToday we look at inflation.\n\n2\n00:01:02,500 --> 00:01:04,000\nThe Phillips curve."
        let cues = CaptionParser.cues(vtt)
        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[2].start, 62.5, accuracy: 0.01)
        XCTAssertEqual(CaptionParser.transcript(vtt), "Today we look at inflation. The Phillips curve.")
        XCTAssertEqual(TranscriptSource.choose(hasCaptions: false, appleSpeechOnDevice: false, whisperPath: "/usr/local/bin/whisper"), .whisper)
        XCTAssertEqual(TranscriptSource.choose(hasCaptions: true, appleSpeechOnDevice: true, whisperPath: nil), .captions)
    }

    func testNotesGapFindsMissedTerms() async {
        let transcript = String(repeating: "The Phillips curve links inflation and unemployment. Adaptive expectations shift the Phillips curve over time. ", count: 3)
            + String(repeating: "The natural rate of unemployment is where inflation is stable. ", count: 3)
        let notes = "Phillips curve: inflation vs unemployment trade-off."
        let report = LectureDigester.compare(transcript: transcript, notes: notes)
        XCTAssertTrue(report.missedTerms.contains { $0.contains("adaptive") || $0.contains("natural") })
        XCTAssertFalse(report.missedTerms.contains("phillips curve"))
        XCTAssertFalse(report.suggestions.isEmpty)
        let rec = LectureRecording(id: "media:x", platform: .media, url: "https://x/a.mp4", title: "L5")
        let d = await LectureDigester.digest(recording: rec, transcript: transcript, source: .captions, notes: notes, router: nil)
        XCTAssertFalse(d.summary.isEmpty)
        XCTAssertNotNil(d.gaps)

        var ledger = RecordingLedger()
        XCTAssertEqual(ledger.register([rec]).count, 1)
        ledger.processed.insert(rec.id)
        XCTAssertEqual(ledger.register([rec]).count, 0)
    }

    // MARK: Exam countdown

    func testExamPlanMixesPapersAndTopics() {
        let now = day(1, 5)
        let exams = [Assessment(id: "x", moduleCode: "BEE1025", title: "Exam", kind: .exam, weightPercent: 60, due: day(20, 5)),
                     Assessment(id: "far", moduleCode: "BEE1026", title: "Exam", kind: .exam, weightPercent: 60, due: day(30, 8))]
        let papers = [ExamMode.PastPaper(id: "p1", moduleCode: "BEE1025", title: "2024 paper", url: nil, minutes: 90, year: 2024)]
        let weak = [ExamMode.TopicSignal(topic: "IS-LM", moduleCode: "BEE1025", reasons: ["low flashcard ease"], score: 3)]
        let plan = ExamCountdownPlanner(calendar: cal).plan(assessments: exams, pastPapers: papers, weakTopics: weak, now: now)
        XCTAssertTrue(plan.isActive)
        XCTAssertEqual(plan.exams.filter(\.inWindow).count, 1)
        XCTAssertTrue(plan.sessions.allSatisfy { $0.moduleCode == "BEE1025" })
        XCTAssertTrue(plan.sessions.contains { $0.kind == .pastPaper })
        XCTAssertTrue(plan.sessions.contains { $0.kind == .weakTopic })
        XCTAssertTrue(plan.sessions.contains { $0.kind == .mock })
        XCTAssertFalse(plan.sessions.contains { cal.isSameDay($0.day, day(20, 5)) })
    }

    // MARK: Groups

    func testGroupWork() {
        let me = GroupProject.Member(name: "Me", isMe: true), sam = GroupProject.Member(name: "Sam")
        var p = GroupProject(name: "Policy brief", moduleCode: "BEE1025", deadline: day(10), members: [me, sam])
        p.tasks = [.init(title: "Lit review", assigneeID: me.id, due: day(3)), .init(title: "Data", assigneeID: sam.id, due: day(2), done: true)]
        p.contributions = [.init(date: day(1), summary: "Drafted intro", minutes: 90)]
        XCTAssertEqual(p.myOpenTasks.map(\.title), ["Lit review"])
        XCTAssertEqual(p.progress, 0.5)
        XCTAssertEqual(p.overdue(now: day(4)).count, 1)
        XCTAssertTrue(p.contributionReport(calendar: cal).contains("Drafted intro (90 min)"))
        let board = GroupWorkBoard(projects: [p])
        XCTAssertEqual(board.myDue(now: day(1), days: 7).count, 1)
    }

    // MARK: News

    func testRSSAndLinking() {
        let rss = """
        <?xml version="1.0"?><rss><channel><title>BBC</title>
        <item><title>Bank of England holds interest rates as inflation eases</title><link>https://bbc.co.uk/1</link>
        <description><![CDATA[<p>The Bank kept Bank Rate at 4%.</p>]]></description><pubDate>Sat, 26 Sep 2026 06:00:00 +0000</pubDate></item>
        <item><title>CMA blocks supermarket merger over competition fears</title><link>https://bbc.co.uk/2</link><description>Monopoly worries.</description></item>
        <item><title>Celebrity wedding</title><link>https://bbc.co.uk/3</link></item>
        </channel></rss>
        """
        let stories = RSSParser.parse(Data(rss.utf8), source: "BBC Business")
        XCTAssertEqual(stories.count, 3)
        XCTAssertEqual(stories[0].summary, "The Bank kept Bank Rate at 4%.")
        XCTAssertNotNil(stories[0].published)
        let mods = [Module(code: "BEE1025", name: "Macroeconomics"), Module(code: "BEE1026", name: "Microeconomics")]
        let linker = NewsLinker(moduleConcepts: NewsLinker.defaultModuleConcepts(mods))
        let picked = linker.pick(stories, now: day(26, 9, 12))
        XCTAssertEqual(picked.count, 2)
        XCTAssertEqual(picked.first { $0.story.url == "https://bbc.co.uk/1" }?.moduleCode, "BEE1025")
        XCTAssertEqual(picked.first { $0.story.url == "https://bbc.co.uk/2" }?.moduleCode, "BEE1026")

        let atom = "<feed xmlns=\"http://www.w3.org/2005/Atom\"><entry><title>Gilt yields rise</title><link href=\"https://x/a\"/><updated>2026-09-26T05:00:00Z</updated></entry></feed>"
        XCTAssertEqual(RSSParser.parse(Data(atom.utf8), source: "FT").first?.url, "https://x/a")
    }

    func testNewsletterExtraction() {
        XCTAssertTrue(NewsFeeds.isNewsletter(from: "The Economist <newsletters@e.economist.com>"))
        XCTAssertFalse(NewsFeeds.isNewsletter(from: "friend@gmail.com"))
        let body = "View in browser\nWhy the Bank of England is cutting rates slowly\nInflation is proving sticky in services, the Bank says.\nhttps://www.economist.com/a\nUnsubscribe"
        let s = NewsletterStories.extract(subject: "The Economist today", from: "x@e.economist.com", body: body, date: day(26, 9))
        XCTAssertEqual(s.first?.title, "Why the Bank of England is cutting rates slowly")
        XCTAssertEqual(s.first?.url, "https://www.economist.com/a")
    }

    // MARK: Briefing and weekly review

    func testWeatherAndSchedule() {
        let json = #"{"current":{"temperature_2m":11.2,"weather_code":61},"daily":{"weather_code":[63],"temperature_2m_max":[14.6],"temperature_2m_min":[8.9],"precipitation_probability_max":[70]}}"#
        let w = OpenMeteo.parse(Data(json.utf8))!
        XCTAssertEqual(w.line, "Rain, 9–15°C, 70% chance of rain. Take a coat or umbrella.")
        XCTAssertTrue(OpenMeteo.forecastURL().absoluteString.contains("latitude=50.7236"))
        let s = BriefingSchedule()
        XCTAssertFalse(s.isDue(now: day(26, 9, 7), lastDay: nil, calendar: cal))
        XCTAssertTrue(s.isDue(now: day(26, 9, 8), lastDay: nil, calendar: cal))
        XCTAssertFalse(s.isDue(now: day(26, 9, 8), lastDay: day(26, 9, 7), calendar: cal))
        let r = WeekRecapSchedule()
        XCTAssertTrue(r.isDue(now: day(26, 9, 20), lastRun: nil, calendar: cal))   // Saturday
        XCTAssertTrue(r.isDue(now: day(27, 9, 20), lastRun: day(26, 9, 20), calendar: cal)) // Sunday
        XCTAssertFalse(r.isDue(now: day(28, 9, 20), lastRun: nil, calendar: cal))  // Monday
    }

    func testWeekRecapAndBriefing() {
        let now = day(26, 9, 19)
        var done = OrbitTask(title: "Problem set 1", estimateMinutes: 60, deadline: day(24, 9))
        done.completedAt = day(24, 9)
        let late = OrbitTask(title: "Reading ch.2", estimateMinutes: 30, deadline: day(25, 9))
        let next = OrbitTask(title: "Essay plan", estimateMinutes: 60, deadline: day(29, 9))
        let recap = WeekRecapBuilder(calendar: cal).build(now: now, tasks: [done, late, next],
                                                          assessments: [Assessment(id: "a", moduleCode: "BEE1025", title: "Quiz 1", due: day(1, 10))],
                                                          events: [], days: [DayStats(day: "2026-09-24", studyMinutes: 120, tasksDone: 1)])
        XCTAssertEqual(recap.tasksDone, 1)
        XCTAssertEqual(recap.tasksPlanned, 2)
        XCTAssertEqual(recap.studyMinutes, 120)
        XCTAssertEqual(recap.slipping.count, 1)
        XCTAssertEqual(recap.nextWeek.count, 2)

        let brief = MorningBriefBuilder().build(now: day(26, 9, 7), events: [], blocks: [], tasks: [next])
        let mail = EmailDigest(id: "m", account: .gmail, from: "tutor@exeter.ac.uk", subject: "Seminar moved", date: day(26, 9, 6),
                               category: .urgent, summary: "Now 2pm", importance: 0.8)
        let b = DailyBriefing(day: day(26, 9, 0), generatedAt: now, weather: nil, brief: brief, newOnELE: [], keyEmail: DailyBriefing.keyEmail([mail], now: now),
                              streakDays: 4, flashcardStreak: 0, news: [], weeklyReview: recap, groupTasksDue: [], examLine: nil)
        XCTAssertTrue(b.isSaturday)
        XCTAssertEqual(b.keyEmail?.id, "m")
        XCTAssertTrue(b.plainText().contains("Weekly review"))
        XCTAssertTrue(b.notificationBody.contains("4-day streak"))
    }

    // MARK: Money

    func testMoneyOverviewAlerts() {
        let now = day(26, 9, 12)
        var txs: [MoneyTransaction] = []
        for w in 1...6 {
            txs.append(MoneyTransaction(id: "g\(w)", accountID: "a", date: cal.addingDays(-7 * w, to: now), amountPence: -2500, name: "Tesco",
                                        descriptionText: "", bankCategory: "groceries", source: .monzoCSV))
        }
        txs.append(MoneyTransaction(id: "g0", accountID: "a", date: cal.addingDays(-1, to: now), amountPence: -9000, name: "Tesco",
                                    descriptionText: "", bankCategory: "groceries", source: .monzoCSV))
        let o = MoneyInsights.overview(txs, categoriser: Categoriser(), now: now, calendar: cal)
        XCTAssertEqual(o.thisWeekPence, 9000)
        XCTAssertEqual(o.typicalWeekPence, 2500)
        XCTAssertEqual(o.termLabel, "Autumn term")
        XCTAssertTrue(o.alerts.contains { $0.kind == .categorySpike })
        XCTAssertTrue(o.alerts.contains { $0.kind == .largePayment })
        XCTAssertEqual(MoneyInsights.pounds(1234), "£12.34")
    }

    // MARK: Chat memory

    func testUniversalSearchAndArchive() async throws {
        let docs = [
            SearchDocument(id: "1", kind: .mail, title: "Seminar moved to Thursday", text: "Your BEE1025 seminar is now Thursday 2pm", date: day(25, 9)),
            SearchDocument(id: "2", kind: .task, title: "Essay plan", text: "Plan the macro essay"),
            SearchDocument(id: "3", kind: .grade, title: "BEE1026 test", text: "Mark 72"),
        ]
        let hits = UniversalSearch(documents: docs).search("when is my seminar", now: day(26, 9))
        XCTAssertEqual(hits.first?.document.id, "1")
        XCTAssertTrue(UniversalSearch.citedText(hits, calendar: cal).hasPrefix("[1] Mail · Seminar moved"))
        let tool = UniversalSearch.tool(calendar: cal) { docs }
        let out = try await tool.run(["query": .string("essay"), "kind": .string("task")])
        XCTAssertTrue(out.contains("Essay plan"))

        var archive = ChatArchive()
        archive.append(.init(role: .user, text: "What did I get in the micro test?"))
        archive.append(.init(role: .assistant, text: "72 [1]."))
        XCTAssertEqual(archive.searchDocuments.count, 1)
        XCTAssertEqual(ChatArchive.citationNumbers(in: "See [1] and [2], again [1]."), [1, 2])
        let data = try JSONEncoder().encode(archive)
        XCTAssertEqual(try JSONDecoder().decode(ChatArchive.self, from: data).messages.count, 2)
    }
}

final class CompanionExtraTests: XCTestCase {
    func testArticleTextAndNotesMatch() {
        let html = "<nav><p>Menu item that is long enough to be counted as text</p></nav><article><h1>T</h1><p>Central banks are weighing how quickly to cut rates this year.</p><p>short</p></article>"
        XCTAssertEqual(ArticleText.extract(html: html), "Central banks are weighing how quickly to cut rates this year.")

        let cal = DayCalendar()
        let r = LectureRecording(id: "panopto:1", platform: .panopto, url: "https://x", title: "Lecture 4 Phillips curve", moduleCode: "BEE1025", week: 4)
        let seg = NoteSegment(kind: .typed, text: "Phillips curve notes")
        let good = LectureNote(id: "n1", title: "Phillips curve", notebook: "Macro", section: "", moduleCode: "BEE1025", week: 4,
                               created: cal.date(year: 2026, month: 10, day: 20)!, modified: Date(), segments: [seg])
        let other = LectureNote(id: "n2", title: "Elasticity", notebook: "Micro", section: "", moduleCode: "BEE1026", week: 4,
                                created: Date(), modified: Date(), segments: [seg])
        XCTAssertEqual(RecordingNotesMatcher.best(for: r, notes: [other, good], calendar: cal)?.id, "n1")
    }
}
