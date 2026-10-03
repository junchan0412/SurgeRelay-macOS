import Foundation
import XCTest
@testable import SurgeRelay

final class SourceRevisionServiceTests: XCTestCase {
    func testNotModifiedMetricsCountZeroResponseBodyAndNoConversion() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SourceRevisionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        SourceRevisionURLProtocol.response = (304, ["ETag": "v1"], Data())
        let module = RelayModule(name: "Metrics", sourceURL: "https://example.com/metrics.sgmodule", outputFileName: "Metrics", sourceContentHash: "cached")
        let metrics = StageMetricsRecorder()
        _ = try await StageMetricsContext.$current.withValue(metrics) { try await SourceRevisionService(session: session).check(module) }
        let download = try XCTUnwrap(metrics.snapshot.first { $0.stage == .download })
        XCTAssertEqual(download.bytesRead, 0)
        XCTAssertEqual(download.attempts, 1)
        XCTAssertEqual(download.result, .completed)
        XCTAssertNil(metrics.snapshot.first { $0.stage == .conversion })
    }

    func testRetryAfterParsesSecondsHTTPDatesAndKeepsOriginalRequestIdentity() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(SourceRetryAfterError.deadline("120", now: now), now.addingTimeInterval(120))
        XCTAssertEqual(SourceRetryAfterError.deadline(" 0 ", now: now), now)
        let date = try XCTUnwrap(SourceRetryAfterError.deadline("Wed, 21 Oct 2015 07:28:00 GMT", now: now))
        XCTAssertEqual(date.timeIntervalSince1970, 1_445_412_480)
        for value in ["-1", "1.5", "tomorrow", "Infinity", ""] { XCTAssertNil(SourceRetryAfterError.deadline(value, now: now)) }
        let original = URL(string: "https://example.com/source")!
        let response = HTTPURLResponse(url: URL(string: "https://cdn.example.com/redirected")!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "120"])!
        let failure = try XCTUnwrap(SourceRetryAfterError.response(response, requestedURL: original, now: now))
        XCTAssertEqual(failure.sourceURL, original.absoluteString)
        XCTAssertEqual(failure.responseURL, response.url?.absoluteString)
        XCTAssertEqual(failure.retryAt, now.addingTimeInterval(120))
    }

    func testSourceAndNativeConversionReturnRetryAfterWithoutImmediateRetry() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SourceRevisionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        SourceRevisionURLProtocol.requestedURLs = []
        SourceRevisionURLProtocol.response = (429, ["Retry-After": "600"], Data("rate limited".utf8))
        let module = RelayModule(name: "Limited", sourceURL: "https://example.com/limited.sgmodule", outputFileName: "Limited")
        let before = Date.now
        do {
            _ = try await SourceRevisionService(session: session).check(module)
            XCTFail("Retry-After should reach the update scheduler")
        } catch let error as SourceRetryAfterError {
            XCTAssertEqual(error.statusCode, 429)
            XCTAssertEqual(error.sourceURL, module.updateSourceURL)
            XCTAssertGreaterThanOrEqual(error.retryAt, before.addingTimeInterval(600))
        }
        XCTAssertEqual(SourceRevisionURLProtocol.requestedURLs.count, 1)
        do {
            _ = try await ScriptHubClient(session: session).convert(module: module)
            XCTFail("Native conversion should also retain Retry-After")
        } catch let error as SourceRetryAfterError { XCTAssertEqual(error.statusCode, 429) }
        XCTAssertEqual(SourceRevisionURLProtocol.requestedURLs.count, 2)
    }

    func testNativeConversionReusesCheckedResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SourceRevisionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        SourceRevisionURLProtocol.requestedURLs = []
        SourceRevisionURLProtocol.response = (200, ["ETag": "new-version"], Data("#!name=DNS\n[Rule]\nDOMAIN,example.org,DIRECT\n".utf8))
        let module = RelayModule(name: "DNS", sourceURL: "https://example.org/dns.sgmodule", outputFileName: "DNS")
        let revision = try await SourceRevisionService(session: session).check(module, hasCache: false)
        guard case let .changed(snapshot) = revision else { return XCTFail("A new source must be converted") }
        let result = try await ScriptHubClient(session: session).convert(module: module, sourceData: snapshot.data)
        XCTAssertTrue(result.content.contains("DOMAIN,example.org,DIRECT"))
        XCTAssertEqual(SourceRevisionURLProtocol.requestedURLs.count, 1)
        XCTAssertEqual(snapshot.etag, "new-version")
    }

    func testCachedRevisionHonorsNotModifiedResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SourceRevisionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        SourceRevisionURLProtocol.response = (304, ["ETag": "refreshed"], Data())
        let module = RelayModule(name: "DNS", sourceURL: "https://example.org/dns.sgmodule", outputFileName: "DNS", sourceContentHash: "existing-hash")
        let revision = try await SourceRevisionService(session: session).check(module)
        guard case let .unchanged(snapshot) = revision else { return XCTFail("304 must reuse existing cache") }
        XCTAssertEqual(snapshot.contentHash, "existing-hash")
        XCTAssertEqual(snapshot.etag, "refreshed")
        XCTAssertNil(snapshot.data)
    }

    func testRecognizesUnchangedContent() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SourceRevisionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        SourceRevisionURLProtocol.requestedURLs = []
        SourceRevisionURLProtocol.response = (200, ["ETag": "demo-v1"], Data("same".utf8))
        let module = RelayModule(
            name: "Demo",
            sourceURL: "https://example.com/demo.sgmodule",
            outputFileName: "Demo",
            sourceContentHash: Data("same".utf8).sha256String
        )

        let result = try await SourceRevisionService(session: session).check(module)

        guard case let .unchanged(snapshot) = result else {
            return XCTFail("Expected unchanged source")
        }
        XCTAssertEqual(snapshot.etag, "demo-v1")
    }

    func testChecksResolvedUpdateSourceURL() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SourceRevisionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        SourceRevisionURLProtocol.requestedURLs = []
        SourceRevisionURLProtocol.response = (200, [:], Data("rewrite".utf8))
        let module = RelayModule(
            name: "Wrapped",
            sourceURL: "http://script.hub/file/_start_/https://raw.githubusercontent.com/example/repo/main/demo.conf/_end_/Demo.sgmodule?type=qx-rewrite&target=surge-module",
            outputFileName: "Demo",
            scriptHubSubscription: ScriptHubSubscriptionInfo(
                subscriptionURL: "http://script.hub/file/_start_/https://raw.githubusercontent.com/example/repo/main/demo.conf/_end_/Demo.sgmodule?type=qx-rewrite&target=surge-module",
                originalURL: "https://raw.githubusercontent.com/example/repo/main/demo.conf",
                outputName: "Demo.sgmodule",
                sourceType: "qx-rewrite",
                target: "surge-module",
                category: nil,
                options: ScriptHubOptions()
            )
        )

        _ = try await SourceRevisionService(session: session).check(module)

        XCTAssertEqual(
            SourceRevisionURLProtocol.requestedURLs.first?.absoluteString,
            "https://raw.githubusercontent.com/example/repo/main/demo.conf"
        )
    }
}

private final class SourceRevisionURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (status: Int, headers: [String: String], data: Data) = (200, [:], Data())
    nonisolated(unsafe) static var requestedURLs: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let responseValue = Self.response
        Self.requestedURLs.append(request.url!)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: responseValue.status,
            httpVersion: "HTTP/1.1",
            headerFields: responseValue.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseValue.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
