import XCTest
@testable import SurgeRelay

final class WebRequestSecurityTests: XCTestCase {
    func testAllowsSessionBootstrapWithValidToken() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: false, accessToken: "secret")
        let request = WebHTTPRequest(
            method: "POST",
            path: "/api/session",
            query: [:],
            headers: [
                "authorization": "Bearer secret",
                "host": "127.0.0.1:8787",
                "origin": "http://127.0.0.1:8787"
            ],
            body: Data(),
            isLoopback: true
        )

        XCTAssertNil(WebRequestSecurity.rejection(for: request, configuration: configuration))
    }

    func testRejectsMissingOrWrongSessionBootstrapToken() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let missing = WebHTTPRequest(
            method: "POST",
            path: "/api/session",
            query: [:],
            headers: ["host": "127.0.0.1:8787", "origin": "http://127.0.0.1:8787"],
            body: Data(),
            isLoopback: true
        )
        let wrong = WebHTTPRequest(
            method: "POST",
            path: "/api/session",
            query: ["token": "wrong"],
            headers: ["host": "127.0.0.1:8787", "origin": "http://127.0.0.1:8787"],
            body: Data(),
            isLoopback: true
        )

        XCTAssertEqual(WebRequestSecurity.rejection(for: missing, configuration: configuration)?.status, 401)
        XCTAssertEqual(WebRequestSecurity.rejection(for: wrong, configuration: configuration)?.status, 401)
    }

    func testRejectsRawTokenForRegularAPI() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let request = WebHTTPRequest(
            method: "GET",
            path: "/api/state",
            query: ["token": "secret"],
            headers: [:],
            body: Data(),
            isLoopback: true
        )

        XCTAssertEqual(WebRequestSecurity.rejection(for: request, configuration: configuration)?.status, 401)
    }

    func testAllowsBearerTokenForNonBrowserAPI() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let request = WebHTTPRequest(
            method: "POST",
            path: "/api/update-all",
            query: [:],
            headers: ["authorization": "Bearer secret"],
            body: Data(),
            isLoopback: false
        )

        XCTAssertNil(WebRequestSecurity.rejection(for: request, configuration: configuration))
    }

    func testAllowsSessionCookieWithoutQueryToken() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let session = WebRequestSecurity.sessionCookieValue(for: "secret")
        let request = WebHTTPRequest(
            method: "GET",
            path: "/api/events",
            query: [:],
            headers: ["cookie": "other=value; \(WebRequestSecurity.sessionCookieName)=\(session)"],
            body: Data(),
            isLoopback: true
        )

        XCTAssertNil(WebRequestSecurity.rejection(for: request, configuration: configuration))
    }

    func testRejectsWrongSessionCookie() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let request = WebHTTPRequest(
            method: "GET",
            path: "/api/events",
            query: [:],
            headers: ["cookie": "\(WebRequestSecurity.sessionCookieName)=wrong"],
            body: Data(),
            isLoopback: true
        )

        XCTAssertEqual(WebRequestSecurity.rejection(for: request, configuration: configuration)?.status, 401)
    }

    func testSessionCookieHeaderDoesNotExposeRawToken() {
        let header = WebRequestSecurity.sessionCookieHeader(accessToken: "secret-token")

        XCTAssertFalse(header.contains("secret-token"))
        XCTAssertTrue(header.contains("\(WebRequestSecurity.sessionCookieName)="))
        XCTAssertTrue(header.contains("HttpOnly"))
        XCTAssertTrue(header.contains("SameSite=Strict"))
        XCTAssertTrue(header.contains("Path=/api"))
    }

    func testRejectsCrossOriginUnsafeRequests() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let session = WebRequestSecurity.sessionCookieValue(for: "secret")
        let request = WebHTTPRequest(
            method: "POST",
            path: "/api/update-all",
            query: [:],
            headers: [
                "cookie": "\(WebRequestSecurity.sessionCookieName)=\(session)",
                "host": "127.0.0.1:8787",
                "origin": "http://evil.example"
            ],
            body: Data(),
            isLoopback: true
        )

        XCTAssertEqual(WebRequestSecurity.rejection(for: request, configuration: configuration)?.status, 403)
    }

    func testAllowsSameOriginUnsafeRequestsWithSessionCookie() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let session = WebRequestSecurity.sessionCookieValue(for: "secret")
        let request = WebHTTPRequest(
            method: "POST",
            path: "/api/update-all",
            query: [:],
            headers: [
                "cookie": "\(WebRequestSecurity.sessionCookieName)=\(session)",
                "host": "127.0.0.1:8787",
                "origin": "http://127.0.0.1:8787"
            ],
            body: Data(),
            isLoopback: true
        )

        XCTAssertNil(WebRequestSecurity.rejection(for: request, configuration: configuration))
    }

    func testAllowsSameOriginRefererWhenOriginIsMissing() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let session = WebRequestSecurity.sessionCookieValue(for: "secret")
        let request = WebHTTPRequest(
            method: "POST",
            path: "/api/update-all",
            query: [:],
            headers: [
                "cookie": "\(WebRequestSecurity.sessionCookieName)=\(session)",
                "host": "127.0.0.1:8787",
                "referer": "http://127.0.0.1:8787/"
            ],
            body: Data(),
            isLoopback: true
        )

        XCTAssertNil(WebRequestSecurity.rejection(for: request, configuration: configuration))
    }

    func testRejectsUnsafeSessionCookieWithoutOriginRefererOrBearer() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let session = WebRequestSecurity.sessionCookieValue(for: "secret")
        let request = WebHTTPRequest(
            method: "POST",
            path: "/api/update-all",
            query: [:],
            headers: [
                "cookie": "\(WebRequestSecurity.sessionCookieName)=\(session)",
                "host": "127.0.0.1:8787"
            ],
            body: Data(),
            isLoopback: true
        )

        XCTAssertEqual(WebRequestSecurity.rejection(for: request, configuration: configuration)?.status, 403)
    }

    func testAuthenticationThrottleLimitsRepeatedFailuresAndClearsOnSuccess() {
        let throttle = WebAuthenticationThrottle(maxFailures: 2, window: 60)
        let now = Date(timeIntervalSince1970: 1_000)
        let request = WebHTTPRequest(
            method: "GET",
            path: "/api/state",
            query: [:],
            headers: [:],
            body: Data(),
            isLoopback: false,
            clientIdentifier: "192.0.2.10"
        )

        XCTAssertNil(throttle.rejection(for: request, now: now))
        throttle.recordFailure(for: request, now: now)
        XCTAssertNil(throttle.rejection(for: request, now: now.addingTimeInterval(1)))
        throttle.recordFailure(for: request, now: now.addingTimeInterval(2))
        XCTAssertEqual(throttle.rejection(for: request, now: now.addingTimeInterval(3))?.status, 429)
        throttle.recordSuccess(for: request)
        XCTAssertNil(throttle.rejection(for: request, now: now.addingTimeInterval(4)))
    }

    func testRejectsRemoteWhenDisabled() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: false, accessToken: "secret")
        let request = WebHTTPRequest(
            method: "GET",
            path: "/api/state",
            query: ["token": "secret"],
            headers: [:],
            body: Data(),
            isLoopback: false
        )

        XCTAssertEqual(WebRequestSecurity.rejection(for: request, configuration: configuration)?.status, 403)
    }

    func testAllowsRemoteWhenEnabledAndSessionCookieMatches() {
        let configuration = WebServerConfiguration(port: 8787, allowRemoteAccess: true, accessToken: "secret")
        let session = WebRequestSecurity.sessionCookieValue(for: "secret")
        let request = WebHTTPRequest(
            method: "POST",
            path: "/api/update-all",
            query: [:],
            headers: [
                "cookie": "\(WebRequestSecurity.sessionCookieName)=\(session)",
                "host": "relay.local:8787",
                "origin": "http://relay.local:8787"
            ],
            body: Data(),
            isLoopback: false
        )

        XCTAssertNil(WebRequestSecurity.rejection(for: request, configuration: configuration))
    }
}
