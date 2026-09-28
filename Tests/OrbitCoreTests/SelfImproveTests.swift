import XCTest
@testable import OrbitCore

final class SelfImproveTests: XCTestCase {
    let config = SelfImproveConfig(sourceDir: "/Users/me/Library/Application Support/Orbit/Source")

    func testDefaultPaths() {
        XCTAssertEqual(SelfImproveConfig.defaultSourceDir(appSupport: "/AS"), "/AS/Orbit/Source")
        XCTAssertEqual(SelfImproveConfig.backupsDir(appSupport: "/AS"), "/AS/Orbit/Backups")
        XCTAssertTrue(config.builtAppPath.hasSuffix("Source/build/Build/Products/Release/Orbit.app"))
    }

    func testCloneAndPull() {
        let clone = SelfImproveCommands.clone(config)
        XCTAssertEqual(clone[0].args, ["clone", "--branch", "claude/zealous-albattani-h2xkcz", "https://github.com/Charliewytk/Orbit.git", config.sourceDir])
        XCTAssertEqual(clone[1].args, ["checkout", "-B", "local/improvements"])
        XCTAssertEqual(clone[1].cwd, config.sourceDir)
        let pull = SelfImproveCommands.pullUpstream(config)
        XCTAssertEqual(pull.last?.args, ["pull", "--no-rebase", "--no-edit", "origin", "claude/zealous-albattani-h2xkcz"])
    }

    func testOpencodeCommand() {
        let c = SelfImproveCommands.opencodeRun(config, prompt: "P", model: "opencode/muse-spark-1.3", variant: "xhigh")
        XCTAssertEqual(c.tool, "opencode")
        XCTAssertEqual(c.args, ["run", "--model", "opencode/muse-spark-1.3", "--variant", "xhigh", "P"])
        XCTAssertEqual(c.cwd, config.sourceDir)
        XCTAssertEqual(SelfImproveCommands.opencodeRun(config, prompt: "P", model: "", variant: "none").args, ["run", "P"])
    }

    func testXcodebuildMatchesReleaseWorkflow() {
        let c = SelfImproveCommands.xcodebuild(config, buildSHA: "abc1234")
        for flag in ["CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "ENABLE_HARDENED_RUNTIME=NO",
                     "ORBIT_ICLOUD_CONTAINER=", "ORBIT_BUILD_SHA=abc1234", "Release", "Orbit-macOS"] {
            XCTAssertTrue(c.args.contains(flag), flag)
        }
        XCTAssertTrue(c.args.contains { $0.hasPrefix("CODE_SIGN_ENTITLEMENTS=") && $0.hasSuffix("Orbit-Unsigned.entitlements") })
    }

    func testDisplayQuotes() {
        XCTAssertEqual(ShellCommand("git", ["commit", "-m", "hi there"]).display, "git commit -m 'hi there'")
    }

    func testPromptsIncludeRules() {
        let p = SelfImprovePrompt.request("  Make the header blue ")
        XCTAssertTrue(p.contains("swift test"))
        XCTAssertTrue(p.contains("Never add secrets"))
        XCTAssertTrue(p.hasSuffix("Make the header blue"))
        let f = SelfImprovePrompt.fix(originalRequest: "x", step: "xcodebuild", errors: ["a.swift:1: error: boom"], attempt: 1)
        XCTAssertTrue(f.contains("- a.swift:1: error: boom"))
    }

    func testCommitMessage() {
        XCTAssertTrue(SelfImproveCommands.commitMessage("Add a dark mode toggle\nmore").hasPrefix("Improve Orbit: Add a dark mode toggle\n"))
        let long = String(repeating: "a", count: 100)
        XCTAssertEqual(SelfImproveCommands.commitMessage(long).split(separator: "\n").first?.count, "Improve Orbit: ".count + 60)
    }

    func testBuildLogParser() {
        let log = """
        Compiling
        /x/A.swift:3:5: error: cannot find 'foo' in scope
        /x/A.swift:3:5: error: cannot find 'foo' in scope
        warning: meh
        ** BUILD FAILED **
        """
        XCTAssertEqual(BuildLogParser.errors(in: log), ["/x/A.swift:3:5: error: cannot find 'foo' in scope", "** BUILD FAILED **"])
        XCTAssertFalse(BuildLogParser.buildSucceeded(log))
        XCTAssertTrue(BuildLogParser.buildSucceeded("** BUILD SUCCEEDED **"))
    }

    func testNumstat() {
        let d = DiffSummary.parseNumstat("10\t2\tApp/A.swift\n-\t-\tIcon.png\n0\t5\tSources/{a => b}.swift\n\ngarbage\n")
        XCTAssertEqual(d.files.count, 3)
        XCTAssertEqual(d.totalAdded, 10)
        XCTAssertEqual(d.totalRemoved, 7)
        XCTAssertTrue(d.files[1].isBinary)
        XCTAssertEqual(d.headline, "3 files changed, +10 −7")
        XCTAssertEqual(DiffSummary.parseNumstat("").headline, "No changes")
        XCTAssertEqual(DiffSummary.parseNumstat("1\t0\tConfig/.env\n").suspiciousPaths, ["Config/.env"])
    }

