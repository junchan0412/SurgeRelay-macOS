import AppKit
import Sparkle
import SwiftUI

@MainActor
final class SparkleUpdateController {
    static let shared = SparkleUpdateController()

    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private init() {}

    func start() {}

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

struct CheckForUpdatesView: View {
    var action: () -> Void

    init(action: (() -> Void)? = nil) {
        self.action = action ?? {
            Task { @MainActor in
                SparkleUpdateController.shared.checkForUpdates()
            }
        }
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

            installationGuidanceView(release.installGuidance)

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
                        assetIntegrityRow(asset, validation: release.checksumValidation(for: asset))
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

    private func installationGuidanceView(_ guidance: ReleaseInstallGuidance) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("安装建议")
                .font(.headline)
            Label(guidance.updateRecommendation, systemImage: guidance.updateSystemImage)
                .foregroundStyle(guidance.updateNeedsAttention ? .orange : .secondary)
            Label(guidance.firstInstallRecommendation, systemImage: "arrow.down.app")
                .foregroundStyle(.secondary)
            Label(guidance.trustNotice, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func assetIntegrityRow(_ asset: GitHubReleaseAsset, validation: ReleaseAssetChecksumValidation) -> some View {
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
                validation.title,
                systemImage: validation.systemImage
            )
            .font(.caption)
            .foregroundStyle(checksumValidationColor(validation.status))
        }
    }

    private func checksumValidationColor(_ status: ReleaseAssetChecksumStatus) -> Color {
        switch status {
        case .matched: .green
        case .missingChecksum, .missingDigest, .mismatched, .unreadable: .orange
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

private extension ReleaseUpdateAvailability {
    var color: Color {
        switch self {
        case .newerAvailable: .blue
        case .upToDate: .green
        case .olderThanCurrent, .unknown: .secondary
        }
    }
}
