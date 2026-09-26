import AppKit
import Foundation
import Observation
import OrbitCore

/// Runs "Improve Orbit": keeps a clone of Orbit's source, asks the local OpenCode CLI
/// to make a change, verifies it (swift test, xcodegen, xcodebuild), shows the diff,
/// then commits and installs the new build (backing up the current app first).
/// The pure logic (commands, state machine, parsing) lives in OrbitCore/SelfImprove.
@MainActor
@Observable
final class SelfImproveService {
    static let shared = SelfImproveService()

    enum Keys {
        static let sourceDir = "selfImprove.sourceDir"
        static let autoFix = "selfImprove.autoFix"
        static let localChangesPolicy = "selfImprove.localChangesPolicy"
        /// OrbitBuildSHA of the locally built app we installed (empty = none).
        static let installedLocalSHA = "selfImprove.installedLocalSHA"
    }

    struct CheckResult: Identifiable {
        let check: SetupCheck
        var ok: Bool?
        var detail: String = ""
        var id: String { check.id }
    }

    private(set) var machine = SelfImproveMachine()
    var phase: SelfImprovePhase { machine.phase }
    private(set) var log = ""
    private(set) var checks: [CheckResult] = SelfImproveCommands.setupChecks.map { CheckResult(check: $0) }
    private(set) var checking = false
    private(set) var sourceBusy = false
    private(set) var patch = ""
    private(set) var backups: [String] = []
    var request = ""

    @ObservationIgnored private var running: Process?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var currentRequest = ""

    // MARK: Settings

