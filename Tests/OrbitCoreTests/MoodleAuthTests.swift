import XCTest
@testable import OrbitCore

final class MoodleAuthTests: XCTestCase {
    let site = URL(string: "https://ele.exeter.ac.uk")!

    func callbackPayload(site: String = "https://ele.exeter.ac.uk", passport: String, privateToken: String? = "priv456") -> String {
        let raw = MD5.hex(site + passport) + ":::tok123" + (privateToken.map { ":::" + $0 } ?? "")
        return Data(raw.utf8).base64EncodedString()
    }

    func testLaunchURL() {
        let url = MoodleAuth.ssoLaunchURL(site: site, passport: "p123", urlScheme: "orbitmoodle")
        XCTAssertEqual(url.absoluteString,
                       "https://ele.exeter.ac.uk/admin/tool/mobile/launch.php?service=moodle_mobile_app&passport=p123&urlscheme=orbitmoodle")
    }

    func testParsesCallbackWithAndWithoutSlashes() throws {
        let payload = callbackPayload(passport: "p123")
        for s in ["orbitmoodle://token=\(payload)", "orbitmoodle:token=\(payload)", "moodlemobile://token=\(payload)"] {
            let creds = try MoodleAuth.parseSSOCallback(url: URL(string: s)!, passport: "p123", siteURL: site)
            XCTAssertEqual(creds.token, "tok123")
            XCTAssertEqual(creds.privateToken, "priv456")
            XCTAssertEqual(creds.siteURL.absoluteString, "https://ele.exeter.ac.uk")
        }
    }

    func testCallbackWithoutPrivateTokenAndPaddingStripped() throws {
        var payload = callbackPayload(passport: "zz", privateToken: nil)
        while payload.hasSuffix("=") { payload.removeLast() }
        let creds = try MoodleAuth.parseSSOCallback("orbitmoodle://token=\(payload)", passport: "zz", siteURL: site)
        XCTAssertEqual(creds.token, "tok123")
        XCTAssertNil(creds.privateToken)
    }

    func testAcceptsHTTPSignatureAndTrailingSlashSite() throws {
        let payload = callbackPayload(site: "http://ele.exeter.ac.uk", passport: "p1")
        let creds = try MoodleAuth.parseSSOCallback("orbitmoodle://token=\(payload)", passport: "p1",
                                                    siteURL: URL(string: "https://ele.exeter.ac.uk/")!)
        XCTAssertEqual(creds.token, "tok123")
    }

    func testRejectsWrongPassport() {
        let payload = callbackPayload(passport: "p123")
        XCTAssertThrowsError(try MoodleAuth.parseSSOCallback("orbitmoodle://token=\(payload)", passport: "other", siteURL: site)) {
            XCTAssertEqual($0 as? MoodleError, .signatureMismatch)
        }
        XCTAssertThrowsError(try MoodleAuth.parseSSOCallback("orbitmoodle://nothing", passport: "p", siteURL: site))
    }

    func testPasswordLoginSuccessAndError() async throws {
        let ok = UniStubTransport { req, fields in
            XCTAssertEqual(req.url?.path, "/login/token.php")
            XCTAssertEqual(fields["service"], "moodle_mobile_app")
            XCTAssertEqual(fields["username"], "cw123")
            return (200, #"{"token":"abc","privatetoken":"def"}"#)
        }
        let creds = try await MoodleAuth(http: HTTPClient(transport: ok)).passwordLogin(site: site, username: "cw123", password: "pw & more")
        XCTAssertEqual(creds, MoodleCredentials(siteURL: site, token: "abc", privateToken: "def"))
        XCTAssertEqual(ok.requests.first?.1["password"], "pw & more")

        let bad = UniStubTransport { _, _ in
            (200, #"{"error":"Invalid login, please try again","errorcode":"invalidlogin","stacktrace":null,"debuginfo":null}"#)
        }
        do {
            _ = try await MoodleAuth(http: HTTPClient(transport: bad)).passwordLogin(site: site, username: "u", password: "p")
            XCTFail("expected error")
        } catch let e as MoodleError {
            XCTAssertEqual(e, .login(errorCode: "invalidlogin", message: "Invalid login, please try again"))
        }
    }

    func testSiteConfigViaAjax() async throws {
        let t = UniStubTransport { req, _ in
            XCTAssertEqual(req.url?.path, "/lib/ajax/service-nologin.php")
            XCTAssertTrue(String(decoding: req.httpBody ?? Data(), as: UTF8.self).contains("tool_mobile_get_public_config"))
            return (200, #"[{"error":false,"data":{"wwwroot":"https://ele.exeter.ac.uk","sitename":"ELE","typeoflogin":2,"launchurl":"https://ele.exeter.ac.uk/admin/tool/mobile/launch.php","enablewebservices":1,"enablemobilewebservice":1,"identityproviders":[{"name":"Microsoft","iconurl":"","url":"https://ele.exeter.ac.uk/auth/oauth2/login.php?id=1"}]}}]"#)
        }
        let cfg = try await MoodleAuth(http: HTTPClient(transport: t)).siteConfig(site: site)
        XCTAssertEqual(cfg.loginType, .browser)
        XCTAssertTrue(cfg.loginType.usesSSO)
        XCTAssertTrue(cfg.isMobileAccessAvailable)
        XCTAssertEqual(cfg.identityProviders.map(\.name), ["Microsoft"])
        XCTAssertEqual(cfg.launchURL?.path, "/admin/tool/mobile/launch.php")
    }

    func testSiteConfigFallsBackToREST() async throws {
        let t = UniStubTransport { req, fields in
            if req.url?.path == "/lib/ajax/service-nologin.php" { return (404, "Not found") }
            XCTAssertEqual(fields["wsfunction"], "tool_mobile_get_public_config")
            XCTAssertNil(fields["wstoken"])
            return (200, #"{"sitename":"ELE","typeoflogin":1,"enablemobilewebservice":0}"#)
        }
        let cfg = try await MoodleAuth(http: HTTPClient(transport: t)).siteConfig(site: site)
        XCTAssertEqual(cfg.loginType, .app)
        XCTAssertFalse(cfg.isMobileAccessAvailable)
    }
}