    func testBackupNaming() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let name = AppBackupNaming.name(for: date)
        XCTAssertTrue(name.hasPrefix("Orbit-2026-"))
        XCTAssertEqual(AppBackupNaming.date(fromName: name), date)
        let older = AppBackupNaming.name(for: date.addingTimeInterval(-86400))
        XCTAssertEqual(AppBackupNaming.sorted([older, "junk.app", name]), [name, older])
        XCTAssertEqual(AppBackupNaming.latest([older, name]), name)
        XCTAssertEqual(AppBackupNaming.prune([older, name], keep: 1), [older])
    }

    func testHappyPath() {
        var m = SelfImproveMachine()
        m.handle(.start); XCTAssertEqual(m.phase, .preparingSource)
        m.handle(.sourceReady); XCTAssertEqual(m.phase, .runningAgent(attempt: 0))
        m.handle(.agentFinished); XCTAssertEqual(m.phase, .testing(attempt: 0))
        m.handle(.stepSucceeded); XCTAssertEqual(m.phase, .generatingProject(attempt: 0))
        m.handle(.stepSucceeded); XCTAssertEqual(m.phase, .building(attempt: 0))
        let diff = DiffSummary.parseNumstat("1\t0\ta.swift")
        m.handle(.diffReady(diff)); XCTAssertEqual(m.phase, .review(diff))
        m.handle(.accept); XCTAssertEqual(m.phase, .installing)
        m.handle(.cancel); XCTAssertEqual(m.phase, .installing, "can't cancel mid-install")
    }

    func testFixAttemptsThenFail() {
        var m = SelfImproveMachine(maxFixAttempts: 2)
        m.handle(.start); m.handle(.sourceReady); m.handle(.agentFinished)
        m.handle(.stepFailed(step: "swift test", errors: ["e1"]))
        XCTAssertEqual(m.phase, .runningAgent(attempt: 1))
        XCTAssertEqual(m.lastErrors, ["e1"])
        m.handle(.agentFinished); m.handle(.stepSucceeded); m.handle(.stepSucceeded)
        m.handle(.stepFailed(step: "xcodebuild", errors: ["e2"]))
        XCTAssertEqual(m.phase, .runningAgent(attempt: 2))
        m.handle(.agentFinished)
        m.handle(.stepFailed(step: "swift test", errors: ["e3"]))
        XCTAssertEqual(m.phase, .failed("swift test failed: e3"))
        m.handle(.discard); XCTAssertEqual(m.phase, .idle)
    }

    func testNoAutoFixAndEmptyDiffAndCancel() {
        var m = SelfImproveMachine(autoFix: false)
        m.handle(.start); m.handle(.sourceReady); m.handle(.agentFinished)
        m.handle(.stepFailed(step: "swift test", errors: []))
        XCTAssertEqual(m.phase, .failed("swift test failed."))

        var n = SelfImproveMachine()
        n.handle(.start); n.handle(.sourceReady); n.handle(.agentFinished); n.handle(.stepSucceeded); n.handle(.stepSucceeded)
        n.handle(.diffReady(DiffSummary(files: [])))
        XCTAssertEqual(n.phase, .failed("OpenCode didn't change anything."))

        var c = SelfImproveMachine()
        c.handle(.start); c.handle(.sourceReady); c.handle(.cancel)
        XCTAssertEqual(c.phase, .cancelled)
        c.handle(.start); XCTAssertEqual(c.phase, .preparingSource)
    }

    func testUpdateConflictPolicy() {
        XCTAssertEqual(UpdateConflictPolicy.action(localBuildInstalled: false, policy: .keepLocal), .installRelease)
        XCTAssertEqual(UpdateConflictPolicy.action(localBuildInstalled: true, policy: .ask), .warn)
        XCTAssertEqual(UpdateConflictPolicy.action(localBuildInstalled: true, policy: .keepLocal), .rebuildLocally)
        XCTAssertEqual(UpdateConflictPolicy.action(localBuildInstalled: true, policy: .useRelease), .installRelease)
        XCTAssertTrue(UpdateConflictPolicy.isLocalBuild(runningSHA: "abcdef1234", installedLocalMarker: "abcdef1"))
        XCTAssertFalse(UpdateConflictPolicy.isLocalBuild(runningSHA: "1234567abc", installedLocalMarker: "abcdef1"))
        XCTAssertFalse(UpdateConflictPolicy.isLocalBuild(runningSHA: "abcdef1", installedLocalMarker: nil))
    }
}
