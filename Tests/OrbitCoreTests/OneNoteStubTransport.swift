import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OrbitCore

/// Canned HTTP responses for the notes tests. Routes match when the (decoded) URL
/// contains the pattern; the longest matching pattern wins.
final class NotesStubTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data
    }

    private let lock = NSLock()
    private var routes: [(pattern: String, reply: Reply)] = []
    private var _requests: [URLRequest] = []

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var requestedURLs: [String] { requests.map { $0.url?.absoluteString.removingPercentEncoding ?? "" } }

    func on(_ pattern: String, _ reply: Reply) {
        lock.lock(); routes.append((pattern, reply)); lock.unlock()
    }

    func on(_ pattern: String, json: String) {
        on(pattern, Reply(body: Data(json.utf8)))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!.absoluteString.removingPercentEncoding ?? request.url!.absoluteString
        lock.lock()
        _requests.append(request)
        let match = routes.filter { url.contains($0.pattern) }.max { $0.pattern.count < $1.pattern.count }
        lock.unlock()
        let reply = match?.reply ?? Reply(status: 404, body: Data("{\"error\":\"no stub for \(url)\"}".utf8))
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        return (reply.body, response)
    }
}

/// Shared fixtures: a OneNote page as Graph returns it with `includeInkML=true`.
enum NotesFixtures {
    static let pageHTML = """
    <html lang="en-GB">
    <head>
    <title>BEM2031 Week 5 &#8211; Market failure</title>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
    <meta name="created" content="2025-10-14T10:05:00.0000000+01:00" />
    </head>
    <body data-absolute-enabled="true" style="font-family:Calibri;font-size:11pt">
    <div id="div:{keypts}{1}" data-id="keypts" style="position:absolute;left:48px;top:620px;width:600px">
    <h2 id="h2:{a}">Key points</h2>
    <ul>
    <li>Externalities cause market failure</li>
    <li>Pigouvian tax corrects negative externalities</li>
    </ul>
    <p data-tag="to-do">Read Ch. 4</p>
    <p>Merit goods &amp; public goods are <span style="font-weight:bold">under-provided</span></p>
    <table border="1"><tr><td><p>Type</p></td><td>Example</td></tr><tr><td>Negative</td><td>Pollution</td></tr></table>
    <img alt="Supply and demand graph" width="300" height="200"
      src="https://graph.microsoft.com/v1.0/users('me')/onenote/resources/0-img!1-abc/$value" data-src-type="image/png"
      data-fullres-src="https://graph.microsoft.com/v1.0/users('me')/onenote/resources/0-imgfull!1-abc/$value" data-fullres-src-type="image/png" />
    </div>
    <div data-id="heading" style="position:absolute;left:48px;top:40pt"><p>Lecture&nbsp;5</p></div>
    <!-- a comment <p>ignored</p> -->
    <object data-attachment="slides.pdf" type="application/pdf" data="https://graph.microsoft.com/v1.0/users('me')/onenote/resources/0-pdf/$value" style="position:absolute;left:700px;top:40px"></object>
    </body>
    </html>
    """

    /// OneNote-style InkML: namespaced, context with resolution, brush, trace group with annotation.
    static let inkML = """
    <?xml version="1.0" encoding="utf-8"?>
    <inkml:ink xmlns:emma="http://www.w3.org/2003/04/emma" xmlns:msink="http://schemas.microsoft.com/ink/2010/main" xmlns:inkml="http://www.w3.org/2003/InkML">
      <inkml:definitions>
        <inkml:context xml:id="ctxCoordinatesWithPressure">
          <inkml:inkSource xml:id="inkSrcCoordinatesWithPressure">
            <inkml:traceFormat>
              <inkml:channel name="X" type="integer" max="32767" units="himetric"/>
              <inkml:channel name="Y" type="integer" max="32767" units="himetric"/>
              <inkml:channel name="F" type="integer" max="32767" units="dev"/>
            </inkml:traceFormat>
            <inkml:channelProperties>
              <inkml:channelProperty channel="X" name="resolution" value="1" units="1/himetric"/>
              <inkml:channelProperty channel="Y" name="resolution" value="1" units="1/himetric"/>
              <inkml:channelProperty channel="F" name="resolution" value="1" units="1/dev"/>
            </inkml:channelProperties>
          </inkml:inkSource>
        </inkml:context>
        <inkml:brush xml:id="br0">
          <inkml:brushProperty name="width" value="100" units="himetric"/>
          <inkml:brushProperty name="height" value="100" units="himetric"/>
          <inkml:brushProperty name="color" value="#1F1F1F"/>
          <inkml:brushProperty name="transparency" value="0"/>
          <inkml:brushProperty name="tip" value="ellipse"/>
        </inkml:brush>
      </inkml:definitions>
      <inkml:traceGroup>
        <inkml:annotationXML>
          <emma:emma version="1.0"><emma:interpretation id="{A1}" emma:medium="tactile" emma:mode="ink"><msink:context type="inkDrawing"/></emma:interpretation></emma:emma>
        </inkml:annotationXML>
        <inkml:trace xml:id="st0" contextRef="#ctxCoordinatesWithPressure" brushRef="#br0">3969 3969 16000, '265 '0 '100, "0 "0 "0</inkml:trace>
        <inkml:trace xml:id="st1" contextRef="#ctxCoordinatesWithPressure" brushRef="#br0">3969 4500 16000, '0'265'0</inkml:trace>
      </inkml:traceGroup>
    </inkml:ink>
    """

    static let boundary = "Part_ab12"

    static var multipartBody: Data {
        let crlf = "\r\n"
        var s = "--\(boundary)\(crlf)"
        s += "Content-Type: text/html\(crlf)Content-Disposition: form-data; name=\"presentation\"\(crlf)\(crlf)"
        s += pageHTML + crlf
        s += "--\(boundary)\(crlf)"
        s += "Content-Type: application/inkml+xml\(crlf)\(crlf)"
        s += inkML + crlf
        s += "--\(boundary)--\(crlf)"
        return Data(s.utf8)
    }
}
