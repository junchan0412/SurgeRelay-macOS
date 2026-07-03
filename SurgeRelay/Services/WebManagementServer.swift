import Foundation
import Network

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

enum WebRequestSecurity {
    static let sessionCookieName = "SurgeRelayWebSession"

    static func rejection(for request: WebHTTPRequest, configuration: WebServerConfiguration) -> WebHTTPResponse? {
        if !configuration.allowRemoteAccess && !request.isLoopback {
            return .error(status: 403, message: "Web 管理仅允许从本机访问。")
        }
        guard request.path.hasPrefix("/api/") else { return nil }
        if isUnsafeMethod(request.method), !isTrustedOrigin(request) {
            return .error(status: 403, message: "Web 管理拒绝跨来源请求。")
        }
        guard isAuthorized(request, configuration: configuration) else {
            return .error(status: 401, message: "Web 管理访问令牌无效或缺失。")
        }
        return nil
    }

    static func isAuthorized(_ request: WebHTTPRequest, configuration: WebServerConfiguration) -> Bool {
        let expected = configuration.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { return false }
        if let provided = bearerAccessToken(in: request),
           timingSafeEqual(provided, expected) {
            return true
        }
        if allowsAccessTokenBootstrap(request),
           let provided = bootstrapAccessToken(in: request),
           timingSafeEqual(provided, expected) {
            return true
        }
        guard let session = sessionCookie(in: request) else { return false }
        return timingSafeEqual(session, sessionCookieValue(for: expected))
    }

    static func sessionCookieHeader(configuration: WebServerConfiguration) -> String {
        sessionCookieHeader(accessToken: configuration.accessToken)
    }

    static func sessionCookieHeader(accessToken: String) -> String {
        let value = sessionCookieValue(for: accessToken)
        return "\(sessionCookieName)=\(value); Path=/api; HttpOnly; SameSite=Strict; Max-Age=2592000"
    }

    static func sessionCookieValue(for accessToken: String) -> String {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return Data("surge-relay-web-session-v1:\(token)".utf8).sha256String
    }

    private static func allowsAccessTokenBootstrap(_ request: WebHTTPRequest) -> Bool {
        request.method == "POST" && request.path == "/api/session"
    }

    private static func isUnsafeMethod(_ method: String) -> Bool {
        ["POST", "PUT", "PATCH", "DELETE"].contains(method.uppercased())
    }

