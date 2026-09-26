import Foundation

// "Improve Orbit": the local OpenCode agent edits Orbit's own source and rebuilds it.
// This file holds the pure, testable parts: command lines, prompts, the run state
// machine, diff/error parsing, backup naming and the auto-update conflict policy.
// The Mac app (App/macOS/SelfImprove) runs the commands and shows the UI.

/// Where the source lives and which branches are used.
public struct SelfImproveConfig: Hashable, Sendable {
    public static let defaultRepoURL = "https://github.com/Charliewytk/Orbit.git"
    public static let localBranch = "local/improvements"

    public var sourceDir: String
    public var repoURL: String
    public var upstreamBranch: String
    public var localBranch: String

    public init(sourceDir: String, repoURL: String = SelfImproveConfig.defaultRepoURL,
                upstreamBranch: String = "claude/zealous-albattani-h2xkcz", localBranch: String = SelfImproveConfig.localBranch) {
        self.sourceDir = sourceDir
        self.repoURL = repoURL
        self.upstreamBranch = upstreamBranch
        self.localBranch = localBranch
    }

    /// ~/Library/Application Support/Orbit/Source
    public static func defaultSourceDir(appSupport: String) -> String {
        (appSupport as NSString).appendingPathComponent("Orbit/Source")
    }

    public static func backupsDir(appSupport: String) -> String {
        (appSupport as NSString).appendingPathComponent("Orbit/Backups")
    }

    /// Where xcodebuild puts intermediates (inside the checkout, git-ignored `build/`).
    public var derivedDataPath: String { (sourceDir as NSString).appendingPathComponent("build") }

    /// The built app after a successful Release build.
    public var builtAppPath: String { (derivedDataPath as NSString).appendingPathComponent("Build/Products/Release/Orbit.app") }
}

/// One command to run: executable + arguments + working directory. `tool` is looked up on PATH.
public struct ShellCommand: Hashable, Sendable {
    public var tool: String
    public var args: [String]
    public var cwd: String?

    public init(_ tool: String, _ args: [String], cwd: String? = nil) {
        self.tool = tool
        self.args = args
        self.cwd = cwd
    }

    /// Human-readable form for the log view.
    public var display: String {
        ([tool] + args).map { a in
            a.isEmpty || a.contains(where: { " \"'$\\\n".contains($0) }) ? UpdateInstallerScript.quote(a) : a
        }.joined(separator: " ")
    }
}

/// Builds every command the flow runs.
public enum SelfImproveCommands {
    // MARK: Setup checks
    public static let setupChecks: [SetupCheck] = [
        SetupCheck(id: "xcode", title: "Xcode", command: ShellCommand("xcode-select", ["-p"]),
                   fix: "Install Xcode from the App Store, open it once, then run: sudo xcode-select -s /Applications/Xcode.app"),
        SetupCheck(id: "xcodebuild", title: "xcodebuild", command: ShellCommand("xcodebuild", ["-version"]),
                   fix: "Run: sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept"),
        SetupCheck(id: "git", title: "git", command: ShellCommand("git", ["--version"]),
                   fix: "Run: xcode-select --install", brewPackage: nil),
        SetupCheck(id: "xcodegen", title: "XcodeGen", command: ShellCommand("xcodegen", ["--version"]),
                   fix: "Run: brew install xcodegen", brewPackage: "xcodegen"),
        SetupCheck(id: "opencode", title: "OpenCode CLI", command: ShellCommand("opencode", ["--version"]),
                   fix: "Run: brew install sst/tap/opencode (or curl -fsSL https://opencode.ai/install | bash), then `opencode auth login`.",
                   brewPackage: "sst/tap/opencode"),
    ]

    public static func brewInstall(_ package: String) -> ShellCommand { ShellCommand("brew", ["install", package]) }

