import Foundation

final class GitHubMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (status: Int, data: Data))?
    nonisolated(unsafe) static var requestedPaths: [String] = []

    static func reset() {
        handler = nil
        requestedPaths = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let url = request.url!
        let query = url.query.map { "?\($0)" } ?? ""
        Self.requestedPaths.append("\(method) \(url.path)\(query)")
        let responseValue = Self.handler?(request) ?? (500, Data(#"{"message":"unhandled request"}"#.utf8))
        let response = HTTPURLResponse(
            url: url,
            statusCode: responseValue.0,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseValue.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
