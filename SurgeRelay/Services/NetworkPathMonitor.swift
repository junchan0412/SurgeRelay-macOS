import Foundation
import Network

/// Observes path changes and fires when connectivity becomes reachable again.
/// Used only for local Web server recovery and deferred GitHub publish retry.
final class NetworkPathMonitor: @unchecked Sendable {
    var onBecameReachable: (@Sendable () -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.allenmiao.SurgeRelay.network-monitor", qos: .utility)
    private var lastStatus: NWPath.Status?
    private var lastReachableFire = Date.distantPast
    private let debounceInterval: TimeInterval = 3
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let becameReachable = path.status == .satisfied && self.lastStatus != .satisfied
            self.lastStatus = path.status
            guard becameReachable else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastReachableFire) >= self.debounceInterval else { return }
            self.lastReachableFire = now
            self.onBecameReachable?()
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        guard started else { return }
        started = false
        monitor.cancel()
        lastStatus = nil
    }
}
