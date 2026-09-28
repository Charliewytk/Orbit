import Foundation
import Observation
import OrbitCore

/// Keeps `opencode serve` running on the Mac. If nothing answers on the port,
/// finds the `opencode` binary and starts it as a child process, restarts it
/// if it dies, and stops it when Orbit quits.
@MainActor
@Observable
final class OpenCodeLauncher {
    enum Status: Equatable {
        case unknown
        case starting
        /// `external` = someone else started it (e.g. you in a terminal).
        case running(external: Bool)
        case notInstalled
        case failed(String)

        var label: String {
            switch self {
            case .unknown: "Checking…"
            case .starting: "Starting…"
            case .running(let external): external ? "Running (started outside Orbit)" : "Running"
            case .notInstalled: "Not found"
            case .failed(let why): "Stopped: \(why)"
            }
        }

        var isRunning: Bool { if case .running = self { true } else { false } }
    }

    private(set) var status: Status = .unknown
    private(set) var binaryPath: String?
    let port = 4096
    /// 0.0.0.0 when sharing with the iPhone, otherwise loopback only.
    private(set) var hostname = "127.0.0.1"
    /// Basic-auth password (only when shared with the iPhone).
    private(set) var password: String?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var restarts: [Date] = []
    @ObservationIgnored private let workspace: URL
    @ObservationIgnored private let logURL: URL

    init(workspace: URL, logsDirectory: URL) {
        self.workspace = workspace
        self.logURL = logsDirectory.appendingPathComponent("opencode.log")
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// The provider Orbit uses on this Mac.
    func provider(model: OpenCodeProvider.ModelRef?, variant: String? = nil) -> OpenCodeProvider {
        OpenCodeProvider(baseURL: baseURL, model: model, password: password, variant: variant)
    }

    /// Share with the iPhone (listen on all interfaces with a password) or not.
    func configureSharing(enabled: Bool, password: String?) {
        let newHost = enabled ? "0.0.0.0" : "127.0.0.1"
        let newPassword = enabled ? password : nil
        guard newHost != hostname || newPassword != self.password else { return }
        hostname = newHost
        self.password = newPassword
        // Restart our own server so the new settings apply.
        if let p = process, p.isRunning {
            stopping = true
            p.terminate()
            process = nil
            stopping = false
            status = .unknown
        }
    }

    func isAnswering() async -> Bool {
        await provider(model: nil).isAvailable()
    }

    /// Makes sure something answers on the port, starting OpenCode if needed.
    func ensureRunning() async {
        if await isAnswering() {
            status = .running(external: process == nil)
            return
        }
        if let p = process, p.isRunning {
            // Probably still booting; give it a moment.
            status = .starting
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(1))
                if await isAnswering() { status = .running(external: false); return }
            }
            return
        }
        guard let path = await Self.locate() else {
            binaryPath = nil
            status = .notInstalled
            return
        }
        binaryPath = path
        start(path)
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(1))
            if await isAnswering() { status = .running(external: false); return }
        }
        if process?.isRunning != true { status = .failed("exited on start; see the log") }
    }

    private func start(_ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["serve", "--port", "\(port)", "--hostname", hostname]
        p.currentDirectoryURL = workspace
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = ["\(home)/.opencode/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        if let password { env["OPENCODE_SERVER_PASSWORD"] = password }
        p.environment = env

        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            p.standardOutput = handle
            p.standardError = handle
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.processDidExit() }
        }
        do {
            try p.run()
            process = p
            status = .starting
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func processDidExit() {
        process = nil
        guard !stopping else { return }
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 600 } + [now]
        if restarts.count > 5 {
            status = .failed("kept crashing; see the log")
            return
        }
        status = .starting
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            await self.ensureRunning()
        }
    }

    func restart() async {
        stop()
        stopping = false
        restarts = []
        await ensureRunning()
    }

    /// Called when Orbit quits.
    func stop() {
        stopping = true
        process?.terminate()
        process = nil
    }

    /// The last part of OpenCode's log (for Diagnostics).
    func logTail(maxBytes: Int = 4000) -> String {
        guard let data = try? Data(contentsOf: logURL) else { return "" }
        return String(decoding: data.suffix(maxBytes), as: UTF8.self)
    }

    /// Looks in the usual install locations, then asks a login shell.
    nonisolated static func locate() async -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.opencode/bin/opencode", "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode", "\(home)/.local/bin/opencode",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return await Task.detached(priority: .utility) { () -> String? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "command -v opencode"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }.value
    }
}
