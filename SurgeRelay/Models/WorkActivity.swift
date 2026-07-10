import Foundation

enum WorkActivityKind: String, Codable, Equatable, Sendable {
    case idle
    case updatingModules
    case scanningLocalModules
    case importingLocalModules
    case refreshingScriptHub
    case testingGitHub
    case publishing
    case automaticPublishing
    case previewingPublish
    case confirmingPublish
    case savingPreview
    case restoringPreview
    case checkingKeychain

    var title: String {
        switch self {
        case .idle: "空闲"
        case .updatingModules: "模块更新"
        case .scanningLocalModules: "本地模块扫描"
        case .importingLocalModules: "本地模块导入"
        case .refreshingScriptHub: "Script-Hub 引擎更新"
        case .testingGitHub: "GitHub 连接测试"
        case .publishing: "GitHub 发布"
        case .automaticPublishing: "GitHub 自动发布"
        case .previewingPublish: "发布预览"
        case .confirmingPublish: "确认发布"
        case .savingPreview: "预览内容写入"
        case .restoringPreview: "预览内容恢复"
        case .checkingKeychain: "钥匙串检查"
        }
    }

    var blocksUpdatesByDefault: Bool {
        switch self {
        case .idle, .checkingKeychain:
            false
        case .updatingModules, .scanningLocalModules, .importingLocalModules, .refreshingScriptHub,
             .testingGitHub, .publishing, .automaticPublishing, .previewingPublish, .confirmingPublish,
             .savingPreview, .restoringPreview:
            true
        }
    }

    var canCancelByDefault: Bool {
        switch self {
        case .updatingModules, .scanningLocalModules, .importingLocalModules, .refreshingScriptHub,
             .testingGitHub, .publishing, .automaticPublishing, .previewingPublish, .confirmingPublish:
            true
        case .idle, .savingPreview, .restoringPreview, .checkingKeychain:
            false
        }
    }
}

struct WorkActivity: Codable, Equatable, Sendable {
    var kind: WorkActivityKind
    var title: String
    var startedAt: Date?
    var blocksUpdates: Bool
    var canCancel: Bool

    var isActive: Bool {
        kind != .idle
    }

    static let idle = WorkActivity(
        kind: .idle,
        title: WorkActivityKind.idle.title,
        startedAt: nil,
        blocksUpdates: false,
        canCancel: false
    )

    init(
        kind: WorkActivityKind,
        title: String? = nil,
        startedAt: Date? = .now,
        blocksUpdates: Bool? = nil,
        canCancel: Bool? = nil
    ) {
        self.kind = kind
        self.title = title ?? kind.title
        self.startedAt = kind == .idle ? nil : startedAt
        self.blocksUpdates = blocksUpdates ?? kind.blocksUpdatesByDefault
        self.canCancel = canCancel ?? kind.canCancelByDefault
    }

    func updateBlockedReason(statusMessage: String) -> String? {
        guard blocksUpdates else { return nil }
        let status = statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !status.isEmpty, status != "准备就绪", status != title else {
            return "Surge Relay 正在执行“\(title)”任务。"
        }
        return "Surge Relay 正在执行“\(title)”任务：\(status)"
    }
}

struct UpdateAdmission: Equatable, Sendable {
    var isAccepted: Bool
    var message: String

    var blockedReason: String? {
        isAccepted ? nil : message
    }

    static func allModules(
        activity: WorkActivity,
        updateableModuleCount: Int,
        statusMessage: String
    ) -> UpdateAdmission {
        if let reason = activity.updateBlockedReason(statusMessage: statusMessage) {
            return .rejected(reason)
        }
        guard updateableModuleCount > 0 else {
            return .rejected("没有可更新的模块。请添加 HTTP/HTTPS 更新地址，或让本地模块参与独立/总模块输出。")
        }
        return .accepted("已开始更新全部模块。")
    }

    static func allModules(
        isWorking: Bool,
        updateableModuleCount: Int,
        statusMessage: String
    ) -> UpdateAdmission {
        if isWorking {
            return .rejected(busyMessage(statusMessage: statusMessage))
        }
        guard updateableModuleCount > 0 else {
            return .rejected("没有可更新的模块。请添加 HTTP/HTTPS 更新地址，或让本地模块参与独立/总模块输出。")
        }
        return .accepted("已开始更新全部模块。")
    }

    static func module(
        _ module: RelayModule,
        moduleIsUpdateable: Bool,
        activity: WorkActivity,
        updateableModuleCount: Int,
        statusMessage: String
    ) -> UpdateAdmission {
        if let reason = activity.updateBlockedReason(statusMessage: statusMessage) {
            return .rejected(reason)
        }
        guard moduleIsUpdateable else {
            return .rejected("“\(module.name)”没有远程更新地址，也未参与独立或总模块输出。")
        }
        guard updateableModuleCount > 0 else {
            return .rejected("没有可更新的模块。请添加 HTTP/HTTPS 更新地址，或让本地模块参与独立/总模块输出。")
        }
        return .accepted("已开始更新 \(module.name)。")
    }

    static func module(
        _ module: RelayModule,
        moduleIsUpdateable: Bool,
        isWorking: Bool,
        updateableModuleCount: Int,
        statusMessage: String
    ) -> UpdateAdmission {
        if isWorking {
            return .rejected(busyMessage(statusMessage: statusMessage))
        }
        guard moduleIsUpdateable else {
            return .rejected("“\(module.name)”没有远程更新地址，也未参与独立或总模块输出。")
        }
        guard updateableModuleCount > 0 else {
            return .rejected("没有可更新的模块。请添加 HTTP/HTTPS 更新地址，或让本地模块参与独立/总模块输出。")
        }
        return .accepted("已开始更新 \(module.name)。")
    }

    private static func accepted(_ message: String) -> UpdateAdmission {
        UpdateAdmission(isAccepted: true, message: message)
    }

    private static func rejected(_ message: String) -> UpdateAdmission {
        UpdateAdmission(isAccepted: false, message: message)
    }

    private static func busyMessage(statusMessage: String) -> String {
        let status = statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !status.isEmpty, status != "准备就绪" else {
            return "Surge Relay 正在执行其他任务。"
        }
        return "Surge Relay 正在执行其他任务：\(status)"
    }
}
