import Foundation

enum ModuleVersionReason: String, Codable, Sendable {
    case current, beforeUpdate, beforeEdit, manualEdit, beforeRestore, restored

    var title: String {
        switch self {
        case .current: "当前缓存"
        case .beforeUpdate: "更新前"
        case .beforeEdit: "编辑前"
        case .manualEdit: "已保存编辑"
        case .beforeRestore: "恢复前"
        case .restored: "已恢复版本"
        }
    }
}

struct ModuleVersionAsset: Codable, Equatable, Sendable {
    var path: String
    var contentHash: String
    var byteCount: Int
}

struct ModuleVersionRecord: Identifiable, Codable, Equatable, Sendable {
    static let missingFingerprint = "missing"
    var id: UUID
    var moduleID: UUID
    var createdAt: Date
    var reason: ModuleVersionReason
    var contentHash: String
    var convertedContentHash: String?
    var hasOverride: Bool
    var assets: [ModuleVersionAsset]
    var fingerprint: String
    var byteCount: Int
}

struct ModuleVersionContent: Sendable {
    var record: ModuleVersionRecord
    var content: String
    var convertedContent: String?
    var assets: [GeneratedAsset]
}

struct ModuleVersionComparison: Sendable {
    var module: RelayModule
    var version: ModuleVersionRecord
    var expectedFingerprint: String
    var diff: ModuleLineDiff
    var changedAssets: [String]
    var currentContentProblem: String? = nil
}

struct ModuleVersionCurrentState: Sendable {
    var content: ModuleVersionContent?
    var fingerprint: String
    var assets: [ModuleVersionAsset]
    var problem: String?
}

enum ModuleRestorePhase: String, CaseIterable, Sendable {
    case prepared, overrideInstalled, snapshotInstalled, metadataPending, committed, finalized
    case recoverySnapshotInstalled, recoveryOverrideInstalled
}
