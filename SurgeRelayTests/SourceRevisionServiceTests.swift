import Foundation
import XCTest
@testable import SurgeRelay

final class SourceRevisionServiceTests: XCTestCase {
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

    func testChecksEffectiveOriginalSourceURL() async throws {
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
