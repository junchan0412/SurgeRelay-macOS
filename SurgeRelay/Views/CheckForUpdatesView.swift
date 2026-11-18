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
        Button("检查软件更新…", systemImage: "arrow.down.circle", action: action)
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
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Surge Relay 软件更新")
                        .font(.system(size: 16, weight: .semibold))
                    Text("当前版本 \(currentVersion) (\(currentBuild))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("重新检查", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .controlSize(.small)
                .disabled(isLoading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Design.Palette.surface)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Design.Separator.color).frame(height: 1)
            }

            ScrollView {
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
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Design.Palette.canvas)

            SheetActionFooter {
                Button("打开 GitHub Releases", systemImage: "safari") {
                    NSWorkspace.shared.open(ReleaseUpdateChannel.latestReleaseURL)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 560, height: 480)
        .task { await refresh() }
    }

    private var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    private var loadingView: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在读取最新 GitHub Release…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
    }

    private func failureView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("无法读取最新版本", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Design.Palette.warning)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailCard()
    }

    private func releaseView(_ release: GitHubRelease) -> some View {
        let availability = ReleaseUpdateAvailability.compare(
            current: currentVersion,
            latest: release.version
        )
        return VStack(alignment: .leading, spacing: 16) {
            DetailInfoSection("版本状态") {
                DetailInfoRow(
                    label: "最新版本",
                    value: "\(release.version) · \(release.publishedAt.formatted(date: .abbreviated, time: .shortened))",
                    icon: "tag"
                )
                HStack(spacing: Design.Row.spacing) {
                    Image(systemName: availability.systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(availability.color)
                        .frame(width: Design.Row.iconWidth)
                    Text("更新状态")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: Design.Row.labelWidth, alignment: .leading)
                    MetadataPill(availability.title, systemImage: availability.systemImage, tint: availability.color)
                    Spacer()
                }
                .padding(.vertical, Design.Row.verticalPadding)

                HStack(spacing: 8) {
                    if let package = release.packageAsset {
                        Button("下载安装包 (.pkg · \(package.formattedSize))", systemImage: "shippingbox") {
                            NSWorkspace.shared.open(package.downloadURL)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    if let appZip = release.appZipAsset {
                        Button("下载压缩包 (.app.zip)", systemImage: "arrow.down.app") {
                            NSWorkspace.shared.open(appZip.downloadURL)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 6)
            }

            DetailInfoSection("安装提示") {
                installationGuidanceView(release.installGuidance)
                    .padding(.vertical, 6)
            }

            if !release.installableAssets.isEmpty {
                DetailInfoSection("校验摘要") {
                    ForEach(release.installableAssets) { asset in
                        assetIntegrityRow(asset, validation: release.checksumValidation(for: asset))
                    }
                }
            }

            if !release.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DetailInfoSection("发布说明") {
                    Text(release.notesPreview)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    private func installationGuidanceView(_ guidance: ReleaseInstallGuidance) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(guidance.updateRecommendation, systemImage: guidance.updateSystemImage)
                .foregroundStyle(guidance.updateNeedsAttention ? Design.Palette.warning : .secondary)
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
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name)
                    .font(.system(size: 12, weight: .semibold))
                    .textSelection(.enabled)
                Text("\(asset.formattedSize) · \(asset.digestDisplay)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            MetadataPill(
                validation.title,
                systemImage: validation.systemImage,
                tint: checksumValidationColor(validation.status)
            )
        }
        .padding(.vertical, 6)
    }

    private func checksumValidationColor(_ status: ReleaseAssetChecksumStatus) -> Color {
        switch status {
        case .matched: Design.Palette.success
        case .missingChecksum, .missingDigest, .mismatched, .unreadable: Design.Palette.warning
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
        case .newerAvailable: Design.Palette.accent
        case .upToDate: Design.Palette.success
        case .olderThanCurrent, .unknown: .secondary
        }
    }
}
