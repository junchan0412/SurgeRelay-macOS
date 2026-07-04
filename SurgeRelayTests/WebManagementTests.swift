import XCTest
@testable import SurgeRelay

final class WebManagementTests: XCTestCase {
    func testWebErrorPayloadIncludesUserFacingMessage() throws {
        let response = WebHTTPResponse.error(status: 409, message: "该模块已经添加，不能重复添加。")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: String])

        XCTAssertEqual(response.status, 409)
        XCTAssertEqual(payload["message"], "该模块已经添加，不能重复添加。")
    }

    func testWebIconContentTypeDetectionOnlyAcceptsRecognizedImages() {
        XCTAssertEqual(WebManagementAPI.imageContentType(Data([0x89, 0x50, 0x4E, 0x47, 0x0D])), "image/png")
        XCTAssertEqual(WebManagementAPI.imageContentType(Data([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
        XCTAssertEqual(WebManagementAPI.imageContentType(Data("GIF89a".utf8)), "image/gif")
        XCTAssertEqual(
            WebManagementAPI.imageContentType(Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])),
            "image/webp"
        )
        XCTAssertEqual(WebManagementAPI.imageContentType(Data("<?xml version=\"1.0\"?><svg></svg>".utf8)), "image/svg+xml")
        XCTAssertNil(WebManagementAPI.imageContentType(Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45])))
        XCTAssertNil(WebManagementAPI.imageContentType(Data("not an image".utf8)))
    }

    func testWebContentSecurityPolicyMatchesCustomIconValidation() {
        let policy = WebManagementAPI.webContentSecurityPolicy

        XCTAssertTrue(policy.contains("img-src"))
        XCTAssertTrue(policy.contains("http:"))
        XCTAssertTrue(policy.contains("https:"))
        XCTAssertTrue(policy.contains("data:"))
    }

    func testWebServerRuntimeStateHasUserFacingAndDiagnosticValues() {
        XCTAssertEqual(WebServerRuntimeState.running.title, "运行中")
        XCTAssertEqual(WebServerRuntimeState.running.diagnosticValue, "running")
        XCTAssertEqual(WebServerRuntimeState.running.systemImage, "checkmark.circle.fill")

        let failed = WebServerRuntimeState.failed("端口已被占用")
        XCTAssertEqual(failed.title, "启动失败")
        XCTAssertEqual(failed.diagnosticValue, "failed: 端口已被占用")
        XCTAssertEqual(failed.failureMessage, "端口已被占用")
    }

    func testWebManagementDisplayURLOmitsAccessToken() throws {
        let accessURL = try XCTUnwrap(WebManagementURLFactory.url(
            host: "relay.local",
            port: 8787,
            accessToken: "secret-token",
            includingToken: true
        ))
        let displayURL = try XCTUnwrap(WebManagementURLFactory.url(
            host: "relay.local",
            port: 8787,
            accessToken: "secret-token",
            includingToken: false
        ))

        XCTAssertEqual(accessURL.absoluteString, "http://relay.local:8787/?token=secret-token")
        XCTAssertEqual(displayURL.absoluteString, "http://relay.local:8787/")
        XCTAssertFalse(displayURL.absoluteString.contains("secret-token"))
    }

    func testWebRequestParserReadsJSONBodyAndQuery() throws {
        let body = #"{"enabled":true}"#
        let request = """
        POST /api/modules/demo/enabled?source=web HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """
        let parsed = try XCTUnwrap(WebManagementServer.parseRequest(Data(request.utf8), isLoopback: true))
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/api/modules/demo/enabled")
        XCTAssertEqual(parsed.query["source"], "web")
        XCTAssertEqual(String(data: parsed.body, encoding: .utf8), body)
        XCTAssertTrue(parsed.isLoopback)
    }

    func testWebRequestParserRejectsInvalidContentLength() {
        let negative = "POST /api/update-all HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: -1\r\n\r\n"
        let huge = "POST /api/update-all HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 999999999\r\n\r\n"

        guard case .invalid = WebManagementServer.parseRequestResult(Data(negative.utf8), isLoopback: true) else {
            return XCTFail("negative Content-Length must be invalid")
        }
        guard case .invalid = WebManagementServer.parseRequestResult(Data(huge.utf8), isLoopback: true) else {
            return XCTFail("oversized Content-Length must be invalid")
        }
    }

    func testWebRequestParserDistinguishesIncompleteBodyFromInvalidLength() {
        let request = """
        POST /api/update-all HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Length: 12\r
        \r
        short
        """

        guard case .incomplete = WebManagementServer.parseRequestResult(Data(request.utf8), isLoopback: true) else {
            return XCTFail("valid Content-Length with partial body should remain incomplete")
        }
    }

    func testWebRequestSecurityAllowsSessionBootstrapWithValidToken() {
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

    func testWebRequestSecurityRejectsMissingOrWrongSessionBootstrapToken() {
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

    func testWebRequestSecurityRejectsRawTokenForRegularAPI() {
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

    func testWebRequestSecurityAllowsBearerTokenForNonBrowserAPI() {
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

    func testWebRequestSecurityAllowsSessionCookieWithoutQueryToken() {
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

    func testWebRequestSecurityRejectsWrongSessionCookie() {
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

    func testWebSessionCookieHeaderDoesNotExposeRawToken() {
        let header = WebRequestSecurity.sessionCookieHeader(accessToken: "secret-token")

        XCTAssertFalse(header.contains("secret-token"))
        XCTAssertTrue(header.contains("\(WebRequestSecurity.sessionCookieName)="))
        XCTAssertTrue(header.contains("HttpOnly"))
        XCTAssertTrue(header.contains("SameSite=Strict"))
        XCTAssertTrue(header.contains("Path=/api"))
    }

    func testWebResponseSecurityAddsNoStoreAndBrowserHardeningHeadersToAPIResponses() {
        let request = WebHTTPRequest(
            method: "GET",
            path: "/api/state",
            query: [:],
            headers: [:],
            body: Data(),
            isLoopback: true
        )
        let headers = WebResponseSecurity.hardenedHeaders(
            for: request,
            responseHeaders: ["Content-Type": "application/json; charset=utf-8"]
        )

        XCTAssertEqual(headers["Cache-Control"], WebResponseSecurity.apiCacheControl)
        XCTAssertEqual(headers["Pragma"], "no-cache")
        XCTAssertEqual(headers["Expires"], "0")
        XCTAssertEqual(headers["X-Frame-Options"], "DENY")
        XCTAssertEqual(headers["X-Content-Type-Options"], "nosniff")
        XCTAssertEqual(headers["Referrer-Policy"], "no-referrer")
        XCTAssertEqual(headers["Permissions-Policy"], "camera=(), microphone=(), geolocation=()")
        XCTAssertEqual(headers["Cross-Origin-Opener-Policy"], "same-origin")
    }

    func testWebResponseSecurityPreservesExplicitCacheControl() {
        let request = WebHTTPRequest(
            method: "GET",
            path: "/api/modules/11111111-1111-1111-1111-111111111111/icon",
            query: [:],
            headers: [:],
            body: Data(),
            isLoopback: true
        )
        let headers = WebResponseSecurity.hardenedHeaders(
            for: request,
            responseHeaders: ["cache-control": "private, max-age=3600"]
        )

        XCTAssertEqual(headers["cache-control"], "private, max-age=3600")
        XCTAssertNil(headers["Cache-Control"])
        XCTAssertNil(headers["Pragma"])
        XCTAssertNil(headers["Expires"])
        XCTAssertEqual(headers["X-Frame-Options"], "DENY")
    }

    func testWebResponseSecurityHardensEventStreamHeaders() {
        let headers = WebResponseSecurity.eventStreamHeaders()

        XCTAssertEqual(headers["Content-Type"], "text/event-stream; charset=utf-8")
        XCTAssertEqual(headers["Cache-Control"], WebResponseSecurity.eventStreamCacheControl)
        XCTAssertEqual(headers["Pragma"], "no-cache")
        XCTAssertEqual(headers["Expires"], "0")
        XCTAssertEqual(headers["Connection"], "keep-alive")
        XCTAssertEqual(headers["X-Frame-Options"], "DENY")
        XCTAssertEqual(headers["X-Content-Type-Options"], "nosniff")
        XCTAssertEqual(headers["Referrer-Policy"], "no-referrer")
    }

    func testWebRequestSecurityRejectsCrossOriginUnsafeRequests() {
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

    func testWebRequestSecurityAllowsSameOriginUnsafeRequestsWithSessionCookie() {
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

    func testWebRequestSecurityAllowsSameOriginRefererWhenOriginIsMissing() {
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

    func testWebRequestSecurityRejectsUnsafeSessionCookieWithoutOriginRefererOrBearer() {
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

    func testWebAuthenticationThrottleLimitsRepeatedFailuresAndClearsOnSuccess() {
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

    func testWebRequestSecurityRejectsRemoteWhenDisabled() {
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

    func testWebRequestSecurityAllowsRemoteWhenEnabledAndSessionCookieMatches() {
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

    func testAppSettingsDecodesWebManagementDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.combinedModuleEnabled)
        XCTAssertFalse(settings.webServerEnabled)
        XCTAssertEqual(settings.webServerPort, 8787)
        XCTAssertFalse(settings.webServerAllowRemoteAccess)
    }
}
