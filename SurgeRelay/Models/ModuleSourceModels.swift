import Foundation

enum ModuleSourceIdentity {
    static func canonicalValue(for source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.isFileURL {
            return url.standardizedFileURL.absoluteString
        }
        guard var components = URLComponents(string: trimmed) else { return trimmed }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil

        if (components.scheme == "https" && components.port == 443) ||
            (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        }

        return components.string ?? trimmed
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        canonicalValue(for: lhs) == canonicalValue(for: rhs)
    }
}

enum ModuleSourceFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case quantumultX
    case loon
    case surge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自动识别"
        case .quantumultX: "Quantumult X 重写"
        case .loon: "Loon 插件"
        case .surge: "Surge 模块"
        }
    }

    var shortTitle: String {
        switch self {
        case .automatic: "自动"
        case .quantumultX: "Quantumult X"
        case .loon: "Loon"
        case .surge: "Surge"
        }
    }

    func resolvedFormat(for sourceURL: URL) -> ModuleSourceFormat {
        guard self == .automatic else { return self }
        let path = sourceURL.path.lowercased()
        switch sourceURL.pathExtension.lowercased() {
        case "sgmodule": return .surge
        case "plugin", "lpx": return .loon
        default: break
        }
        if path.contains("/loon/") { return .loon }
        if path.contains("/quantumultx/") || path.contains("/quantumult-x/") || path.contains("/qx/") {
            return .quantumultX
        }
        return .quantumultX
    }

    func scriptHubType(for sourceURL: URL) -> String {
        switch resolvedFormat(for: sourceURL) {
        case .quantumultX: "qx-rewrite"
        case .loon: "loon-plugin"
        case .surge: "surge-module"
        case .automatic: "qx-rewrite"
        }
    }

    func isNativeSurgeModule(for sourceURL: URL) -> Bool {
        resolvedFormat(for: sourceURL) == .surge
    }
}

enum ModuleStorageLocation: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case gitHub

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "本地模块"
        case .gitHub: "GitHub 模块"
        }
    }

    var detail: String {
        switch self {
        case .local: "储存在本地模块根目录"
        case .gitHub: "储存在 GitHub 模块目录"
        }
    }

    var systemImage: String {
        switch self {
        case .local: "folder"
        case .gitHub: "cloud"
        }
    }

    static func preferredDefault(publishToLocal: Bool) -> ModuleStorageLocation {
        publishToLocal ? .local : .gitHub
    }
}

enum ModuleInitialSource: Equatable, Sendable {
    case pending
    case selfAuthored
    case subscribed(ModuleSourceFormat)
    case invalid

    var title: String {
        switch self {
        case .pending:
            "待更新识别"
        case .selfAuthored:
            "自写模块"
        case .subscribed(let format):
            switch format {
            case .automatic:
                "订阅来源"
            case .quantumultX:
                "订阅 Quantumult X"
            case .loon:
                "订阅 Loon"
            case .surge:
                "订阅 Surge 模块"
            }
        case .invalid:
            "来源记录无效"
        }
    }

    var systemImage: String {
        switch self {
        case .pending: "clock.arrow.circlepath"
        case .selfAuthored: "pencil.and.outline"
        case .subscribed: "link"
        case .invalid: "exclamationmark.triangle"
        }
    }

    var isSubscribed: Bool {
        if case .subscribed = self { return true }
        return false
    }
}

enum ModuleUpdateState: String, Codable, Sendable {
    case never
    case updating
    case current
    case failed

    var title: String {
        switch self {
        case .never: "尚未更新"
        case .updating: "正在更新"
        case .current: "已是最新"
        case .failed: "更新失败"
        }
    }

    var systemImage: String {
        switch self {
        case .never: "circle"
        case .updating: "arrow.triangle.2.circlepath"
        case .current: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}
