import Foundation

enum ReleaseUpdateChannel {
    static let latestReleaseURL = URL(string: "https://github.com/junchan0412/SurgeRelay-macOS/releases/latest")!
}

struct GitHubRelease: Decodable, Equatable, Sendable {
    var tagName: String
    var name: String
    var htmlURL: URL
    var publishedAt: Date
    var body: String
    var assets: [GitHubReleaseAsset]
    var checksumValidations: [String: ReleaseAssetChecksumValidation] = [:]

    var version: String {
        tagName.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("v")
    }

    var packageAsset: GitHubReleaseAsset? {
        assets.first { $0.name.lowercased().hasSuffix(".pkg") }
    }

    var appZipAsset: GitHubReleaseAsset? {
        assets.first { $0.name.lowercased().hasSuffix(".app.zip") }
    }

    var installableAssets: [GitHubReleaseAsset] {
        [packageAsset, appZipAsset].compactMap(\.self)
    }

    var installGuidance: ReleaseInstallGuidance {
        ReleaseInstallGuidance(
            updateRecommendation: packageAsset == nil
                ? "后续更新优先使用 App 内 Sparkle；此 Release 缺少 pkg 手动更新包，请只在首次安装或排障时使用 app.zip。"
                : "后续更新优先使用 App 内 Sparkle；手动更新已有安装时可使用 pkg，安装器会替换 /Applications/Surge Relay.app 并清除隔离属性。",
            firstInstallRecommendation: appZipAsset == nil
                ? "此 Release 缺少 app.zip；首次安装请使用 pkg 或打开 Release 页面查看说明。"
                : "首次安装可使用 app.zip；如果 macOS 首次拦截，可右键打开或按文档处理一次隔离属性。",
            trustNotice: "当前发布资产使用固定自签名证书和 Sparkle EdDSA 更新签名，未做 Developer ID 公证；首次手动安装仍可能需要信任一次。",
            updateSystemImage: packageAsset == nil ? "exclamationmark.triangle.fill" : "shippingbox",
            updateNeedsAttention: packageAsset == nil
        )
    }

    func checksumAsset(for asset: GitHubReleaseAsset) -> GitHubReleaseAsset? {
        let expectedName = "\(asset.name).sha256".lowercased()
        return assets.first { $0.name.lowercased() == expectedName }
    }

    func checksumValidation(for asset: GitHubReleaseAsset) -> ReleaseAssetChecksumValidation {
        if let validation = checksumValidations[asset.name] {
            return validation
        }
        guard checksumAsset(for: asset) != nil else {
            return ReleaseAssetChecksumValidation(status: .missingChecksum)
        }
        guard asset.sha256Digest != nil else {
            return ReleaseAssetChecksumValidation(status: .missingDigest)
        }
        return ReleaseAssetChecksumValidation(status: .unreadable)
    }

    var notesPreview: String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 900 else { return trimmed }
        return String(trimmed.prefix(900)) + "..."
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case body
        case assets
    }
}

struct ReleaseInstallGuidance: Equatable, Sendable {
    var updateRecommendation: String
    var firstInstallRecommendation: String
    var trustNotice: String
    var updateSystemImage: String
    var updateNeedsAttention: Bool
}

struct ReleaseAssetChecksumValidation: Equatable, Sendable {
    var status: ReleaseAssetChecksumStatus
    var checksumHash: String? = nil
    var digestHash: String? = nil

    var title: String {
        switch status {
        case .matched: "sha256 匹配"
        case .missingChecksum: "缺少 sha256"
        case .missingDigest: "缺少 digest"
        case .mismatched: "sha256 不匹配"
        case .unreadable: "无法读取 sha256"
        }
    }

    var systemImage: String {
        switch status {
        case .matched: "checkmark.seal.fill"
        case .missingChecksum, .missingDigest, .mismatched, .unreadable: "exclamationmark.triangle.fill"
        }
    }
}

enum ReleaseAssetChecksumStatus: Equatable, Sendable {
    case matched
    case missingChecksum
    case missingDigest
    case mismatched
    case unreadable
}

struct GitHubReleaseAsset: Decodable, Equatable, Identifiable, Sendable {
    var name: String
    var downloadURL: URL
    var size: Int
    var digest: String?

    var id: String { name }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var digestDisplay: String {
        guard let digest = digest?.trimmingCharacters(in: .whitespacesAndNewlines),
              !digest.isEmpty else { return "GitHub digest 不可用" }
        guard digest.count > 28 else { return digest }
        return "\(digest.prefix(28))..."
    }

    var sha256Digest: String? {
        guard let digest = digest?.trimmingCharacters(in: .whitespacesAndNewlines),
              !digest.isEmpty else { return nil }
        return digest.replacingOccurrences(of: "sha256:", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
        case size
        case digest
    }
}

enum ReleaseUpdateAvailability: Equatable, Sendable {
    case newerAvailable
    case upToDate
    case olderThanCurrent
    case unknown

    static func compare(current: String, latest: String) -> ReleaseUpdateAvailability {
        let currentVersion = ReleaseVersion(current)
        let latestVersion = ReleaseVersion(latest)
        guard !currentVersion.components.isEmpty, !latestVersion.components.isEmpty else {
            return .unknown
        }
        if latestVersion > currentVersion { return .newerAvailable }
        if latestVersion == currentVersion { return .upToDate }
        return .olderThanCurrent
    }

    var title: String {
        switch self {
        case .newerAvailable: "发现新版本"
        case .upToDate: "当前已是最新"
        case .olderThanCurrent: "当前版本较新"
        case .unknown: "无法比较版本"
        }
    }

    var systemImage: String {
        switch self {
        case .newerAvailable: "arrow.down.circle.fill"
        case .upToDate: "checkmark.circle.fill"
        case .olderThanCurrent: "clock.badge.checkmark"
        case .unknown: "questionmark.circle"
        }
    }
}

struct ReleaseVersion: Comparable, Equatable, Sendable {
    var rawValue: String
    var components: [Int]

    init(_ value: String) {
        rawValue = value
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("v")
        components = normalized
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
