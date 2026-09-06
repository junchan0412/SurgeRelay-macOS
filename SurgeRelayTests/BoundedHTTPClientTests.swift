import Foundation
import XCTest
@testable import SurgeRelay

final class BoundedHTTPClientTests: XCTestCase {
    func testRejectsOversizedDeclaredAndChunkedResponses() async throws {
        for declaresLength in [true, false] {
            let fixture = HTTPFixture(data: Data(repeating: 1, count: 128), declaresLength: declaresLength)
            let (client, request) = makeRequest(fixture, limit: 64)
            do {
                _ = try await client.data(for: request)
                XCTFail("The size limit must apply before buffering the entire response")
            } catch let error as BoundedRemoteFetchError {
                XCTAssertEqual(error, .responseTooLarge(maximumSize: 64))
            }
        }
    }

    func testCancellationStopsNetworkTaskWithoutWaitingForTimeout() async throws {
        let started = expectation(description: "network request started")
        let stopped = expectation(description: "network request cancelled")
        let fixture = HTTPFixture(data: Data(), neverFinishes: true, onStart: { started.fulfill() }, onStop: { stopped.fulfill() })
        let (client, request) = makeRequest(fixture)
        let task = Task { try await client.data(for: request) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [stopped], timeout: 2)
        do {
            _ = try await task.value
            XCTFail("Cancelled request must not succeed")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }

    func testConcurrentResponsesStayAssociatedWithTheirRequests() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedFixtureProtocol.self]
        let client = BoundedHTTPClient(configuration: configuration)
        let requests = (0..<16).map { value in
            BoundedFixtureProtocol.register(HTTPFixture(data: Data("response-\(value)".utf8)))
        }
        let values = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask { (index, try await client.data(for: request).0) }
            }
            var results: [Int: Data] = [:]
            for try await (index, data) in group { results[index] = data }
            return results
        }
        for index in requests.indices { XCTAssertEqual(values[index], Data("response-\(index)".utf8)) }
    }

    func testAlreadyCancelledRequestDoesNotStartNetwork() async throws {
        let fixture = HTTPFixture(data: Data("unused".utf8))
        let (client, request) = makeRequest(fixture)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.data(for: request)
        }
        do { _ = try await task.value; XCTFail("Cancellation must be checked before starting") }
        catch { XCTAssertTrue(error is CancellationError) }
        BoundedFixtureProtocol.unregister(request)
    }

    private func makeRequest(_ fixture: HTTPFixture, limit: Int = 1024) -> (BoundedHTTPClient, URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedFixtureProtocol.self]
        return (BoundedHTTPClient(maximumResponseSize: limit, configuration: configuration), BoundedFixtureProtocol.register(fixture))
    }
}

private struct HTTPFixture: Sendable {
    let data: Data
    var declaresLength = false
    var neverFinishes = false
    var onStart: @Sendable () -> Void = {}
    var onStop: @Sendable () -> Void = {}
}

private final class BoundedFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [URL: HTTPFixture] = [:]
    private var fixture: HTTPFixture?

    static func register(_ fixture: HTTPFixture) -> URLRequest {
        let url = URL(string: "https://test.invalid/\(UUID().uuidString)")!
        lock.withLock { fixtures[url] = fixture }
        return URLRequest(url: url)
    }

    static func unregister(_ request: URLRequest) {
        if let url = request.url { _ = lock.withLock { fixtures.removeValue(forKey: url) } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let fixture = Self.lock.withLock({ Self.fixtures.removeValue(forKey: url) }) else { return }
        self.fixture = fixture
        fixture.onStart()
        if fixture.neverFinishes { return }
        let headers = fixture.declaresLength ? ["Content-Length": String(fixture.data.count)] : [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { fixture?.onStop() }
}
