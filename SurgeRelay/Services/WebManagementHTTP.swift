import Foundation

struct WebServerConfiguration: Sendable {
    let port: UInt16
    let allowRemoteAccess: Bool
    let accessToken: String
}

enum WebServerRuntimeState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case failed(String)

    var title: String {
        switch self {
        case .stopped: "已停止"
        case .starting: "正在启动"
        case .running: "运行中"
        case .failed: "启动失败"
        }
    }

    var diagnosticValue: String {
        switch self {
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case let .failed(message): "failed: \(message)"
        }
    }

    var systemImage: String {
        switch self {
        case .stopped: "pause.circle"
        case .starting: "clock"
        case .running: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var failureMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

enum WebManagementURLFactory {
    static func url(host: String, port: Int, accessToken: String, includingToken: Bool) -> URL? {
        guard (1...65_535).contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/"
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if includingToken, !token.isEmpty {
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        return components.url
    }
}

struct WebHTTPRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
    let isLoopback: Bool
    let clientIdentifier: String

    init(
        method: String,
        path: String,
        query: [String: String],
        headers: [String: String],
        body: Data,
        isLoopback: Bool,
        clientIdentifier: String = "loopback"
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.isLoopback = isLoopback
        self.clientIdentifier = clientIdentifier
    }

    func decodeBody<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: body)
    }
}

struct WebHTTPResponse: Sendable {
    let status: Int
    let reason: String
    let headers: [String: String]
    let body: Data

    init(
        status: Int = 200,
        reason: String = "OK",
        contentType: String = "application/json; charset=utf-8",
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.status = status
        self.reason = reason
        self.headers = headers.merging(["Content-Type": contentType]) { current, _ in current }
        self.body = body
    }

    static func json<Value: Encodable>(
        _ value: Value,
        status: Int = 200,
        reason: String = "OK",
        headers: [String: String] = [:]
    ) -> WebHTTPResponse {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return WebHTTPResponse(status: status, reason: reason, headers: headers, body: try encoder.encode(value))
        } catch {
            return .error(status: 500, message: error.localizedDescription)
        }
    }

    static func text(
        _ value: String,
        status: Int = 200,
        reason: String = "OK",
        contentType: String = "text/plain; charset=utf-8",
        headers: [String: String] = [:]
    ) -> WebHTTPResponse {
        WebHTTPResponse(
            status: status,
            reason: reason,
            contentType: contentType,
            headers: headers,
            body: Data(value.utf8)
        )
    }

    static func error(status: Int, message: String) -> WebHTTPResponse {
        struct Payload: Encodable {
            let error: String
            let message: String
        }
        let reason = switch status {
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 429: "Too Many Requests"
        default: "Internal Server Error"
        }
        return .json(Payload(error: message, message: message), status: status, reason: reason)
    }
}

enum WebRequestParseResult {
    case request(WebHTTPRequest)
    case incomplete
    case invalid(String)
}

enum WebRequestParser {
    static func parseRequest(
        _ data: Data,
        isLoopback: Bool,
        clientIdentifier: String = "loopback"
    ) -> WebHTTPRequest? {
        guard case let .request(request) = parseRequestResult(
            data,
            isLoopback: isLoopback,
            clientIdentifier: clientIdentifier
        ) else {
            return nil
        }
        return request
    }

    static func parseRequestResult(
        _ data: Data,
        isLoopback: Bool,
        clientIdentifier: String = "loopback",
        maximumRequestSize: Int = 4 * 1024 * 1024
    ) -> WebRequestParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return .incomplete
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid("无效的 HTTP 请求。") }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3 else { return .invalid("无效的 HTTP 请求。") }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLengthHeader = headers["content-length", default: "0"]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let contentLength = Int(contentLengthHeader),
              (0...maximumRequestSize).contains(contentLength) else {
            return .invalid("Content-Length 无效或超过限制。")
        }
        let bodyStart = headerRange.upperBound
        guard bodyStart <= maximumRequestSize,
              contentLength <= maximumRequestSize - bodyStart else {
            return .invalid("请求内容过大。")
        }
        guard data.count >= bodyStart + contentLength else { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))

        let target = String(requestParts[1])
        let components = URLComponents(string: target)
        let path = components?.percentEncodedPath.removingPercentEncoding ?? target
        let query = Dictionary(
            (components?.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { _, latest in latest }
        )
        return .request(WebHTTPRequest(
            method: String(requestParts[0]).uppercased(),
            path: path.isEmpty ? "/" : path,
            query: query,
            headers: headers,
            body: body,
            isLoopback: isLoopback,
            clientIdentifier: clientIdentifier
        ))
    }
}

enum WebResponseSecurity {
    static let apiCacheControl = "no-store, no-cache, must-revalidate"
    static let eventStreamCacheControl = "\(apiCacheControl), no-transform"

    static func hardenedHeaders(
        for request: WebHTTPRequest?,
        responseHeaders: [String: String]
    ) -> [String: String] {
        var headers = responseHeaders
        headers["X-Content-Type-Options"] = "nosniff"
        headers["Referrer-Policy"] = "no-referrer"
        headers["X-Frame-Options"] = "DENY"
        headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
        headers["Cross-Origin-Opener-Policy"] = "same-origin"

        if request?.path.hasPrefix("/api/") == true,
           !containsHeader("Cache-Control", in: headers) {
            headers["Cache-Control"] = apiCacheControl
            headers["Pragma"] = "no-cache"
            headers["Expires"] = "0"
        }
        return headers
    }

    static func eventStreamHeaders() -> [String: String] {
        var headers = hardenedHeaders(
            for: WebHTTPRequest(
                method: "GET",
                path: "/api/events",
                query: [:],
                headers: [:],
                body: Data(),
                isLoopback: true
            ),
            responseHeaders: [
                "Content-Type": "text/event-stream; charset=utf-8",
                "Connection": "keep-alive"
            ]
        )
        headers["Cache-Control"] = eventStreamCacheControl
        return headers
    }

    private static func containsHeader(_ name: String, in headers: [String: String]) -> Bool {
        headers.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

enum WebServerError: LocalizedError {
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidPort: "端口必须在 1–65535 之间。"
        }
    }
}

extension NSLock {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}
