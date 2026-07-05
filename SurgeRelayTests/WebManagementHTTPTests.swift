import XCTest
@testable import SurgeRelay

final class WebManagementHTTPTests: XCTestCase {
    func testErrorPayloadIncludesUserFacingMessage() throws {
        let response = WebHTTPResponse.error(status: 409, message: "该模块已经添加，不能重复添加。")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: String])

        XCTAssertEqual(response.status, 409)
        XCTAssertEqual(payload["message"], "该模块已经添加，不能重复添加。")
    }

    func testRequestParserReadsJSONBodyAndQuery() throws {
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

    func testRequestParserRejectsInvalidContentLength() {
        let negative = "POST /api/update-all HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: -1\r\n\r\n"
        let huge = "POST /api/update-all HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 999999999\r\n\r\n"

        guard case .invalid = WebManagementServer.parseRequestResult(Data(negative.utf8), isLoopback: true) else {
            return XCTFail("negative Content-Length must be invalid")
        }
        guard case .invalid = WebManagementServer.parseRequestResult(Data(huge.utf8), isLoopback: true) else {
            return XCTFail("oversized Content-Length must be invalid")
        }
    }

    func testRequestParserDistinguishesIncompleteBodyFromInvalidLength() {
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

    func testResponseSecurityAddsNoStoreAndBrowserHardeningHeadersToAPIResponses() {
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

    func testResponseSecurityPreservesExplicitCacheControl() {
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

    func testResponseSecurityHardensEventStreamHeaders() {
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
}
