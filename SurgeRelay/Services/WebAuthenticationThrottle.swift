import Foundation

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
