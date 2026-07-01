import AppKit
import SwiftUI

struct CheckForUpdatesView: View {
    var action: () -> Void

    init(action: @escaping () -> Void = {
        NSWorkspace.shared.open(ReleaseUpdateChannel.latestReleaseURL)
    }) {
        self.action = action
    }

    var body: some View {
        Button("查看更新…", action: action)
    }
}

struct CheckForUpdatesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var phase: UpdateCheckPhase = .loading

    private let client = GitHubReleaseClient()

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    private var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .cornerRadius(10)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Surge Relay 更新")
                        .font(.title2.bold())
                    Text("当前版本 \(currentVersion) (\(currentBuild))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }

            Group {
                switch phase {
                case .loading:
                    loadingView
                case let .loaded(release):
                    releaseView(release)
                case let .failed(message):
                    failureView(message)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("打开 Releases", systemImage: "safari") {
                    NSWorkspace.shared.open(ReleaseUpdateChannel.latestReleaseURL)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .task { await refresh() }
    }

    private var loadingView: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在检查 GitHub Release…")
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 180, alignment: .center)
    }

    private func failureView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("无法读取最新版本", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("重新检查", systemImage: "arrow.clockwise") {
                Task { await refresh() }
            }
        }
        .frame(minHeight: 180, alignment: .topLeading)
    }

    private func releaseView(_ release: GitHubRelease) -> some View {
        let availability = ReleaseUpdateAvailability.compare(
            current: currentVersion,
            latest: release.version
        )
        return VStack(alignment: .leading, spacing: 14) {
            LabeledContent("最新版本") {
                Text("\(release.version) · \(release.publishedAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            LabeledContent("状态") {
                Label(availability.title, systemImage: availability.systemImage)
                    .foregroundStyle(availability.color)
            }

            if let package = release.packageAsset {
                HStack(spacing: 10) {
                    Button("下载 pkg", systemImage: "shippingbox") {
                        NSWorkspace.shared.open(package.downloadURL)
                    }
                    .buttonStyle(.borderedProminent)
                    Text(package.formattedSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let appZip = release.appZipAsset {
                Button("下载 app.zip", systemImage: "arrow.down.app") {
                    NSWorkspace.shared.open(appZip.downloadURL)
                }
            }

            if !release.installableAssets.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("资产完整性")
                        .font(.headline)
                    ForEach(release.installableAssets) { asset in
                        assetIntegrityRow(asset, checksum: release.checksumAsset(for: asset))
                    }
                }
            }

            if !release.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("发布说明")
                        .font(.headline)
                    ScrollView {
                        Text(release.notesPreview)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxHeight: 150)
                }
            }
        }
        .frame(minHeight: 180, alignment: .topLeading)
    }

    private func assetIntegrityRow(_ asset: GitHubReleaseAsset, checksum: GitHubReleaseAsset?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name)
                    .font(.caption.weight(.semibold))
                    .textSelection(.enabled)
                Text("\(asset.formattedSize) · \(asset.digestDisplay)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Label(
                checksum == nil ? "缺少 sha256" : "已提供 sha256",
                systemImage: checksum == nil ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
            )
            .font(.caption)
            .foregroundStyle(checksum == nil ? .orange : .green)
        }
    }

    @MainActor
    private func refresh() async {
        phase = .loading
        do {
            phase = .loaded(try await client.latestRelease())
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

private enum UpdateCheckPhase {
    case loading
    case loaded(GitHubRelease)
    case failed(String)
}

struct GitHubRelease: Decodable, Equatable, Sendable {
    var tagName: String
    var name: String
    var htmlURL: URL
    var publishedAt: Date
    var body: String
    var assets: [GitHubReleaseAsset]

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

    func checksumAsset(for asset: GitHubReleaseAsset) -> GitHubReleaseAsset? {
        let expectedName = "\(asset.name).sha256".lowercased()
        return assets.first { $0.name.lowercased() == expectedName }
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

    var color: Color {
        switch self {
        case .newerAvailable: .blue
        case .upToDate: .green
        case .olderThanCurrent, .unknown: .secondary
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

actor GitHubReleaseClient {
    static let latestReleaseAPIURL = URL(
        string: "https://api.github.com/repos/junchan0412/SurgeRelay-macOS/releases/latest"
    )!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.latestReleaseAPIURL, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SurgeRelay/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = String(data: data, encoding: .utf8) ?? "GitHub Release 查询失败。"
            throw RelayError.httpFailure(status: status, message: String(message.prefix(240)))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: data)
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
