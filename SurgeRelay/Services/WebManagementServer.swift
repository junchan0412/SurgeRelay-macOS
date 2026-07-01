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

    static func json<Value: Encodable>(_ value: Value, status: Int = 200, reason: String = "OK") -> WebHTTPResponse {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return WebHTTPResponse(status: status, reason: reason, body: try encoder.encode(value))
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
        default: "Internal Server Error"
        }
        return .json(Payload(error: message, message: message), status: status, reason: reason)
    }
}

enum WebRequestSecurity {
    static func rejection(for request: WebHTTPRequest, configuration: WebServerConfiguration) -> WebHTTPResponse? {
        if !configuration.allowRemoteAccess && !request.isLoopback {
            return .error(status: 403, message: "Web 管理仅允许从本机访问。")
        }
        guard request.path.hasPrefix("/api/") else { return nil }
        guard isAuthorized(request, configuration: configuration) else {
            return .error(status: 401, message: "Web 管理访问令牌无效或缺失。")
        }
        return nil
    }

    static func isAuthorized(_ request: WebHTTPRequest, configuration: WebServerConfiguration) -> Bool {
        let expected = configuration.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty, let provided = accessToken(in: request) else { return false }
        return timingSafeEqual(provided, expected)
    }

    private static func accessToken(in request: WebHTTPRequest) -> String? {
        if let value = request.query["token"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        if let value = request.headers["x-surge-relay-token"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        guard let authorization = request.headers["authorization"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !authorization.isEmpty else { return nil }
        if authorization.lowercased().hasPrefix("bearer ") {
            return String(authorization.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return authorization
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
        guard lock.withLock({ self.configuration }) != nil else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data(), isLoopback: isLoopback)
    }

    private func receive(on connection: NWConnection, accumulated: Data, isLoopback: Bool) {
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
            if let request = Self.parseRequest(buffer, isLoopback: isLoopback) {
                dispatch(request, over: connection)
            } else if complete || error != nil {
                send(.error(status: 400, message: "无效的 HTTP 请求。"), over: connection)
            } else {
                receive(on: connection, accumulated: buffer, isLoopback: isLoopback)
            }
        }
    }

    private func dispatch(_ request: WebHTTPRequest, over connection: NWConnection) {
        guard let configuration = lock.withLock({ self.configuration }) else {
            send(.error(status: 500, message: "Web 服务尚未就绪。"), over: connection)
            return
        }
        if let rejection = WebRequestSecurity.rejection(for: request, configuration: configuration) {
            send(rejection, over: connection)
            return
        }

        if request.method == "GET", request.path == "/api/events",
           let eventHandler = lock.withLock({ self.eventHandler }) {
            openEventStream(over: connection, eventHandler: eventHandler)
            return
        }
        guard let requestHandler = lock.withLock({ self.requestHandler }) else {
            send(.error(status: 500, message: "Web 服务尚未就绪。"), over: connection)
            return
        }

        Task { [weak self] in
            let response = await requestHandler(request)
            self?.send(response, over: connection)
        }
    }

    private func openEventStream(over connection: NWConnection, eventHandler: @escaping EventHandler) {
        let identifier = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            let head = """
            HTTP/1.1 200 OK\r
            Content-Type: text/event-stream; charset=utf-8\r
            Cache-Control: no-cache, no-transform\r
            Connection: keep-alive\r
            X-Content-Type-Options: nosniff\r
            \r

            """
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
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["X-Content-Type-Options"] = "nosniff"
        headers["Referrer-Policy"] = "no-referrer"
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func notify(_ state: WebServerRuntimeState) {
        lock.withLock { stateHandler }?(state)
    }

    static func parseRequest(_ data: Data, isLoopback: Bool) -> WebHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength = Int(headers["content-length", default: "0"]) ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))

        let target = String(requestParts[1])
        let components = URLComponents(string: target)
        let path = components?.percentEncodedPath.removingPercentEncoding ?? target
        let query = Dictionary(
            (components?.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { _, latest in latest }
        )
        return WebHTTPRequest(
            method: String(requestParts[0]).uppercased(),
            path: path.isEmpty ? "/" : path,
            query: query,
            headers: headers,
            body: body,
            isLoopback: isLoopback
        )
    }

    private static func isLoopback(endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        let value = String(describing: host).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
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
