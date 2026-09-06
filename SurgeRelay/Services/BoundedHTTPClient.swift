import Foundation

final class BoundedHTTPClient: Sendable {
    private let session: URLSession
    private let delegate: ResponseDelegate

    init(maximumResponseSize: Int = 20 * 1024 * 1024, configuration: URLSessionConfiguration = .ephemeral,
         validateRequest: @escaping @Sendable (URLRequest) throws -> Void = { _ in }) {
        delegate = ResponseDelegate(maximumSize: maximumResponseSize, validateRequest: validateRequest)
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try delegate.validateRequest(request)
        let cancellation = RequestCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                delegate.register(task, continuation: continuation)
                cancellation.start(task)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class RequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    func start(_ task: URLSessionTask) {
        let cancelled = lock.withLock {
            self.task = task
            return isCancelled
        }
        if cancelled { task.cancel() }
        else { task.resume() }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }
}

private final class ResponseDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct ResponseState {
        var data = Data()
        var response: URLResponse?
        let continuation: CheckedContinuation<(Data, URLResponse), any Error>
    }

    private let maximumSize: Int
    let validateRequest: @Sendable (URLRequest) throws -> Void
    private let lock = NSLock()
    private var responses: [Int: ResponseState] = [:]

    init(maximumSize: Int, validateRequest: @escaping @Sendable (URLRequest) throws -> Void) {
        self.maximumSize = maximumSize
        self.validateRequest = validateRequest
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        do { try validateRequest(request); completionHandler(request) }
        catch { finish(task, error: error); completionHandler(nil); task.cancel() }
    }

    func register(_ task: URLSessionTask, continuation: CheckedContinuation<(Data, URLResponse), any Error>) {
        lock.withLock { responses[task.taskIdentifier] = ResponseState(continuation: continuation) }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard response.expectedContentLength <= maximumSize else {
            finish(dataTask, error: BoundedRemoteFetchError.responseTooLarge(maximumSize: maximumSize))
            completionHandler(.cancel)
            return
        }
        lock.withLock { responses[dataTask.taskIdentifier]?.response = response }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceedsLimit = lock.withLock {
            guard let count = responses[dataTask.taskIdentifier]?.data.count else { return false }
            guard data.count <= maximumSize - count else { return true }
            responses[dataTask.taskIdentifier]?.data.append(data)
            return false
        }
        if exceedsLimit {
            finish(dataTask, error: BoundedRemoteFetchError.responseTooLarge(maximumSize: maximumSize))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(task, error: error)
    }

    private func finish(_ task: URLSessionTask, error: (any Error)?) {
        guard let state = lock.withLock({ responses.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error {
            state.continuation.resume(throwing: error)
        } else if let response = state.response {
            state.continuation.resume(returning: (state.data, response))
        } else {
            state.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}
