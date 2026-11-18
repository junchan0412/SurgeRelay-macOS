import SwiftUI

struct ModuleVersionHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let moduleID: UUID
    @State private var versions: [ModuleVersionRecord] = []
    @State private var selectedVersionID: UUID?
    @State private var comparison: ModuleVersionComparison?
    @State private var isLoading = false
    @State private var confirmsRestore = false
    @State private var confirmsPublish = false
    @State private var publishReview: SelectedPublishLintReview?
    @State private var restored = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                "版本历史与回退",
                subtitle: "保存正文与受管脚本资源；来源、参数和发布设置沿用当前配置。",
                systemImage: "clock.arrow.circlepath"
            ) {
                Button("刷新") { Task { await loadVersions() } }
                    .controlSize(.small)
                    .disabled(model.isWorking || isLoading)
            }

            HSplitView {
                List(versions, selection: $selectedVersionID) { version in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(version.createdAt.formatted(date: .abbreviated, time: .standard))
                            .font(.system(size: 12, weight: .semibold))
                        Text(version.reason.title + " · \(version.assets.count) 个脚本")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(version.byteCount), countStyle: .file))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .tag(version.id)
                }
                .listStyle(.sidebar)
                .frame(minWidth: 220, idealWidth: 248, maxWidth: 300)
                .disabled(model.isWorking || isLoading)

                comparisonPane
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Design.Palette.codeBackground)
            }

            SheetActionFooter {
                Text(restored ? "历史内容已恢复到缓存；后续发布按现有设置执行。" : "保留最近最多 20 版（约 128 MiB）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if restored {
                    Button("发布当前模块…") { confirmsPublish = true }
                        .disabled(model.isWorking)
                }
                Button("恢复选中版本到缓存…") { confirmsRestore = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking || comparison == nil || comparison?.version.fingerprint == comparison?.expectedFingerprint)
            }
        }
        .frame(minWidth: 920, minHeight: 580)
        .task { await loadVersions() }
        .task(id: selectedVersionID) { await compareSelection() }
        .confirmationDialog("恢复历史正文和脚本？", isPresented: $confirmsRestore) {
            Button("恢复到缓存并暂停自动刷新", role: .destructive) {
                guard let comparison else { return }
                Task {
                    do {
                        try await model.restoreModuleVersion(comparison)
                        restored = true
                        await loadVersions()
                    } catch { errorMessage = error.localizedDescription }
                }
            }
        } message: {
            Text(comparison?.currentContentProblem == nil
                 ? "当前内容会先保存为历史版本。新的未保存草稿仍保留；该模块改为仅手动刷新，避免历史内容立即被更新。本次不写入发布目标；后续发布仍按现有发布设置执行。若比较后当前内容已变化，回退将停止。"
                 : "当前损坏内容会另存原始备份。新的未保存草稿仍保留；该模块改为仅手动刷新，避免历史内容立即被更新。本次不写入发布目标；后续发布仍按现有发布设置执行。若比较后内容已变化，回退将停止。")
        }
        .confirmationDialog("发布当前模块？", isPresented: $confirmsPublish) {
            Button("发布") {
                Task { await preparePublish() }
            }
        } message: { Text("将当前缓存内容发布到这个模块已配置并启用的目标。") }
        .sheet(item: $publishReview) { review in
            ModuleLintView(issues: review.issues) {
                publishReview = nil
                Task { await confirmPublish(token: review.reviewToken) }
            }
            .environment(model)
        }
        .alert("无法完成版本操作", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private var comparisonPane: some View {
        if isLoading || model.isWorking && comparison == nil {
            ProgressView("正在读取版本…")
        } else if let comparison {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("选中历史版本 → 当前缓存")
                        .font(.system(size: 13, weight: .semibold))
                    MetadataPill("−\(comparison.diff.removedCount) / +\(comparison.diff.addedCount) 行")
                    if !comparison.changedAssets.isEmpty {
                        MetadataPill("\(comparison.changedAssets.count) 个脚本变化", tint: Design.Palette.accent)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Design.Palette.surface)

                if let problem = comparison.currentContentProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(Design.Palette.warning)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }

                if !comparison.changedAssets.isEmpty {
                    DisclosureGroup("脚本资源变化") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(comparison.changedAssets, id: \.self) { Text($0).textSelection(.enabled) }
                            }
                            .font(.system(size: 11, design: .monospaced))
                        }
                        .frame(maxHeight: 120)
                    }
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Design.Palette.surface)
                }

                Divider()

                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(comparison.diff.rows.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top, spacing: 8) {
                                Text(row.localLine.map(String.init) ?? "–")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 44, alignment: .trailing)
                                Text(row.githubLine.map(String.init) ?? "–")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 44, alignment: .trailing)
                                Text(row.kind == .removed ? "−" : row.kind == .added ? "+" : " ")
                                    .foregroundStyle(row.kind == .added ? Design.Palette.success : row.kind == .removed ? Design.Palette.error : .secondary)
                                    .frame(width: 10)
                                Text(String(row.text.prefix(4_000))).textSelection(.enabled)
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.vertical, 3)
                            .padding(.horizontal, 10)
                            .frame(minWidth: 550, alignment: .leading)
                            .background(
                                row.kind == .removed ? Design.Palette.error.opacity(0.10)
                                    : row.kind == .added ? Design.Palette.success.opacity(0.10)
                                    : Color.clear
                            )
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        } else {
            ContentUnavailableView(
                versions.isEmpty ? "暂无历史版本" : "选择一个版本查看差异",
                systemImage: "clock.arrow.circlepath"
            )
        }
    }

    private func loadVersions() async {
        isLoading = true
        defer { isLoading = false }
        do {
            versions = try await model.moduleVersions(moduleID: moduleID)
            comparison = nil
            selectedVersionID = versions.first?.id
        } catch { errorMessage = error.localizedDescription }
    }

    private func preparePublish() async {
        model.cancelAutomaticPublishSchedule()
        do {
            let payload = try await model.webPublishPreview(WebPublishPreviewRequest(moduleIDs: [moduleID]), retainsForNativeUI: true)
            let issues = payload.previews.flatMap(\.issues)
            if issues.isEmpty {
                await confirmPublish(token: payload.token)
            } else {
                publishReview = SelectedPublishLintReview(reviewToken: payload.token, moduleIDs: payload.moduleIDs, issues: issues)
            }
        } catch {
            if !model.isCurrentWorkCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    private func confirmPublish(token: UUID) async {
        do {
            let result = try await model.confirmWebPublish(token: token)
            if result.attempt?.results.contains(where: { $0.status == .failed }) == true || (!result.ok && result.attempt == nil) {
                errorMessage = result.message
            }
        } catch {
            if !model.isCurrentWorkCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    private func compareSelection() async {
        guard let versionID = selectedVersionID else { comparison = nil; return }
        comparison = nil
        do {
            let result = try await model.compareModuleVersion(moduleID: moduleID, versionID: versionID)
            guard !Task.isCancelled, selectedVersionID == versionID else { return }
            comparison = result
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