    private static func isTrustedOrigin(_ request: WebHTTPRequest) -> Bool {
        if let origin = request.headers["origin"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !origin.isEmpty {
            return isSameOrigin(origin, host: request.headers["host"])
        }
        if let referer = request.headers["referer"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !referer.isEmpty {
            return isSameOrigin(referer, host: request.headers["host"])
        }
        return bearerAccessToken(in: request) != nil
    }

    private static func isSameOrigin(_ value: String, host: String?) -> Bool {
        guard value.lowercased() != "null",
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "http",
              let sourceHost = components.host?.lowercased(),
              let expected = normalizedHostPort(from: host) else {
            return false
        }
        let sourcePort = components.port ?? 80
        let expectedPort = expected.port ?? 80
        return sourceHost == expected.host && sourcePort == expectedPort
    }

    private static func bearerAccessToken(in request: WebHTTPRequest) -> String? {
        guard let authorization = request.headers["authorization"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              authorization.lowercased().hasPrefix("bearer ") else {
            return nil
        }
        let token = String(authorization.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private static func bootstrapAccessToken(in request: WebHTTPRequest) -> String? {
        if let token = bearerAccessToken(in: request) {
            return token
        }
        if let value = request.query["token"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        if let value = request.headers["x-surge-relay-token"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return nil
    }

    private static func normalizedHostPort(from value: String?) -> (host: String, port: Int?)? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let components = URLComponents(string: "http://\(value)"),
              let host = components.host?.lowercased() else {
            return nil
        }
        return (host, components.port)
    }

    private static func sessionCookie(in request: WebHTTPRequest) -> String? {
        guard let cookie = request.headers["cookie"] else { return nil }
        let values = cookie
            .split(separator: ";")
            .compactMap { item -> (String, String)? in
                let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (
                    parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                    parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        return values.first(where: { $0.0 == sessionCookieName })?.1
    }

    private static func timingSafeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            difference |= Int((index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0))
        }
        return difference == 0
    }
}

enum WebRequestParseResult {
    case request(WebHTTPRequest)
    case incomplete
    case invalid(String)
}

final class WebAuthenticationThrottle {
    private let maxFailures: Int
    private let window: TimeInterval
    private let lock = NSLock()
    private var failuresByClient: [String: [Date]] = [:]

    init(maxFailures: Int = 8, window: TimeInterval = 60) {
        self.maxFailures = maxFailures
        self.window = window
    }

    func rejection(for request: WebHTTPRequest, now: Date = .now) -> WebHTTPResponse? {
        guard request.path.hasPrefix("/api/") else { return nil }
        let isLimited = lock.withLock {
            pruneFailures(for: request.clientIdentifier, now: now).count >= maxFailures
        }
        return isLimited
            ? .error(status: 429, message: "Web 管理认证失败次数过多，请稍后再试。")
            : nil
    }

    func recordFailure(for request: WebHTTPRequest, now: Date = .now) {
        guard request.path.hasPrefix("/api/") else { return }
        lock.withLock {
            var values = pruneFailures(for: request.clientIdentifier, now: now)
            values.append(now)
            failuresByClient[request.clientIdentifier] = values
        }
    }

    func recordSuccess(for request: WebHTTPRequest) {
        guard request.path.hasPrefix("/api/") else { return }
        lock.withLock {
            _ = failuresByClient.removeValue(forKey: request.clientIdentifier)
        }
    }

    private func pruneFailures(for clientIdentifier: String, now: Date) -> [Date] {
        let cutoff = now.addingTimeInterval(-window)
        let values = failuresByClient[clientIdentifier, default: []].filter { $0 >= cutoff }
        failuresByClient[clientIdentifier] = values
        return values
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

final class WebManagementServer: @unchecked Sendable {
    typealias RequestHandler = @Sendable (WebHTTPRequest) async -> WebHTTPResponse
    typealias EventHandler = @Sendable () async -> String
    typealias StateHandler = @Sendable (WebServerRuntimeState) -> Void

    private let queue = DispatchQueue(label: "com.allenmiao.SurgeRelay.web-server", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var configuration: WebServerConfiguration?
    private var requestHandler: RequestHandler?
    private var eventHandler: EventHandler?
    private var stateHandler: StateHandler?
    private var eventTasks: [UUID: Task<Void, Never>] = [:]
    private let authenticationThrottle = WebAuthenticationThrottle()
    private let maximumRequestSize = 4 * 1024 * 1024

    func start(
        configuration: WebServerConfiguration,
        stateHandler: @escaping StateHandler,
        eventHandler: @escaping EventHandler,
        requestHandler: @escaping RequestHandler
    ) throws {
        stop()
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw WebServerError.invalidPort
        }

        let listener = try NWListener(using: .tcp, on: port)
        listener.service = NWListener.Service(name: "Surge Relay", type: "_http._tcp")
        lock.withLock {
            self.configuration = configuration
            self.requestHandler = requestHandler
            self.eventHandler = eventHandler
            self.stateHandler = stateHandler
            self.listener = listener
        }

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .setup, .waiting:
                self.notify(.starting)
            case .ready:
                self.notify(.running)
            case let .failed(error):
                self.notify(.failed(error.localizedDescription))
                listener.cancel()
            case .cancelled:
                self.notify(.stopped)
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        notify(.starting)
        listener.start(queue: queue)
    }

    func stop() {
        let (listener, tasks) = lock.withLock { () -> (NWListener?, [Task<Void, Never>]) in
            defer {
                self.listener = nil
                self.configuration = nil
                self.requestHandler = nil
                self.eventHandler = nil
                self.stateHandler = nil
                self.eventTasks.removeAll()
            }
            return (self.listener, Array(self.eventTasks.values))
        }
        tasks.forEach { $0.cancel() }
        listener?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        let isLoopback = Self.isLoopback(endpoint: connection.endpoint)
        let clientIdentifier = Self.clientIdentifier(endpoint: connection.endpoint)
        guard lock.withLock({ self.configuration }) != nil else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data(), isLoopback: isLoopback, clientIdentifier: clientIdentifier)
    }

    private func receive(
        on connection: NWConnection,
        accumulated: Data,
        isLoopback: Bool,
        clientIdentifier: String
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard buffer.count <= maximumRequestSize else {
                send(.error(status: 400, message: "请求内容过大。"), over: connection)
                return
            }
            switch Self.parseRequestResult(
                buffer,
                isLoopback: isLoopback,
                clientIdentifier: clientIdentifier
            ) {
            case let .request(request):
                dispatch(request, over: connection)
            case .incomplete where complete || error != nil:
                send(.error(status: 400, message: "无效的 HTTP 请求。"), over: connection)
            case .incomplete:
                receive(
                    on: connection,
                    accumulated: buffer,
                    isLoopback: isLoopback,
                    clientIdentifier: clientIdentifier
                )
            case let .invalid(message):
                send(.error(status: 400, message: message), over: connection)
            }
        }
    }

    private func dispatch(_ request: WebHTTPRequest, over connection: NWConnection) {
        guard let configuration = lock.withLock({ self.configuration }) else {
            send(.error(status: 500, message: "Web 服务尚未就绪。"), for: request, over: connection)
            return
        }
        if let throttled = authenticationThrottle.rejection(for: request) {
            send(throttled, for: request, over: connection)
            return
        }
        if let rejection = WebRequestSecurity.rejection(for: request, configuration: configuration) {
            if rejection.status == 401 {
                authenticationThrottle.recordFailure(for: request)
            }
            send(rejection, for: request, over: connection)
            return
        }
        authenticationThrottle.recordSuccess(for: request)

        if request.method == "GET", request.path == "/api/events",
           let eventHandler = lock.withLock({ self.eventHandler }) {
            openEventStream(over: connection, eventHandler: eventHandler)
            return
        }
        guard let requestHandler = lock.withLock({ self.requestHandler }) else {
            send(.error(status: 500, message: "Web 服务尚未就绪。"), for: request, over: connection)
            return
        }

        Task { [weak self] in
            let response = await requestHandler(request)
            self?.send(response, for: request, over: connection)
        }
    }

    private func openEventStream(over connection: NWConnection, eventHandler: @escaping EventHandler) {
        let identifier = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            let head = Self.responseHead(
                status: 200,
                reason: "OK",
                headers: WebResponseSecurity.eventStreamHeaders()
            )
            do {
                try await sendStreamData(Data(head.utf8), over: connection)
                var previous = ""
                var heartbeat = 0
                while !Task.isCancelled {
                    let payload = await eventHandler()
                    if payload != previous {
                        let line = payload.replacingOccurrences(of: "\n", with: "")
                        try await sendStreamData(Data("event: state\ndata: \(line)\n\n".utf8), over: connection)
                        previous = payload
                        heartbeat = 0
                    } else {
                        heartbeat += 1
                        if heartbeat >= 15 {
                            try await sendStreamData(Data(": keep-alive\n\n".utf8), over: connection)
                            heartbeat = 0
                        }
                    }
                    try await Task.sleep(for: .seconds(1))
                }
            } catch {
                // Closing a browser tab or changing networks naturally ends the stream.
            }
            connection.cancel()
            _ = self.lock.withLock { self.eventTasks.removeValue(forKey: identifier) }
        }
        lock.withLock { self.eventTasks[identifier] = task }
    }

    private func sendStreamData(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func send(_ response: WebHTTPResponse, over connection: NWConnection) {
        send(response, for: nil, over: connection)
    }

    private func send(_ response: WebHTTPResponse, for request: WebHTTPRequest?, over connection: NWConnection) {
        var headers = WebResponseSecurity.hardenedHeaders(for: request, responseHeaders: response.headers)
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        let head = Self.responseHead(status: response.status, reason: response.reason, headers: headers)
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func responseHead(status: Int, reason: String, headers: [String: String]) -> String {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return head
    }

    private func notify(_ state: WebServerRuntimeState) {
        lock.withLock { stateHandler }?(state)
    }

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

    private static func clientIdentifier(endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "unknown" }
        return String(describing: host).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func isLoopback(endpoint: NWEndpoint) -> Bool {
        let value = clientIdentifier(endpoint: endpoint)
        return value == "127.0.0.1" || value == "::1" || value == "localhost"
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

private extension NSLock {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}