    // MARK: Source
    public static func clone(_ c: SelfImproveConfig) -> [ShellCommand] {
        let parent = (c.sourceDir as NSString).deletingLastPathComponent
        return [
            ShellCommand("git", ["clone", "--branch", c.upstreamBranch, c.repoURL, c.sourceDir], cwd: parent),
            ShellCommand("git", ["checkout", "-B", c.localBranch], cwd: c.sourceDir),
        ]
    }

    /// Fetches upstream and merges it into the local branch (keeps local commits).
    public static func pullUpstream(_ c: SelfImproveConfig) -> [ShellCommand] {
        [
            ShellCommand("git", ["checkout", c.localBranch], cwd: c.sourceDir),
            ShellCommand("git", ["pull", "--no-rebase", "--no-edit", "origin", c.upstreamBranch], cwd: c.sourceDir),
        ]
    }

    public static func upstreamSHA(_ c: SelfImproveConfig) -> ShellCommand {
        ShellCommand("git", ["rev-parse", "origin/\(c.upstreamBranch)"], cwd: c.sourceDir)
    }

    public static func headSHA(_ c: SelfImproveConfig) -> ShellCommand {
        ShellCommand("git", ["rev-parse", "HEAD"], cwd: c.sourceDir)
    }

    // MARK: Agent
    public static func opencodeRun(_ c: SelfImproveConfig, prompt: String, model: String?, variant: String?) -> ShellCommand {
        var args = ["run"]
        if let model, !model.trimmingCharacters(in: .whitespaces).isEmpty { args += ["--model", model] }
        if let variant, !variant.isEmpty, variant != "none" { args += ["--variant", variant] }
        args.append(prompt)
        return ShellCommand("opencode", args, cwd: c.sourceDir)
    }

    // MARK: Verify
    public static func swiftTest(_ c: SelfImproveConfig) -> ShellCommand { ShellCommand("swift", ["test"], cwd: c.sourceDir) }
    public static func xcodegen(_ c: SelfImproveConfig) -> ShellCommand { ShellCommand("xcodegen", ["generate"], cwd: c.sourceDir) }

    /// Same flags as .github/workflows/release-mac.yml (ad-hoc signed Release build).
    /// `buildSHA` is embedded as OrbitBuildSHA so the updater can still compare with upstream.
    public static func xcodebuild(_ c: SelfImproveConfig, buildSHA: String?) -> ShellCommand {
        let entitlements = (c.sourceDir as NSString).appendingPathComponent("App/Supporting/macOS/Orbit-Unsigned.entitlements")
        return ShellCommand("xcodebuild", [
            "build",
            "-project", "Orbit.xcodeproj",
            "-scheme", "Orbit-macOS",
            "-configuration", "Release",
            "-destination", "generic/platform=macOS",
            "-derivedDataPath", c.derivedDataPath,
            "CODE_SIGN_IDENTITY=-",
            "CODE_SIGN_STYLE=Manual",
            "DEVELOPMENT_TEAM=",
            "PROVISIONING_PROFILE_SPECIFIER=",
            "CODE_SIGN_ENTITLEMENTS=\(entitlements)",
            "ENABLE_HARDENED_RUNTIME=NO",
            "ORBIT_ICLOUD_CONTAINER=",
            "ORBIT_BUILD_SHA=\(buildSHA ?? "")",
        ], cwd: c.sourceDir)
    }

    public static func codesign(appPath: String) -> ShellCommand {
        ShellCommand("codesign", ["--force", "--deep", "--sign", "-", appPath])
    }

    // MARK: Review
    public static func stageAll(_ c: SelfImproveConfig) -> ShellCommand { ShellCommand("git", ["add", "-A"], cwd: c.sourceDir) }
    /// Run after `stageAll` so new files are counted.
    public static func diffNumstat(_ c: SelfImproveConfig) -> ShellCommand {
        ShellCommand("git", ["diff", "--cached", "--numstat"], cwd: c.sourceDir)
    }
    public static func diffPatch(_ c: SelfImproveConfig) -> ShellCommand {
        ShellCommand("git", ["diff", "--cached"], cwd: c.sourceDir)
    }

