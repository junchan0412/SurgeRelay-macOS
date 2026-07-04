import Foundation
import Network

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
        WebRequestParser.parseRequest(
            data,
            isLoopback: isLoopback,
            clientIdentifier: clientIdentifier
        )
    }

    static func parseRequestResult(
        _ data: Data,
        isLoopback: Bool,
        clientIdentifier: String = "loopback",
        maximumRequestSize: Int = 4 * 1024 * 1024
    ) -> WebRequestParseResult {
        WebRequestParser.parseRequestResult(
            data,
            isLoopback: isLoopback,
            clientIdentifier: clientIdentifier,
            maximumRequestSize: maximumRequestSize
        )
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
