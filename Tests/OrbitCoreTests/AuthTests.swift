import XCTest
@testable import OrbitCore

final class AuthSHA256Tests: XCTestCase {
    func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    func testKnownVectors() {
        let vectors: [(String, String)] = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
             "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
            ("The quick brown fox jumps over the lazy dog",
             "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(hex(SHA256Digest.pureSwiftHash(Data(input.utf8))), expected, input)
            XCTAssertEqual(hex(SHA256Digest.hash(Data(input.utf8))), expected, input)
        }
    }

    func testPaddingBoundaries() {
        let expected: [Int: String] = [
            55: "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
            56: "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
            63: "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
            64: "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
            65: "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
            1000: "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3",
        ]
        for (n, h) in expected {
            XCTAssertEqual(hex(SHA256Digest.pureSwiftHash(Data(repeating: UInt8(ascii: "a"), count: n))), h, "\(n)")
        }
    }

    func testBase64URL() {
        let data = Data([0xfb, 0xff, 0xfe, 0x00, 0x01])
        let s = Base64URL.encode(data)
        XCTAssertEqual(s, "-__-AAE")
        XCTAssertEqual(Base64URL.decode(s), data)
    }

    func testStableUUIDIsDeterministic() {
        XCTAssertEqual(StableUUID.make("x"), StableUUID.make("x"))
        XCTAssertNotEqual(StableUUID.make("x"), StableUUID.make("y"))
    }
}

final class AuthPKCETests: XCTestCase {
    func testRFC7636Vector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(pkce.method, "S256")
    }

    func testRandomVerifier() {
        let a = PKCE(), b = PKCE()
        XCTAssertNotEqual(a.verifier, b.verifier)
        XCTAssertEqual(a.verifier.count, 43)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(a.verifier.unicodeScalars.allSatisfy(allowed.contains))
        XCTAssertEqual(a.challenge, PKCE.challenge(for: a.verifier))
        XCTAssertFalse(PKCE.randomState().isEmpty)
    }
}

final class AuthOAuthClientTests: XCTestCase {
    let now = SchedFixtures.date(2026, 10, 7, 10)