    public static func discard(_ c: SelfImproveConfig) -> [ShellCommand] {
        [
            ShellCommand("git", ["reset", "--hard", "HEAD"], cwd: c.sourceDir),
            ShellCommand("git", ["clean", "-fd", "-e", "build/"], cwd: c.sourceDir),
        ]
    }

    public static func commit(_ c: SelfImproveConfig, request: String) -> [ShellCommand] {
        [
            ShellCommand("git", ["add", "-A"], cwd: c.sourceDir),
            ShellCommand("git", ["-c", "user.name=Orbit", "-c", "user.email=orbit@localhost",
                                 "commit", "-m", commitMessage(request)], cwd: c.sourceDir),
        ]
    }

    public static func commitMessage(_ request: String) -> String {
        let oneLine = request.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? "change"
        let title = oneLine.count > 60 ? String(oneLine.prefix(59)) + "…" : oneLine
        return "Improve Orbit: \(title.isEmpty ? "change" : title)\n\nRequested in Orbit:\n\(request)"
    }
}

/// A prerequisite shown in the setup checklist.
public struct SetupCheck: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var command: ShellCommand
    public var fix: String
    public var brewPackage: String?

    public init(id: String, title: String, command: ShellCommand, fix: String, brewPackage: String? = nil) {
        self.id = id
        self.title = title
        self.command = command
        self.fix = fix
        self.brewPackage = brewPackage
    }
}

/// Prompts sent to `opencode run`.
public enum SelfImprovePrompt {
    public static let preamble = """
    You are editing the source code of Orbit, a SwiftUI app for macOS/iOS, in the current directory.
    Rules:
    - Make the smallest change that fully does what the user asks. Do not refactor unrelated code.
    - Keep the existing code style, naming and file layout. Put pure logic in Sources/OrbitCore with tests in Tests/OrbitCoreTests.
    - If you add Swift files under App/, they are picked up by project.yml automatically (xcodegen is run afterwards).
    - Run `swift test` and make sure it passes before you finish.
    - Never add secrets, API keys, tokens, passwords or personal data. This repository is public.
    - Do not commit, push, or change git configuration; the app reviews and commits your changes.
    """

    public static func request(_ userRequest: String) -> String {
        "\(preamble)\n\nUser request:\n\(userRequest.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Follow-up after a failed verification step.
    public static func fix(originalRequest: String, step: String, errors: [String], attempt: Int) -> String {
        let list = errors.prefix(40).map { "- \($0)" }.joined(separator: "\n")
        return """
        \(preamble)

        You were asked: \(originalRequest.trimmingCharacters(in: .whitespacesAndNewlines))
        The change was made, but `\(step)` failed (fix attempt \(attempt)). Fix these errors with minimal edits:
        \(list.isEmpty ? "(no error lines captured; check the build)" : list)
        """
    }
}

/// Pulls the useful error lines out of swift test / xcodebuild output.
public enum BuildLogParser {
    public static func errors(in log: String, limit: Int = 60) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for raw in log.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let isError = line.contains("error:") || line.hasPrefix("✘") || line.contains(": error ")
                || (line.contains("XCTAssert") && line.contains("failed"))
                || line.hasPrefix("** BUILD FAILED") || line.hasPrefix("** TEST FAILED")
            guard isError, seen.insert(line).inserted else { continue }
            out.append(line)
            if out.count >= limit { break }
        }
        return out
    }

    public static func buildSucceeded(_ log: String) -> Bool { log.contains("BUILD SUCCEEDED") }
}

/// One file in `git diff --numstat`.
public struct DiffFileStat: Hashable, Sendable {
    public var path: String
    /// nil for binary files.
    public var added: Int?
    public var removed: Int?
    public var isBinary: Bool { added == nil }
    public init(path: String, added: Int?, removed: Int?) { self.path = path; self.added = added; self.removed = removed }
}

