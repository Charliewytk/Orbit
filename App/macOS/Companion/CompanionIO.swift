import AppKit
import Foundation
import Speech
import WebKit
import OrbitCore

/// Fetches with the cookies of Orbit's own website data store (ELE, Panopto, Echo360, FT, Economist sign-ins
/// done in Orbit's web windows). No passwords are ever seen or stored by Orbit.
enum CookieFetcher {
    static let domains = ["exeter.ac.uk", "panopto", "echo360", "ft.com", "economist.com"]
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    @MainActor
    static func syncCookies() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for c in cookies where domains.contains(where: { c.domain.contains($0) }) {
            HTTPCookieStorage.shared.setCookie(c)
        }
    }

    static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.httpShouldHandleCookies = true
        return req
    }

    static func data(_ url: URL) async throws -> (Data, URLResponse) {
        await syncCookies()
        let (data, response) = try await URLSession.shared.data(for: request(url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return (data, response)
    }

    /// Downloads to a temporary file (kept only until transcription finishes).
    static func download(_ url: URL) async throws -> URL {
        await syncCookies()
        let (tmp, response) = try await URLSession.shared.download(for: request(url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-lecture-\(UUID().uuidString).\(ext)")
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}

/// On-device transcription: Apple Speech (on-device only), or whisper.cpp when installed.
enum LocalTranscriber {
    enum Failure: Error { case notAuthorized, unavailable, noOutput }

    static let locale = Locale(identifier: "en-GB")

    static var appleOnDeviceAvailable: Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status != .denied, status != .restricted, let r = SFSpeechRecognizer(locale: locale) else { return false }
        return r.supportsOnDeviceRecognition
    }

    private final class Once { var done = false }

    static func transcribeApple(_ file: URL) async throws -> String {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized, let recognizer = SFSpeechRecognizer(locale: locale) else { throw Failure.notAuthorized }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let once = Once()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            recognizer.recognitionTask(with: request) { result, error in
                guard !once.done else { return }
                if let result, result.isFinal {
                    once.done = true
                    c.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    once.done = true
                    c.resume(throwing: error)
                }
            }
        }
    }

    static func whisperBinary() -> String? {
        guard whisperModel() != nil else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/whisper-cli", "/opt/homebrew/bin/whisper-cpp", "/usr/local/bin/whisper-cli",
                          "/usr/local/bin/whisper-cpp", "\(home)/whisper.cpp/build/bin/whisper-cli", "\(home)/whisper.cpp/main"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func whisperModel() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let dirs = ["\(home)/Library/Application Support/Orbit/whisper", "/opt/homebrew/share/whisper-cpp",
                    "/usr/local/share/whisper-cpp", "\(home)/whisper.cpp/models"]
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            if let f = files.filter({ $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }).sorted().first { return "\(dir)/\(f)" }
        }
        return nil
    }

    static func transcribeWhisper(_ file: URL) async throws -> String {
        guard let binary = whisperBinary(), let model = whisperModel() else { throw Failure.unavailable }
        let wav = file.deletingPathExtension().appendingPathExtension("wav")
        let base = file.deletingPathExtension().path + "-transcript"
        defer {
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(atPath: base + ".txt")
        }
        try await run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", file.path, wav.path])
        try await run(binary, TranscriptSource.whisperArguments(model: model, audio: wav.path, outputBase: base))
        guard let text = try? String(contentsOfFile: base + ".txt", encoding: .utf8), !text.isEmpty else { throw Failure.noOutput }
        return text
    }

    private static func run(_ path: String, _ args: [String]) async throws {
        try await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 { throw Failure.noOutput }
        }.value
    }
}

/// Optional sign-in to ft.com / economist.com in Orbit's own web window. Cookies stay in the
/// app's website data store (like ELE); Orbit never sees or stores the password.
@MainActor
enum NewsLogin {
    enum Site: String, CaseIterable, Identifiable {
        case ft = "Financial Times", economist = "The Economist"
        var id: String { rawValue }
        var url: URL {
            switch self {
            case .ft: URL(string: "https://www.ft.com/login")!
            case .economist: URL(string: "https://www.economist.com/api/auth/login")!
            }
        }
        var host: String { self == .ft ? "ft.com" : "economist.com" }
    }

    private static var windows: [NSWindow] = []

    static func open(_ site: Site) {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 720), configuration: ELEWebSession.makeConfiguration())
        view.customUserAgent = CookieFetcher.userAgent
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sign in to \(site.rawValue)"
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        view.load(URLRequest(url: site.url))
        windows.append(window)
    }

    static func signOut(_ site: Site) async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records.filter { $0.displayName.contains(site.host) })
        for c in HTTPCookieStorage.shared.cookies ?? [] where c.domain.contains(site.host) { HTTPCookieStorage.shared.deleteCookie(c) }
    }
}
