import Foundation

enum ModuleSyncResolution: Equatable, Sendable {
    case localWins
    case githubWins
}

enum ModuleSyncPlanner {
    static func isCurrent(_ reviewed: ModuleSyncComparison, comparedTo current: ModuleSyncComparison) -> Bool {
        reviewed.moduleID == current.moduleID && reviewed.scope == current.scope &&
            reviewed.localFileHash == current.localFileHash && reviewed.metadata.githubHash == current.metadata.githubHash &&
            reviewed.githubCommitSHA == current.githubCommitSHA
    }

    static func state(localHash: String, githubHash: String, baseHash: String?) -> ModuleSyncState {
        if localHash == githubHash { return .same }
        guard let baseHash else { return .unbasedDifference }
        if githubHash == baseHash { return .localAhead }
        if localHash == baseHash { return .githubAhead }
        return .bothChanged
    }

    static func normalizedPublishedData(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return Data(lines.filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line != "# Surge Relay managed output" && !line.hasPrefix("# surge-relay-relative-path:")
        }.joined(separator: "\n").utf8)
    }

    static func conflict(
        localData: Data?,
        localUpdatedAt: Date?,
        github: GitHubClient.FileSnapshot?,
        baseHash: String? = nil,
        now: Date = .now
    ) -> ModuleSyncConflictMetadata? {
        guard let localData, let localUpdatedAt, let github else { return nil }
        let localHash = normalizedPublishedData(localData).sha256String
        let githubHash = normalizedPublishedData(github.data).sha256String
        guard localHash != githubHash else { return nil }
        return ModuleSyncConflictMetadata(
            localHash: localHash,
            githubHash: githubHash,
            localUpdatedAt: localUpdatedAt,
            githubUpdatedAt: github.updatedAt,
            detectedAt: now,
            baseHash: baseHash,
            githubCommitSHA: github.commitSHA
        )
    }
}

enum ModuleSyncState: String, Sendable {
    case same, localAhead, githubAhead, bothChanged, unbasedDifference

    var title: String {
        switch self {
        case .same: "两端内容一致"
        case .localAhead: "本地领先"
        case .githubAhead: "GitHub 领先"
        case .bothChanged: "两端均已修改"
        case .unbasedDifference: "两端不同，尚无共同基线"
        }
    }
}

struct ModuleSyncComparison: Identifiable, Sendable {
    var id: UUID { moduleID }
    var moduleID: UUID
    var scope: String
    var localData: Data
    var githubData: Data
    var localFileHash: String
    var githubCommitSHA: String
    var metadata: ModuleSyncConflictMetadata
    var diff: ModuleLineDiff
}

struct ModuleLineDiff: Encodable, Sendable {
    struct Row: Encodable, Sendable {
        enum Kind: String, Encodable, Equatable, Sendable { case context, removed, added }
        var kind: Kind
        var text: String
        var localLine: Int?
        var githubLine: Int?
    }
    var rows: [Row]
    var removedCount: Int
    var addedCount: Int
    var isTruncated: Bool
    var usesCoarseComparison: Bool
    var hasFinalNewlineDifference = false
}

enum ModuleLineDiffPlanner {
    static let maximumDisplayedRows = 2_000
    static let maximumComparisonCells = 250_000

    static func compare(local: String, github: String) -> ModuleLineDiff {
        func lines(_ text: String) -> [String] {
            guard !text.isEmpty else { return [] }
            var result = text.components(separatedBy: "\n")
            if text.hasSuffix("\n") { result.removeLast() }
            return result
        }
        let left = lines(local)
        let right = lines(github)
        func equal(_ i: Int, _ j: Int) -> Bool { left[i].utf16.elementsEqual(right[j].utf16) }
        var prefix = 0
        while prefix < min(left.count, right.count), equal(prefix, prefix) { prefix += 1 }
        var suffix = 0
        while suffix < min(left.count, right.count) - prefix,
              equal(left.count - suffix - 1, right.count - suffix - 1) { suffix += 1 }
        let leftCount = left.count - prefix - suffix
        let rightCount = right.count - prefix - suffix
        var result = ModuleLineDiff(rows: [], removedCount: 0, addedCount: 0, isTruncated: false, usesCoarseComparison: false)
        result.hasFinalNewlineDifference = local.hasSuffix("\n") != github.hasSuffix("\n")
        func append(_ kind: ModuleLineDiff.Row.Kind, _ i: Int?, _ j: Int?) {
            if kind == .removed { result.removedCount += 1 }
            if kind == .added { result.addedCount += 1 }
            guard result.rows.count < maximumDisplayedRows else { result.isTruncated = true; return }
            result.rows.append(.init(kind: kind, text: i.map { left[$0] } ?? right[j!], localLine: i.map { $0 + 1 }, githubLine: j.map { $0 + 1 }))
        }
        for index in max(0, prefix - 3)..<prefix { append(.context, index, index) }
        if leftCount > 0, rightCount > 0,
           leftCount <= maximumComparisonCells / rightCount {
            let columns = rightCount + 1
            var lengths = [Int32](repeating: 0, count: (leftCount + 1) * columns)
            for i in stride(from: leftCount - 1, through: 0, by: -1) {
                for j in stride(from: rightCount - 1, through: 0, by: -1) {
                    lengths[i * columns + j] = equal(prefix + i, prefix + j)
                        ? lengths[(i + 1) * columns + j + 1] + 1
                        : max(lengths[(i + 1) * columns + j], lengths[i * columns + j + 1])
                }
            }
            var i = 0
            var j = 0
            while i < leftCount || j < rightCount {
                if i < leftCount, j < rightCount, equal(prefix + i, prefix + j) {
                    append(.context, prefix + i, prefix + j); i += 1; j += 1
                } else if i < leftCount, j == rightCount || lengths[(i + 1) * columns + j] >= lengths[i * columns + j + 1] {
                    append(.removed, prefix + i, nil); i += 1
                } else {
                    append(.added, nil, prefix + j); j += 1
                }
            }
        } else {
            result.usesCoarseComparison = leftCount > 0 && rightCount > 0
            for i in 0..<leftCount { append(.removed, prefix + i, nil) }
            for j in 0..<rightCount { append(.added, nil, prefix + j) }
        }
        for index in 0..<min(3, suffix) {
            append(.context, left.count - suffix + index, right.count - suffix + index)
        }
        return result
    }
}