public struct DiffSummary: Hashable, Sendable {
    public var files: [DiffFileStat]
    public init(files: [DiffFileStat]) { self.files = files }
    public var totalAdded: Int { files.compactMap(\.added).reduce(0, +) }
    public var totalRemoved: Int { files.compactMap(\.removed).reduce(0, +) }
    public var isEmpty: Bool { files.isEmpty }

    public var headline: String {
        isEmpty ? "No changes" : "\(files.count) file\(files.count == 1 ? "" : "s") changed, +\(totalAdded) −\(totalRemoved)"
    }

    /// Parses `git diff --numstat` ("12\t3\tpath", "-\t-\tbinary", renames "a => b").
    public static func parseNumstat(_ text: String) -> DiffSummary {
        var files: [DiffFileStat] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let path = String(parts[2])
            guard !path.isEmpty else { continue }
            files.append(DiffFileStat(path: path, added: Int(parts[0]), removed: Int(parts[1])))
        }
        return DiffSummary(files: files)
    }

    /// True if any changed path looks like it could hold a secret (blocked from Accept until reviewed).
    public var suspiciousPaths: [String] {
        let bad = [".env", "secrets", "credentials", ".pem", ".p12", "id_rsa", "token"]
        return files.map(\.path).filter { p in bad.contains { p.lowercased().contains($0) } }
    }
}

/// Timestamped app backups: Orbit-2026-09-26-143005.app
public enum AppBackupNaming {
    static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }

    public static func name(for date: Date) -> String { "Orbit-\(formatter().string(from: date)).app" }

    public static func date(fromName name: String) -> Date? {
        guard name.hasPrefix("Orbit-"), name.hasSuffix(".app") else { return nil }
        let stamp = name.dropFirst("Orbit-".count).dropLast(".app".count)
        return formatter().date(from: String(stamp))
    }

    /// Backups newest first (ignores anything that isn't one of ours).
    public static func sorted(_ names: [String]) -> [String] {
        names.compactMap { n in date(fromName: n).map { (n, $0) } }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    public static func latest(_ names: [String]) -> String? { sorted(names).first }

    /// Names to delete to keep only the newest `keep`.
    public static func prune(_ names: [String], keep: Int = 5) -> [String] { Array(sorted(names).dropFirst(max(0, keep))) }
}

/// Script that waits for Orbit to quit, swaps in `newApp`, and relaunches (shared with the updater).
public enum SelfImproveInstaller {
    public static func script(pid: Int32, newApp: String, destination: String, logFile: String) -> String {
        UpdateInstallerScript.make(pid: pid, newApp: newApp, destination: destination, logFile: logFile)
    }
}

// MARK: - State machine

public enum SelfImprovePhase: Hashable, Sendable {
    case idle
    case preparingSource
    case runningAgent(attempt: Int)
    case testing(attempt: Int)
    case generatingProject(attempt: Int)
    case building(attempt: Int)
    case review(DiffSummary)
    case installing
    case failed(String)
    case cancelled

    public var isBusy: Bool {
        switch self {
        case .idle, .review, .failed, .cancelled: return false
        default: return true
        }
    }

    public var label: String {
        switch self {
        case .idle: return "Ready"
        case .preparingSource: return "Updating the source…"
        case .runningAgent(let a): return a == 0 ? "OpenCode is making the change…" : "OpenCode is fixing errors (attempt \(a))…"
        case .testing: return "Running tests…"
        case .generatingProject: return "Generating the Xcode project…"
        case .building: return "Building Orbit…"
        case .review(let d): return "Ready to review: \(d.headline)"
        case .installing: return "Installing; Orbit will restart…"
        case .failed(let e): return e
        case .cancelled: return "Cancelled"
        }
    }
}

public enum SelfImproveEvent: Hashable, Sendable {
    case start
    case sourceReady
    case agentFinished
    case agentFailed(String)
    case stepSucceeded
    case stepFailed(step: String, errors: [String])
    case diffReady(DiffSummary)
    case accept
    case discard
    case cancel
    case installFailed(String)
}