    func query(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for i in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[i.name] = i.value }
        return out
    }

    func testGoogleAuthorizeURL() {
        let config = OAuthConfig.google(clientID: "123.apps.googleusercontent.com",
                                        redirectURI: "com.googleusercontent.apps.123:/oauth2redirect")
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = OAuthClient(config: config).authorizationURL(state: "st", pkce: pkce, loginHint: "me@gmail.com")
        XCTAssertTrue(url.absoluteString.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth?"))
        let q = query(url)
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["client_id"], "123.apps.googleusercontent.com")
        XCTAssertEqual(q["redirect_uri"], "com.googleusercontent.apps.123:/oauth2redirect")
        XCTAssertEqual(q["scope"], "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/drive.file openid email")
        XCTAssertEqual(q["include_granted_scopes"], "true")
        XCTAssertEqual(q["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["access_type"], "offline")
        XCTAssertEqual(q["prompt"], "consent")
        XCTAssertEqual(q["state"], "st")
        XCTAssertEqual(q["login_hint"], "me@gmail.com")
        XCTAssertTrue(url.absoluteString.contains("scope=https%3A%2F%2Fwww.googleapis.com"))
        XCTAssertEqual(config.callbackScheme, "com.googleusercontent.apps.123")
    }

    func testMissingScopesForIncrementalAuth() {
        let old = OAuthTokens(accessToken: "a", scope: "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/calendar openid email")
        XCTAssertEqual(old.missingScopes([GmailClient.modifyScope]), [GmailClient.modifyScope])
        let fresh = OAuthTokens(accessToken: "a", scope: OAuthConfig.googleScopes.joined(separator: " "))
        XCTAssertEqual(fresh.missingScopes([GmailClient.modifyScope]), [])
        XCTAssertEqual(OAuthTokens(accessToken: "a").missingScopes([GmailClient.modifyScope]), [], "unknown scope isn't reported missing")
    }

    func testIncrementalGoogleConfigAsksOnlyForNewScope() {
        let config = OAuthConfig.google(clientID: "123.apps.googleusercontent.com",
                                        redirectURI: "com.googleusercontent.apps.123:/oauth2redirect")
            .incremental(adding: [GmailClient.modifyScope])
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let q = query(OAuthClient(config: config).authorizationURL(state: "st", pkce: pkce, loginHint: nil))
        XCTAssertEqual(q["scope"], "https://www.googleapis.com/auth/gmail.modify openid email")
        XCTAssertEqual(q["include_granted_scopes"], "true")
    }

    func testMicrosoftConfig() {
        let c = OAuthConfig.microsoft(clientID: "abc", redirectURI: "com.orbit.app://auth")
        XCTAssertEqual(c.authorizationEndpoint.absoluteString,
                       "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize")
        XCTAssertEqual(c.tokenEndpoint.absoluteString, "https://login.microsoftonline.com/organizations/oauth2/v2.0/token")
        XCTAssertEqual(c.scopes, ["offline_access", "User.Read", "Mail.Read", "Mail.ReadWrite", "Notes.Read", "Calendars.Read"])
        XCTAssertEqual(c.callbackScheme, "com.orbit.app")
    }

    func testCallbackParsing() throws {
        let client = OAuthClient(config: .google(clientID: "c", redirectURI: "com.orbit.app:/cb"))
        XCTAssertEqual(try client.code(from: URL(string: "com.orbit.app:/cb?code=4%2F0abc&state=s1")!, expecting: "s1"), "4/0abc")
        XCTAssertThrowsError(try client.code(from: URL(string: "com.orbit.app:/cb?code=x&state=evil")!, expecting: "s1")) {
            XCTAssertEqual($0 as? OAuthError, .stateMismatch)
        }
        XCTAssertThrowsError(try client.code(from: URL(string: "com.orbit.app:/cb?error=access_denied&state=s1")!, expecting: "s1")) {
            XCTAssertEqual($0 as? OAuthError, .cancelled)
        }
        XCTAssertThrowsError(try client.code(from: URL(string: "com.orbit.app:/cb?state=s1")!, expecting: "s1")) {
            XCTAssertEqual($0 as? OAuthError, .missingCode)
        }
    }

    func testExchangeCode() async throws {
        let stub = SchedStubTransport { _ in
            (200, #"{"access_token":"ya29.a","expires_in":3599,"refresh_token":"1//r","scope":"openid email","token_type":"Bearer","id_token":"x.eyJlbWFpbCI6Im1lQGdtYWlsLmNvbSJ9.y"}"#)
        }
        let client = OAuthClient(config: .google(clientID: "cid", redirectURI: "com.orbit.app:/cb", clientSecret: "sec"),
                                 http: HTTPClient(transport: stub))
        let pkce = PKCE(verifier: "verifier123")
        let tokens = try await client.exchange(code: "4/abc", pkce: pkce, now: now)
        XCTAssertEqual(tokens.accessToken, "ya29.a")
        XCTAssertEqual(tokens.refreshToken, "1//r")
        XCTAssertEqual(tokens.expiry, now.addingTimeInterval(3599))
        XCTAssertEqual(tokens.email, "me@gmail.com")

        let req = stub.requests[0]
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.url.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(req.headers["Content-Type"], "application/x-www-form-urlencoded")
        let body = req.bodyString
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=4%2Fabc"))
        XCTAssertTrue(body.contains("code_verifier=verifier123"))
        XCTAssertTrue(body.contains("client_secret=sec"))
        XCTAssertTrue(body.contains("redirect_uri=com.orbit.app%3A%2Fcb"))
    }

    func testRefreshKeepsOldRefreshToken() async throws {
        let stub = SchedStubTransport { _ in (200, #"{"access_token":"new","expires_in":3600}"#) }
        let client = OAuthClient(config: .microsoft(clientID: "cid", redirectURI: "com.orbit.app://auth"),
                                 http: HTTPClient(transport: stub))
        let old = OAuthTokens(accessToken: "old", refreshToken: "r1", expiry: now, scope: "Mail.Read", idToken: "id")
        let fresh = try await client.refresh(old, now: now)
        XCTAssertEqual(fresh.accessToken, "new")
        XCTAssertEqual(fresh.refreshToken, "r1")
        XCTAssertEqual(fresh.idToken, "id")
        XCTAssertEqual(fresh.scope, "Mail.Read")
        XCTAssertEqual(fresh.expiry, now.addingTimeInterval(3600))
        let body = stub.requests[0].bodyString
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=r1"))
        XCTAssertTrue(body.contains("scope=offline_access%20User.Read"), "Microsoft refresh sends scopes")
    }

    func testInvalidGrantMeansSignInAgain() async {
        let stub = SchedStubTransport { _ in (400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#) }
        let client = OAuthClient(config: .google(clientID: "c", redirectURI: "x:/y"), http: HTTPClient(transport: stub))
        do {
            _ = try await client.refresh(OAuthTokens(accessToken: "a", refreshToken: "r"))
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? OAuthError, .reauthenticationRequired("Token has been expired or revoked."))
        }
        do {
            _ = try await client.refresh(OAuthTokens(accessToken: "a"))
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? OAuthError, .noRefreshToken)
        }
    }
}

final class AuthSessionTests: XCTestCase {
    let now = SchedFixtures.date(2026, 10, 7, 10)

    func makeSession(expiresIn: TimeInterval, stub: SchedStubTransport, store: InMemoryTokenStore) -> OAuthSession {
        let fixed = now
        let client = OAuthClient(config: .google(clientID: "c", redirectURI: "x:/y"), http: HTTPClient(transport: stub))
        let tokens = OAuthTokens(accessToken: "cached", refreshToken: "r", expiry: now.addingTimeInterval(expiresIn))
        try? store.save(tokens, account: "google:me")
        return OAuthSession(account: "google:me", client: client, store: store, now: { fixed })
    }

    func testValidTokenNeedsNoRequest() async throws {
        let stub = SchedStubTransport { _ in (500, "{}") }
        let session = makeSession(expiresIn: 600, stub: stub, store: InMemoryTokenStore())
        let token = try await session.accessToken()
        XCTAssertEqual(token, "cached")
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testRefreshesWithinTwoMinutesAndSaves() async throws {
        let stub = SchedStubTransport { _ in (200, #"{"access_token":"fresh","expires_in":3600}"#) }
        let store = InMemoryTokenStore()
        let session = makeSession(expiresIn: 90, stub: stub, store: store)
        async let a = session.accessToken()
        async let b = session.accessToken()
        let (x, y) = try await (a, b)
        XCTAssertEqual(x, "fresh")
        XCTAssertEqual(y, "fresh")
        XCTAssertEqual(stub.requests.count, 1, "concurrent callers share one refresh")
        let saved = try store.load(account: "google:me")
        XCTAssertEqual(saved?.accessToken, "fresh")
        XCTAssertEqual(saved?.refreshToken, "r")
        let again = try await session.accessToken()
        XCTAssertEqual(again, "fresh")
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testSignOutAndNotSignedIn() async throws {
        let store = InMemoryTokenStore()
        let session = makeSession(expiresIn: 600, stub: SchedStubTransport { _ in (500, "{}") }, store: store)
        let signedIn = await session.isSignedIn
        XCTAssertTrue(signedIn)
        try await session.signOut()
        XCTAssertNil(try store.load(account: "google:me"))
        do {
            _ = try await session.accessToken()
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? OAuthError, .notSignedIn)
        }
        try await session.signIn(with: OAuthTokens(accessToken: "new"))
        let token = try await session.accessToken()
        XCTAssertEqual(token, "new")
        XCTAssertEqual(store.accounts, ["google:me"])
    }

    func testTokensAreCodable() throws {
        let t = OAuthTokens(accessToken: "a", refreshToken: "r", expiry: now, scope: "s", idToken: "i")
        XCTAssertEqual(try JSONDecoder().decode(OAuthTokens.self, from: JSONEncoder().encode(t)), t)
        XCTAssertTrue(t.expires(within: 120, of: now.addingTimeInterval(-60)))
        XCTAssertFalse(t.expires(within: 120, of: now.addingTimeInterval(-600)))
    }
}
