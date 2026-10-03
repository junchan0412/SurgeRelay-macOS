import Foundation

@MainActor
final class WebActionTickets {
    private let maximumBytes: Int

    init(maximumBytes: Int = 64 * 1024 * 1024) { self.maximumBytes = maximumBytes }

    private var publishes: [UUID: WebPublishTicket] = [:]
    private var versions: [UUID: (Date, ModuleVersionComparison)] = [:]
    private var comparisons: [UUID: (Date, ModuleSyncComparison)] = [:]

    func store(_ ticket: WebPublishTicket) throws {
        prune()
        let bytes = ticket.files.values.flatMap { $0 }.reduce(0) { $0 + $1.data.count }
        try makeRoom(for: bytes)
        while publishes.count >= 4 {
            if let oldest = publishes.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
                publishes.removeValue(forKey: oldest)
            }
        }
        publishes[ticket.token] = ticket
    }

    func consumePublish(_ token: UUID) throws -> WebPublishTicket {
        prune()
        guard let ticket = publishes.removeValue(forKey: token) else { throw PreviewContentSaveError.changed }
        return ticket
    }

    func storeComparison(_ comparison: ModuleSyncComparison) throws -> UUID {
        try makeRoom(for: comparison.localData.count + comparison.githubData.count + diffBytes(comparison.diff))
        if comparisons.count >= 4, let oldest = comparisons.min(by: { $0.value.0 < $1.value.0 })?.key {
            comparisons.removeValue(forKey: oldest)
        }
        let token = UUID()
        comparisons[token] = (.now, comparison)
        return token
    }

    func consumeComparison(_ token: UUID, moduleID: UUID) throws -> ModuleSyncComparison {
        prune()
        guard let (_, comparison) = comparisons.removeValue(forKey: token), comparison.moduleID == moduleID else {
            throw PreviewContentSaveError.changed
        }
        return comparison
    }

    func storeVersion(_ comparison: ModuleVersionComparison) throws -> UUID {
        try makeRoom(for: diffBytes(comparison.diff))
        if versions.count >= 4, let oldest = versions.min(by: { $0.value.0 < $1.value.0 })?.key {
            versions.removeValue(forKey: oldest)
        }
        let token = UUID()
        versions[token] = (.now, comparison)
        return token
    }

    func consumeVersion(_ token: UUID, moduleID: UUID, versionID: UUID) throws -> ModuleVersionComparison {
        prune()
        guard let (_, comparison) = versions.removeValue(forKey: token), comparison.module.id == moduleID,
              comparison.version.id == versionID else { throw PreviewContentSaveError.changed }
        return comparison
    }

    func removeWebActions() { publishes = publishes.filter { $0.value.retainsForNativeUI }; comparisons.removeAll(); versions.removeAll() }

    func removeAll() { publishes.removeAll(); comparisons.removeAll(); versions.removeAll() }

    private var retainedBytes: Int {
        publishes.values.reduce(0) { total, ticket in
            total + ticket.files.values.flatMap { $0 }.reduce(0) { $0 + $1.data.count }
        } + comparisons.values.reduce(0) { $0 + $1.1.localData.count + $1.1.githubData.count + diffBytes($1.1.diff) }
          + versions.values.reduce(0) { $0 + diffBytes($1.1.diff) }
    }

    private func diffBytes(_ diff: ModuleLineDiff) -> Int {
        diff.rows.reduce(0) { $0 + $1.text.utf8.count }
    }

    private func makeRoom(for bytes: Int) throws {
        prune()
        guard bytes <= maximumBytes else {
            throw RelayError.invalidOutput("预览内容超过内存预算，请分批发布或缩小比较文件。")
        }
        while retainedBytes + bytes > maximumBytes {
            let dates = publishes.map { ($0.key, $0.value.createdAt) }
                + comparisons.map { ($0.key, $0.value.0) } + versions.map { ($0.key, $0.value.0) }
            guard let oldest = dates.min(by: { $0.1 < $1.1 })?.0 else { break }
            publishes.removeValue(forKey: oldest)
            comparisons.removeValue(forKey: oldest)
            versions.removeValue(forKey: oldest)
        }
    }

    private func prune() {
        versions = versions.filter { $0.value.0.addingTimeInterval(300) > .now }
        publishes = publishes.filter { $0.value.expiresAt > .now }
        comparisons = comparisons.filter { $0.value.0.addingTimeInterval(300) > .now }
    }
}