/// Pure transitions: agent → test → xcodegen → build → review; a failed step
/// goes back to the agent for up to `maxFixAttempts` fixes when `autoFix` is on.
public struct SelfImproveMachine: Hashable, Sendable {
    public var phase: SelfImprovePhase = .idle
    public var maxFixAttempts: Int
    public var autoFix: Bool
    /// Errors from the last failed step (fed to the fix prompt).
    public private(set) var lastErrors: [String] = []
    public private(set) var lastFailedStep: String?

    public init(maxFixAttempts: Int = 2, autoFix: Bool = true) {
        self.maxFixAttempts = maxFixAttempts
        self.autoFix = autoFix
    }

    var attempt: Int {
        switch phase {
        case .runningAgent(let a), .testing(let a), .generatingProject(let a), .building(let a): return a
        default: return 0
        }
    }

    @discardableResult
    public mutating func handle(_ event: SelfImproveEvent) -> SelfImprovePhase {
        switch (phase, event) {
        case (_, .cancel) where phase.isBusy && phase != .installing:
            phase = .cancelled
        case (.idle, .start), (.failed, .start), (.cancelled, .start):
            lastErrors = []; lastFailedStep = nil
            phase = .preparingSource
        case (.preparingSource, .sourceReady):
            phase = .runningAgent(attempt: 0)
        case (.runningAgent(let a), .agentFinished):
            phase = .testing(attempt: a)
        case (.runningAgent, .agentFailed(let e)):
            phase = .failed("OpenCode failed: \(e)")
        case (.testing(let a), .stepSucceeded):
            phase = .generatingProject(attempt: a)
        case (.generatingProject(let a), .stepSucceeded):
            phase = .building(attempt: a)
        case (.building, .diffReady(let d)):
            phase = d.isEmpty ? .failed("OpenCode didn't change anything.") : .review(d)
        case (.testing(let a), .stepFailed(let step, let errs)),
             (.generatingProject(let a), .stepFailed(let step, let errs)),
             (.building(let a), .stepFailed(let step, let errs)):
            lastErrors = errs; lastFailedStep = step
            if autoFix && a < maxFixAttempts {
                phase = .runningAgent(attempt: a + 1)
            } else {
                phase = .failed("\(step) failed" + (errs.first.map { ": \($0)" } ?? "."))
            }
        case (.review, .accept):
            phase = .installing
        case (.review, .discard), (.failed, .discard), (.cancelled, .discard):
            phase = .idle
        case (.installing, .installFailed(let e)):
            phase = .failed("Install failed: \(e)")
        case (.preparingSource, .agentFailed(let e)):
            phase = .failed(e)
        default:
            break
        }
        return phase
    }
}

// MARK: - Auto-update interplay

public enum LocalChangesPolicy: String, CaseIterable, Sendable {
    /// Ask before the GitHub update overwrites a locally improved build.
    case ask
    /// Merge upstream into local/improvements and rebuild instead of installing the release.
    case keepLocal
    /// Install the GitHub release (local changes stay in the source checkout).
    case useRelease
}

public enum UpdateConflictAction: Hashable, Sendable {
    /// No local build is installed: install the release as usual.
    case installRelease
    /// Show a warning; the user picks keep-local or use-release.
    case warn
    /// Pull upstream into the local branch and rebuild.
    case rebuildLocally
}

public enum UpdateConflictPolicy {
    /// - localBuildInstalled: the running app was installed by Improve Orbit.
    public static func action(localBuildInstalled: Bool, policy: LocalChangesPolicy) -> UpdateConflictAction {
        guard localBuildInstalled else { return .installRelease }
        switch policy {
        case .ask: return .warn
        case .keepLocal: return .rebuildLocally
        case .useRelease: return .installRelease
        }
    }

    /// Whether the running build is the local one: its embedded commit matches what Improve Orbit installed.
    public static func isLocalBuild(runningSHA: String, installedLocalMarker: String?) -> Bool {
        guard let marker = installedLocalMarker, !marker.isEmpty else { return false }
        return runningSHA.isEmpty || UpdateDecision.sameCommit(runningSHA, marker)
    }
}
