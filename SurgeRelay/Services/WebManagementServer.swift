import Foundation
import Network

final class WebManagementServer: @unchecked Sendable {
    typealias RequestHandler = @Sendable (WebHTTPRequest) async -> WebHTTPResponse
    typealias EventHandler = @Sendable () async -> String
    typealias EventProvider = @Sendable (Bool) async throws -> WebEventPayload
    typealias StateHandler = @Sendable (WebServerRuntimeState) -> Void

    private struct Client {
        let connection: NWConnection
        var readDeadline: DispatchWorkItem?
        var requestTask: Task<Void, Never>?
        var isEventStream = false
        var isSending = false
        var supportsActivity = false
        var sentStateRevision: UInt64?
        var sentActivityRevision: UInt64?
        var lastWasState = false
        var lastEventSentAt = ContinuousClock.now
    }

    private let queue = DispatchQueue(label: "com.allenmiao.SurgeRelay.web-server", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var generation = UUID()
    private var configuration: WebServerConfiguration?
    private var requestHandler: RequestHandler?
    private var eventProvider: EventProvider?
    private var stateHandler: StateHandler?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var eventTask: Task<Void, Never>?
    private var eventProducerID: UUID?
    private struct Frame {
        let message: WebEventMessage
        let token: UInt64
        let data: Data
    }
    private var eventRevision: UInt64 = 0
    private var stateFrame: Frame?
    private var activityFrame: Frame?
    private var legacyFrame: Frame?
    private let authenticationThrottle = WebAuthenticationThrottle()
    private final class RequestBuffer: @unchecked Sendable {
        var data = Data()
        var head: WebRequestHead?
    }
    private let maximumConnections: Int
    private let maximumEventStreams: Int
    private let requestReadTimeout: TimeInterval
    private let eventInterval: Duration

    init(maximumConnections: Int = 32, maximumEventStreams: Int = 8,
         requestReadTimeout: TimeInterval = 15, eventInterval: Duration = .seconds(1)) {
        self.maximumConnections = max(1, maximumConnections)
        self.maximumEventStreams = max(1, maximumEventStreams)
        self.requestReadTimeout = requestReadTimeout
        self.eventInterval = eventInterval
    }

    var listeningPort: UInt16? {
        lock.withLock {
            guard let port = listener?.port?.rawValue, port != 0 else { return nil }
            return port
        }
    }

    func start(
        configuration: WebServerConfiguration,
        stateHandler: @escaping StateHandler,
        eventHandler: @escaping EventHandler,
        requestHandler: @escaping RequestHandler
    ) throws {
        try start(configuration: configuration, stateHandler: stateHandler, eventProvider: { _ in
            let data = Data((await eventHandler()).replacingOccurrences(of: "\n", with: "").utf8)
            let message = WebEventMessage(data: data, revision: nil)
            return WebEventPayload(state: message, activity: nil, legacyState: message)
        }, requestHandler: requestHandler)
    }

    func start(
        configuration: WebServerConfiguration,
        stateHandler: @escaping StateHandler,
        eventProvider: @escaping EventProvider,
        requestHandler: @escaping RequestHandler
    ) throws {
        stop()
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw WebServerError.invalidPort
        }
        let listener = try NWListener(using: .tcp, on: port)
        listener.service = NWListener.Service(name: "Surge Relay", type: "_http._tcp")
        let generation = UUID()
        lock.withLock {
            self.generation = generation
            self.configuration = configuration
            self.requestHandler = requestHandler
            self.eventProvider = eventProvider
            self.stateHandler = stateHandler
            self.listener = listener
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .setup, .waiting:
                self.notify(.starting, generation: generation)
            case .ready:
                self.notify(.running, generation: generation)
            case let .failed(error):
                self.notify(.failed(error.localizedDescription), generation: generation)
                listener.cancel()
            case .cancelled:
                self.notify(.stopped, generation: generation)
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, generation: generation)
        }
        notify(.starting, generation: generation)
        listener.start(queue: queue)
    }

    func stop() {
        let resources = lock.withLock { () -> (NWListener?, [Client], Task<Void, Never>?, StateHandler?) in
            let resources = (listener, Array(clients.values), eventTask, stateHandler)
            generation = UUID()
            listener = nil
            configuration = nil
            requestHandler = nil
            eventProvider = nil
            stateHandler = nil
            clients.removeAll()
            eventTask = nil
            eventProducerID = nil
            stateFrame = nil
            activityFrame = nil
            legacyFrame = nil
            eventRevision = 0
            return resources
        }
        resources.2?.cancel()
        for client in resources.1 {
            client.readDeadline?.cancel()
            client.requestTask?.cancel()
            client.connection.cancel()
        }
        resources.0?.cancel()
        resources.3?(.stopped)
    }

    private func accept(_ connection: NWConnection, generation: UUID) {
        let identifier = ObjectIdentifier(connection)
        let deadline = DispatchWorkItem { [weak self, weak connection] in
            guard let connection else { return }
            self?.close(connection)
        }
        let accepted = lock.withLock {
            guard self.generation == generation, configuration != nil,
                  clients.count < maximumConnections else { return false }
            clients[identifier] = Client(connection: connection, readDeadline: deadline)
            return true
        }
        guard accepted else { connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .failed, .cancelled: self?.close(connection)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + requestReadTimeout, execute: deadline)
        receive(on: connection, pending: RequestBuffer(), isLoopback: Self.isLoopback(endpoint: connection.endpoint),
                clientIdentifier: Self.clientIdentifier(endpoint: connection.endpoint))
    }

    private func close(_ connection: NWConnection) {
        let (client, producer) = lock.withLock { () -> (Client?, Task<Void, Never>?) in
            let client = clients.removeValue(forKey: ObjectIdentifier(connection))
            guard client?.isEventStream == true, !clients.values.contains(where: \.isEventStream) else {
                return (client, nil)
            }
            let producer = eventTask
            eventTask = nil
            eventProducerID = nil
            stateFrame = nil
            activityFrame = nil
            legacyFrame = nil
            return (client, producer)
        }
        client?.readDeadline?.cancel()
        client?.requestTask?.cancel()
        producer?.cancel()
        connection.cancel()
    }

    private func receive(on connection: NWConnection, pending: RequestBuffer, isLoopback: Bool, clientIdentifier: String) {
        let maximumLength = pending.head.map { min(64 * 1024, max(1, $0.contentLength - pending.data.count)) }
            ?? min(8 * 1024, max(1, WebRequestParser.maximumHeaderSize - pending.data.count))
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { [weak self] data, _, complete, error in
            guard let self, lock.withLock({ clients[ObjectIdentifier(connection)] != nil }) else {
                connection.cancel()
                return
            }
            if let data { pending.data.append(data) }
            if pending.head == nil {
                switch WebRequestParser.parseHead(pending.data, isLoopback: isLoopback, clientIdentifier: clientIdentifier) {
                case .incomplete:
                    if complete || error != nil { send(.error(status: 400, message: "无效的 HTTP 请求。"), over: connection) }
                    else { receive(on: connection, pending: pending, isLoopback: isLoopback, clientIdentifier: clientIdentifier) }
                    return
                case let .invalid(message):
                    send(.error(status: 400, message: message), over: connection)
                    return
                case let .head(head):
                    guard let configuration = lock.withLock({ self.configuration }) else { close(connection); return }
                    if let throttled = authenticationThrottle.rejection(for: head.request) {
                        send(throttled, for: head.request, over: connection)
                        return
                    }
                    if let rejection = WebRequestSecurity.rejection(for: head.request, configuration: configuration) {
                        if rejection.status == 401 { authenticationThrottle.recordFailure(for: head.request) }
                        send(rejection, for: head.request, over: connection)
                        return
                    }
                    pending.head = head
                    pending.data = Data(pending.data.dropFirst(head.bodyOffset))
                }
            }
            guard let head = pending.head else { return }
            if pending.data.count >= head.contentLength {
                dispatch(head.completed(body: Data(pending.data.prefix(head.contentLength))), over: connection)
            } else if complete || error != nil {
                send(.error(status: 400, message: "无效的 HTTP 请求。"), over: connection)
            } else {
                receive(on: connection, pending: pending, isLoopback: isLoopback, clientIdentifier: clientIdentifier)
            }
        }
    }

    private func dispatch(_ request: WebHTTPRequest, over connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        guard let configuration = lock.withLock({ () -> WebServerConfiguration? in
            guard clients[identifier] != nil else { return nil }
            clients[identifier]?.readDeadline?.cancel()
            clients[identifier]?.readDeadline = nil
            return self.configuration
        }) else { close(connection); return }
        if let throttled = authenticationThrottle.rejection(for: request) {
            send(throttled, for: request, over: connection)
            return
        }
        if let rejection = WebRequestSecurity.rejection(for: request, configuration: configuration) {
            if rejection.status == 401 { authenticationThrottle.recordFailure(for: request) }
            send(rejection, for: request, over: connection)
            return
        }
        authenticationThrottle.recordSuccess(for: request)
        if request.method == "GET", request.path == "/api/events" {
            openEventStream(over: connection, supportsActivity: request.query["activity"] == "1")
            return
        }
        lock.withLock {
            guard clients[identifier] != nil, let requestHandler else { return }
            clients[identifier]?.requestTask = Task { [weak self] in
                guard !Task.isCancelled else { return }
                let response = await requestHandler(request)
                guard !Task.isCancelled else { return }
                self?.send(response, for: request, over: connection)
            }
        }
    }

    private func openEventStream(over connection: NWConnection, supportsActivity: Bool) {
        let identifier = ObjectIdentifier(connection)
        let accepted = lock.withLock {
            guard clients[identifier] != nil, let eventProvider,
                  clients.values.filter(\.isEventStream).count < maximumEventStreams else { return false }
            clients[identifier]?.isEventStream = true
            clients[identifier]?.supportsActivity = supportsActivity
            clients[identifier]?.isSending = true
            if eventTask == nil {
                let producerID = UUID()
                eventProducerID = producerID
                let interval = eventInterval
                eventTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do {
                            guard let includesLegacy = self?.legacyRequired(producerID: producerID) else { return }
                            let payload = try await eventProvider(includesLegacy)
                            try Task.checkCancellation()
                            self?.broadcast(payload, producerID: producerID)
                            try await Task.sleep(for: interval)
                        } catch {
                            self?.endProducer(producerID: producerID)
                            return
                        }
                    }
                }
            }
            return true
        }
        guard accepted else {
            send(.error(status: 503, message: "Web 实时连接已达上限，请关闭其他管理页面后重试。"), over: connection)
            return
        }
        let head = Self.responseHead(status: 200, reason: "OK", headers: WebResponseSecurity.eventStreamHeaders())
        sendEventData(Data(head.utf8), over: connection)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
            self?.close(connection)
        }
    }

    private func legacyRequired(producerID: UUID) -> Bool? {
        lock.withLock {
            guard eventProducerID == producerID else { return nil }
            return clients.values.contains { $0.isEventStream && !$0.supportsActivity }
        }
    }

    private func endProducer(producerID: UUID) {
        let connections = lock.withLock { () -> [NWConnection] in
            guard eventProducerID == producerID else { return [] }
            eventTask = nil
            eventProducerID = nil
            return clients.values.filter(\.isEventStream).map(\.connection)
        }
        for connection in connections { close(connection) }
    }

    private func updatedFrame(_ message: WebEventMessage, previous: Frame?, event: String) -> Frame {
        if let previous {
            if let revision = message.revision, let oldRevision = previous.message.revision {
                if revision <= oldRevision { return previous }
            } else if message.data == previous.message.data { return previous }
        }
        eventRevision &+= 1
        var data = Data("event: \(event)\ndata: ".utf8)
        data.append(message.data)
        data.append(Data("\n\n".utf8))
        return Frame(message: message, token: eventRevision, data: data)
    }

    private func broadcast(_ payload: WebEventPayload, producerID: UUID) {
        let deliveries = lock.withLock { () -> [(NWConnection, Data)] in
            guard eventProducerID == producerID else { return [] }
            stateFrame = updatedFrame(payload.state, previous: stateFrame, event: "state")
            if let activity = payload.activity {
                activityFrame = updatedFrame(activity, previous: activityFrame, event: "activity")
            }
            if let legacy = payload.legacyState {
                if let revision = legacy.revision, revision == stateFrame?.message.revision {
                    legacyFrame = stateFrame
                } else {
                    legacyFrame = updatedFrame(legacy, previous: legacyFrame, event: "state")
                }
            } else { legacyFrame = nil }
            return Array(clients.keys).compactMap { nextDelivery(for: $0) }
        }
        for (connection, data) in deliveries { sendEventData(data, over: connection) }
    }

    private func nextDelivery(for identifier: ObjectIdentifier) -> (NWConnection, Data)? {
        guard var client = clients[identifier], client.isEventStream, !client.isSending else { return nil }
        let state = client.supportsActivity ? stateFrame : legacyFrame
        let activity = client.supportsActivity ? activityFrame : nil
        let pendingState = state != nil && client.sentStateRevision != state?.token
        let pendingActivity = activity != nil && client.sentActivityRevision != activity?.token
        var data: Data
        if pendingState && (client.sentStateRevision == nil || !pendingActivity || !client.lastWasState) {
            data = state!.data
            client.sentStateRevision = state!.token
            client.lastWasState = true
        } else if pendingActivity, client.sentStateRevision != nil {
            data = activity!.data
            client.sentActivityRevision = activity!.token
            client.lastWasState = false
        } else if client.lastEventSentAt.duration(to: .now) >= .seconds(15) {
            data = Data(": keep-alive\n\n".utf8)
        } else { return nil }
        client.isSending = true
        client.lastEventSentAt = .now
        clients[identifier] = client
        return (client.connection, data)
    }

    private func sendEventData(_ data: Data, over connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { close(connection) }
            else {
                let delivery = lock.withLock { () -> (NWConnection, Data)? in
                    let identifier = ObjectIdentifier(connection)
                    clients[identifier]?.isSending = false
                    return nextDelivery(for: identifier)
                }
                if let (connection, data) = delivery { sendEventData(data, over: connection) }
            }
        })
    }

    private func send(_ response: WebHTTPResponse, over connection: NWConnection) {
        send(response, for: nil, over: connection)
    }

    private func send(_ response: WebHTTPResponse, for request: WebHTTPRequest?, over connection: NWConnection) {
        guard lock.withLock({ clients[ObjectIdentifier(connection)] != nil }) else { return }
        var headers = WebResponseSecurity.hardenedHeaders(for: request, responseHeaders: response.headers)
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        let head = Self.responseHead(status: response.status, reason: response.reason, headers: headers)
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in self?.close(connection) })
    }

    private static func responseHead(status: Int, reason: String, headers: [String: String]) -> String {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        return head + "\r\n"
    }

    private func notify(_ state: WebServerRuntimeState, generation: UUID) {
        lock.withLock { self.generation == generation ? stateHandler : nil }?(state)
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
