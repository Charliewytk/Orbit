import Foundation
import Network
import OrbitCore

/// A one-shot HTTP listener on 127.0.0.1:<port> that catches the OAuth redirect
/// (GET /monzo/callback?code=…&state=…), answers with a short page and returns the query.
final class LoopbackCallbackReceiver: @unchecked Sendable {
    enum Failure: LocalizedError {
        case timedOut, portBusy(String), cancelled
        var errorDescription: String? {
            switch self {
            case .timedOut: "Timed out waiting for Monzo's sign-in page to send you back."
            case .portBusy(let d): "Couldn't listen on 127.0.0.1:\(MonzoClientConfig.redirectPort) (\(d)). Is another app using that port?"
            case .cancelled: "Cancelled."
            }
        }
    }

    private let lock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private let queue = DispatchQueue(label: "orbit.monzo.loopback")

    /// Waits for one request to `path` and returns its query items.
    func wait(port: UInt16 = MonzoClientConfig.redirectPort, path: String = MonzoClientConfig.redirectPath,
              timeout: TimeInterval = 300, ready: @escaping @Sendable () -> Void) async throws -> [String: String] {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw Failure.portBusy("bad port") }
        let listener: NWListener
        do { listener = try NWListener(using: params, on: nwPort) } catch { throw Failure.portBusy(error.localizedDescription) }
        self.listener = listener

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
            lock.lock(); continuation = cont; lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: ready()
                case .failed(let error): self?.finish(.failure(Failure.portBusy(error.localizedDescription)))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn, path: path) }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(Failure.timedOut)) }
        }
    }

    func cancel() { finish(.failure(Failure.cancelled)) }

    private func handle(_ conn: NWConnection, path: String) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            let target = parts.count >= 2 ? String(parts[1]) : ""
            let comps = URLComponents(string: "http://127.0.0.1" + target)
            let matches = comps?.path == path
            let body = matches
                ? "<html><body style=\"font-family:-apple-system;padding:40px\"><h2>Monzo is connected to Orbit.</h2><p>Now approve Orbit in your Monzo app, then return to Orbit. You can close this tab.</p></body></html>"
                : "<html><body>Not found</body></html>"
            let response = "HTTP/1.1 \(matches ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            guard matches else { return }
            var items: [String: String] = [:]
            for q in comps?.queryItems ?? [] { items[q.name] = q.value ?? "" }
            self?.finish(.success(items))
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let l = listener
        listener = nil
        lock.unlock()
        l?.cancel()
        guard let cont else { return }
        switch result {
        case .success(let v): cont.resume(returning: v)
        case .failure(let e): cont.resume(throwing: e)
        }
    }
}