    static var appSupport: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support")
    }

    var sourceDir: String {
        get { UserDefaults.standard.string(forKey: Keys.sourceDir).flatMap { $0.isEmpty ? nil : $0 }
              ?? SelfImproveConfig.defaultSourceDir(appSupport: Self.appSupport) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sourceDir) }
    }

    var config: SelfImproveConfig { SelfImproveConfig(sourceDir: sourceDir) }
    var backupsDir: String { SelfImproveConfig.backupsDir(appSupport: Self.appSupport) }
    var hasSource: Bool { FileManager.default.fileExists(atPath: (sourceDir as NSString).appendingPathComponent(".git")) }
    var allChecksPass: Bool { checks.allSatisfy { $0.ok == true } }

    var policy: LocalChangesPolicy {
        get { LocalChangesPolicy(rawValue: UserDefaults.standard.string(forKey: Keys.localChangesPolicy) ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.localChangesPolicy) }
    }

    var isLocalBuildInstalled: Bool {
        let running = (Bundle.main.object(forInfoDictionaryKey: "OrbitBuildSHA") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return UpdateConflictPolicy.isLocalBuild(runningSHA: running.hasPrefix("$(") ? "" : running,
                                                 installedLocalMarker: UserDefaults.standard.string(forKey: Keys.installedLocalSHA))
    }

    /// Model and variant from the OpenCode settings (Muse Spark 1.3, xhigh by default).
    var model: String? {
        let m = MacPrefs.string(MacPrefs.openCodeModel).flatMap { $0.isEmpty ? nil : $0 } ?? MacPrefs.string(MacPrefs.openCodeResolvedModel)
        return m.flatMap { $0.isEmpty ? nil : $0 }
    }

    var variant: String {
        let v = MacPrefs.string(MacPrefs.openCodeVariant) ?? ""
        return v.isEmpty ? OpenCodeModelResolver.preferredVariant : v
    }

    // MARK: Setup

    func runChecks() async {
        checking = true
        defer { checking = false }
        for i in checks.indices {
            let r = await Self.capture(checks[i].check.command)
            checks[i].ok = r.status == 0
            let text = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            checks[i].detail = r.status == 0 ? String(text.split(separator: "\n").first ?? "") : checks[i].check.fix
        }
    }

    func brewInstall(_ check: SetupCheck) async {
        guard let pkg = check.brewPackage else { return }
        _ = await stream(SelfImproveCommands.brewInstall(pkg))
        await runChecks()
    }

    func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use folder"
        if panel.runModal() == .OK, let url = panel.url {
            sourceDir = url.path.hasSuffix("/Source") ? url.path : url.appendingPathComponent("Source").path
        }
    }

    /// Clones the repo if needed; otherwise just makes sure we're on the local branch.
    @discardableResult
    func prepareSource(pull: Bool) async -> Bool {
        sourceBusy = true
        defer { sourceBusy = false }
        let c = config
        if !hasSource {
            try? FileManager.default.createDirectory(atPath: (c.sourceDir as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            for cmd in SelfImproveCommands.clone(c) { guard await stream(cmd) == 0 else { return false } }
            return true
        }
        if pull {
            for cmd in SelfImproveCommands.pullUpstream(c) {
                guard await stream(cmd) == 0 else {
                    appendLog("\nMerging upstream failed (conflict?). Resolve it in \(c.sourceDir) or discard local changes.\n")
                    return false
                }
            }
        }
        return true
    }

    func updateSource() {
        task = Task { await prepareSource(pull: true) }
    }

    // MARK: Run

    func start() {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !phase.isBusy else { return }
        currentRequest = text
        log = ""
        patch = ""
        machine = SelfImproveMachine(maxFixAttempts: 2, autoFix: UserDefaults.standard.object(forKey: Keys.autoFix) as? Bool ?? true)
        machine.handle(.start)
        task = Task { await runPipeline() }
    }

    func cancel() {
        running?.terminate()
        task?.cancel()
        machine.handle(.cancel)
        appendLog("\nCancelled.\n")
    }

    private func runPipeline() async {
        guard await prepareSource(pull: false) else { machine.handle(.agentFailed("Couldn't prepare the source.")); return }
        // Start from a clean tree so the diff only shows this request's changes.
        for cmd in SelfImproveCommands.discard(config) { _ = await stream(cmd) }
        guard !Task.isCancelled else { return }
        machine.handle(.sourceReady)

        while !Task.isCancelled {
            switch machine.phase {
            case .runningAgent(let attempt):
                let prompt = attempt == 0
                    ? SelfImprovePrompt.request(currentRequest)
                    : SelfImprovePrompt.fix(originalRequest: currentRequest, step: machine.lastFailedStep ?? "build",
                                            errors: machine.lastErrors, attempt: attempt)
                let status = await stream(SelfImproveCommands.opencodeRun(config, prompt: prompt, model: model, variant: variant))
                guard !Task.isCancelled else { return }
                machine.handle(status == 0 ? .agentFinished : .agentFailed("exit code \(status)"))
            case .testing:
                await verify(SelfImproveCommands.swiftTest(config), step: "swift test")
            case .generatingProject:
                await verify(SelfImproveCommands.xcodegen(config), step: "xcodegen")
            case .building:
                let base = await Self.capture(SelfImproveCommands.upstreamSHA(config)).output.trimmingCharacters(in: .whitespacesAndNewlines)
                let (status, out) = await streamCapturing(SelfImproveCommands.xcodebuild(config, buildSHA: base))
                guard !Task.isCancelled else { return }
                if status == 0 && BuildLogParser.buildSucceeded(out) {
                    _ = await stream(SelfImproveCommands.codesign(appPath: config.builtAppPath))
                    _ = await Self.capture(SelfImproveCommands.stageAll(config))
                    let numstat = await Self.capture(SelfImproveCommands.diffNumstat(config)).output
                    patch = await Self.capture(SelfImproveCommands.diffPatch(config)).output
                    machine.handle(.diffReady(DiffSummary.parseNumstat(numstat)))
                } else {
                    machine.handle(.stepFailed(step: "xcodebuild", errors: BuildLogParser.errors(in: out)))
                }
            default:
                return
            }
        }
    }

    private func verify(_ cmd: ShellCommand, step: String) async {
        let (status, out) = await streamCapturing(cmd)
        guard !Task.isCancelled else { return }
        machine.handle(status == 0 ? .stepSucceeded : .stepFailed(step: step, errors: BuildLogParser.errors(in: out)))
    }

    // MARK: Review

    func discard() {
        task = Task {
            for cmd in SelfImproveCommands.discard(config) { _ = await stream(cmd) }
            machine.handle(.discard)
        }
    }

    func accept() {
        guard case .review = phase else { return }
        machine.handle(.accept)
        task = Task {
            for cmd in SelfImproveCommands.commit(config, request: currentRequest) {
                guard await stream(cmd) == 0 else { machine.handle(.installFailed("git commit failed")); return }
            }
            await installBuiltApp()
        }
    }

    /// Backs up the current app, then hands over to the swap-and-relaunch helper.
    private func installBuiltApp() async {
        let fm = FileManager.default
        let built = config.builtAppPath
        guard fm.fileExists(atPath: built) else { machine.handle(.installFailed("The built app is missing.")); return }
        let dest = Self.destinationPath
        do {
            try fm.createDirectory(atPath: backupsDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest) {
                let backup = (backupsDir as NSString).appendingPathComponent(AppBackupNaming.name(for: Date()))
                appendLog("Backing up \(dest) to \(backup)\n")
                guard await stream(ShellCommand("/usr/bin/ditto", [dest, backup])) == 0 else {
                    throw UpdateService.UpdateError("Couldn't back up the current app.")
                }
                for old in AppBackupNaming.prune(listBackups(), keep: 5) {
                    try? fm.removeItem(atPath: (backupsDir as NSString).appendingPathComponent(old))
                }
            }
            // Copy the build out of the checkout so later builds can't disturb the install.
            let staged = fm.temporaryDirectory.appendingPathComponent("orbit-local-\(UUID().uuidString)/Orbit.app").path
            try fm.createDirectory(atPath: (staged as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard await stream(ShellCommand("/usr/bin/ditto", [built, staged])) == 0 else {
                throw UpdateService.UpdateError("Couldn't stage the new build.")
            }
            let sha = Bundle(path: staged)?.object(forInfoDictionaryKey: "OrbitBuildSHA") as? String ?? ""
            UserDefaults.standard.set(sha.isEmpty ? "local" : sha, forKey: Keys.installedLocalSHA)
            try launchHelper(newApp: staged, destination: dest)
        } catch {
            machine.handle(.installFailed(error.localizedDescription))
        }
    }

    // MARK: Roll back

    func listBackups() -> [String] {
        AppBackupNaming.sorted((try? FileManager.default.contentsOfDirectory(atPath: backupsDir)) ?? [])
    }

    func refreshBackups() { backups = listBackups() }

    func rollBack(to name: String? = nil) {
        guard let pick = name ?? listBackups().first else { return }
        let path = (backupsDir as NSString).appendingPathComponent(pick)
        do {
            // The previous app may itself be a local build; clear the marker only if it isn't ours.
            UserDefaults.standard.removeObject(forKey: Keys.installedLocalSHA)
            try launchHelper(newApp: path, destination: Self.destinationPath)
        } catch {
            appendLog("Roll back failed: \(error.localizedDescription)\n")
        }
    }

    private func launchHelper(newApp: String, destination: String) throws {
        let parent = (destination as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw UpdateService.UpdateError("Orbit can't write to \(parent).")
        }
        let script = SelfImproveInstaller.script(pid: ProcessInfo.processInfo.processIdentifier, newApp: newApp,
                                                 destination: destination, logFile: OrbitLog.fileURL.path)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-self-install-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [url.path]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        OrbitLog.log("selfimprove", "installing \(newApp) → \(destination); quitting")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    static var destinationPath: String {
        let running = Bundle.main.bundlePath
        if running.contains("/AppTranslocation/") || running.hasPrefix("/Volumes/") { return "/Applications/Orbit.app" }
        return running
    }

    // MARK: Auto-update interplay

    /// Called by UpdateService before installing a GitHub release. Returns true if the
    /// release install should be skipped (the user kept local changes or cancelled).
    func interceptReleaseInstall() -> Bool {
        var action = UpdateConflictPolicy.action(localBuildInstalled: isLocalBuildInstalled, policy: policy)
        if action == .warn {
            let alert = NSAlert()
            alert.messageText = "This update would replace your local improvements"
            alert.informativeText = "The installed Orbit was built by Improve Orbit. Keep your changes by merging the update into your local source and rebuilding, or install the GitHub version (your changes stay in the source folder)."
            alert.addButton(withTitle: "Keep my local changes")
            alert.addButton(withTitle: "Install GitHub version")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Remember my choice"
            let r = alert.runModal()
            let remember = alert.suppressionButton?.state == .on
            switch r {
            case .alertFirstButtonReturn:
                action = .rebuildLocally
                if remember { policy = .keepLocal }
            case .alertSecondButtonReturn:
                action = .installRelease
                if remember { policy = .useRelease }
            default:
                return true
            }
        }
        switch action {
        case .installRelease:
            UserDefaults.standard.removeObject(forKey: Keys.installedLocalSHA)
            return false
        case .rebuildLocally:
            rebuildFromUpstream()
            return true
        case .warn:
            return true
        }
    }

    /// Merges upstream into local/improvements, verifies, builds and installs (no agent run).
    func rebuildFromUpstream() {
        guard !phase.isBusy else { return }
        log = ""
        currentRequest = "Merge upstream updates"
        machine = SelfImproveMachine(maxFixAttempts: 0, autoFix: false)
        machine.handle(.start)
        task = Task {
            guard await prepareSource(pull: true) else { machine.handle(.agentFailed("Merging upstream failed.")); return }
            machine.handle(.sourceReady)
            machine.handle(.agentFinished) // skip the agent; go straight to verification
            while !Task.isCancelled {
                switch machine.phase {
                case .testing: await verify(SelfImproveCommands.swiftTest(config), step: "swift test")
                case .generatingProject: await verify(SelfImproveCommands.xcodegen(config), step: "xcodegen")
                case .building:
                    let base = await Self.capture(SelfImproveCommands.upstreamSHA(config)).output.trimmingCharacters(in: .whitespacesAndNewlines)
                    let (status, out) = await streamCapturing(SelfImproveCommands.xcodebuild(config, buildSHA: base))
                    guard status == 0, BuildLogParser.buildSucceeded(out) else {
                        machine.handle(.stepFailed(step: "xcodebuild", errors: BuildLogParser.errors(in: out))); return
                    }
                    _ = await stream(SelfImproveCommands.codesign(appPath: config.builtAppPath))
                    // xcodegen may touch the project file; commit so the tree stays clean.
                    for cmd in SelfImproveCommands.commit(config, request: currentRequest) { _ = await stream(cmd) }
                    machine.handle(.diffReady(DiffSummary(files: [DiffFileStat(path: "upstream", added: 0, removed: 0)])))
                    machine.handle(.accept)
                    await installBuiltApp()
                    return
                default: return
                }
            }
        }
    }

    // MARK: Process plumbing

    private func appendLog(_ s: String) {
        log += s
        if log.count > 400_000 { log = String(log.suffix(300_000)) }
    }

    /// PATH for GUI apps misses Homebrew and the OpenCode installer's bin dirs.
    nonisolated static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.opencode/bin", "\(home)/.local/bin", "\(home)/.bun/bin"]
        env["PATH"] = (extra + [(env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")]).joined(separator: ":")
        env["NO_COLOR"] = "1"
        return env
    }

    nonisolated static func makeProcess(_ cmd: ShellCommand) -> Process {
        let p = Process()
        if cmd.tool.hasPrefix("/") {
            p.executableURL = URL(fileURLWithPath: cmd.tool)
            p.arguments = cmd.args
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [cmd.tool] + cmd.args
        }
        if let cwd = cmd.cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        return p
    }

    /// Runs quietly and returns (exit status, combined output).
    nonisolated static func capture(_ cmd: ShellCommand) async -> (status: Int32, output: String) {
        await Task.detached {
            let p = makeProcess(cmd)
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return (127, error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }

    @discardableResult
    private func stream(_ cmd: ShellCommand) async -> Int32 { await streamCapturing(cmd).0 }

    /// Runs a command, streaming its output into `log`; returns status and the full output.
    private func streamCapturing(_ cmd: ShellCommand) async -> (Int32, String) {
        appendLog("\n$ \(cmd.display.count > 300 ? String(cmd.display.prefix(300)) + "…" : cmd.display)\n")
        let p = Self.makeProcess(cmd)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let collected = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            let s = String(decoding: data, as: UTF8.self)
            collected.append(s)
            Task { @MainActor in self?.appendLog(s) }
        }
        let started: Bool = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            p.terminationHandler = { _ in c.resume(returning: true) }
            do {
                try p.run()
                running = p
            } catch {
                p.terminationHandler = nil
                appendLog("Couldn't start \(cmd.tool): \(error.localizedDescription)\n")
                c.resume(returning: false)
            }
        }
        guard started else { pipe.fileHandleForReading.readabilityHandler = nil; return (127, "") }
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            let s = String(decoding: rest, as: UTF8.self)
            collected.append(s)
            appendLog(s)
        }
        running = nil
        return (p.terminationStatus, collected.value)
    }
}

/// Thread-safe string accumulator for pipe output.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}
