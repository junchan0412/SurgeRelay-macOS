import SwiftUI

@MainActor
struct ModuleSidebarStatusCard: View {
    @Environment(AppModel.self) private var model
    @State private var showsErrorDetails = false
    @State private var showsPendingSaves = false

    private var hasDetailedStatus: Bool {
        !model.pendingModuleSaves.isEmpty
            || model.presentedError != nil
            || model.workActivity.isActive
            || automaticPublishText != nil
            || (model.selectedPublishAttempt.map { !$0.retryDestinations.isEmpty } ?? false)
            || (!model.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.statusMessage != "准备就绪")
    }

    var body: some View {
        Group {
            if hasDetailedStatus {
                ViewThatFits(in: .vertical) {
                    detailedStatusContent.fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        detailedStatusContent
                    }
                }
                .frame(maxHeight: 190)
            } else {
                compactIdleBar
            }
        }
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .animation(.snappy(duration: 0.22), value: model.workActivity.kind)
        .animation(.snappy(duration: 0.22), value: model.workActivity.isActive)
        .animation(.snappy(duration: 0.22), value: model.automaticPublishRunsAt)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.status")
        .sheet(isPresented: $showsPendingSaves) {
            PendingModuleSavesView().environment(model)
        }
        .sheet(isPresented: $showsErrorDetails) {
            if let error = model.presentedError {
                VStack(spacing: 0) {
                    SheetHeader("错误详情", subtitle: "本次操作返回了以下错误信息", systemImage: "exclamationmark.triangle.fill") {
                        TextCopyButton(text: error, title: "复制错误")
                    }
                    ScrollView {
                        Text(error)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .background(Design.Palette.codeBackground)

                    SheetActionFooter {
                        Spacer()
                        Button("关闭") { showsErrorDetails = false }
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("work.close-error-details")
                    }
                }
                .frame(width: 540, height: 380)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("work.error-detail-content")
            }
        }
    }

    private var compactIdleBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.moduleSummary.attentionCount > 0 ? Design.Palette.warning : Design.Palette.success)
                .frame(width: 6, height: 6)
            Text("最新更新")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(latestUpdateText)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var detailedStatusContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.pendingModuleSaves.isEmpty {
                Button {
                    showsPendingSaves = true
                } label: {
                    Label(pendingSaveTitle, systemImage: "tray.full")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("work.pending-saves")
            }

            if let error = model.presentedError {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Design.Palette.warning)
                            .accessibilityHidden(true)
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(error)
                        Button {
                            model.presentedError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("关闭错误提示")
                        .accessibilityLabel("关闭错误提示")
                        .accessibilityIdentifier("work.dismiss-error")
                    }
                    Button("查看完整错误…") { showsErrorDetails = true }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .font(.system(size: 11, weight: .medium))
                        .accessibilityIdentifier("work.error-details")
                }
            }

            if !model.workActivity.isActive,
               model.presentedError == nil,
               automaticPublishText == nil,
               !model.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               model.statusMessage != "准备就绪" {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(model.statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(model.statusMessage)
                }
            }

            if let attempt = model.selectedPublishAttempt, !attempt.retryDestinations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("所选模块发布结果")
                        .font(.system(size: 11, weight: .semibold))
                    ForEach(attempt.results) { result in
                        Text("\(result.destination.title)：\(result.message)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(result.message)
                    }
                    Button("重试未完成目标") {
                        Task { await model.retrySelectedPublish() }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                    .disabled(model.isWorking)
                    .help("使用当前模块内容，只重试未完成的发布目标")
                    .accessibilityIdentifier("publish.retry-targets")
                }
            }

            if model.workActivity.isActive {
                VStack(alignment: .leading, spacing: 5) {
                    if model.workActivity.kind == .updatingModules,
                       let name = synchronizingModuleName,
                       model.synchronizationTotalCount > 0 {
                        HStack(spacing: 8) {
                            Text(name)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentTransition(.identity)
                            Text("\(model.synchronizationCompletedCount)/\(model.synchronizationTotalCount)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText(value: Double(model.synchronizationCompletedCount)))
                                .animation(.smooth(duration: 0.25), value: model.synchronizationCompletedCount)
                        }
                        .font(.system(size: 11, weight: .medium))

                        ProgressView(value: synchronizationProgress)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .animation(.smooth(duration: 0.25), value: synchronizationProgress)
                            .accessibilityLabel("模块更新进度")
                            .accessibilityValue("已完成 \(model.synchronizationCompletedCount) 个，共 \(model.synchronizationTotalCount) 个模块")
                            .accessibilityIdentifier("work.progress")
                    } else {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                            Text(workActivityStatusText)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(2)
                                .contentTransition(.opacity)
                        }
                    }

                    if let stages = model.workActivity.activeStages, !stages.isEmpty {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let counts = WorkStage.allCases.compactMap { stage -> String? in
                                let count = stages.filter { $0.stage == stage }.count
                                return count == 0 ? nil : "\(stage.title) \(count)"
                            }.joined(separator: " · ")
                            let elapsed = stages.map { max(0, Int(context.date.timeIntervalSince($0.startedAt))) }.max() ?? 0
                            Text("\(counts) · \(elapsed) 秒")
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .help(stages.map { "\($0.moduleName)：\($0.stage.title)" }.joined(separator: "\n"))
                        .accessibilityIdentifier("work.stages")
                    }

                    if model.workActivity.canCancel {
                        Button {
                            model.cancelCurrentWork()
                        } label: {
                            Label(model.workCancellationRequested ? "正在取消…" : "取消当前任务", systemImage: "xmark.circle")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(!model.canCancelCurrentWork)
                        .accessibilityIdentifier("work.cancel")
                    }
                }
            }

            if let automaticPublishText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "paperplane.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Design.Palette.accent)
                        .accessibilityHidden(true)
                    Text(automaticPublishText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 6) {
                Text("最新更新时间")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Text(latestUpdateText)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var latestUpdateText: String {
        guard let date = model.moduleSummary.latestUpdatedAt else { return "尚未更新" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var pendingSaveTitle: String {
        let failed = model.pendingModuleSaves.filter { $0.errorMessage != nil }.count
        return failed == 0 ? "待处理保存队列（\(model.pendingModuleSaves.count)）" : "保存队列：\(failed) 项失败，点击处理"
    }

    private var automaticPublishText: String? {
        guard let runsAt = model.automaticPublishRunsAt else { return nil }
        return "自动发布已排队，预计 \(runsAt.formatted(date: .omitted, time: .shortened)) 执行"
    }

    private var workActivityStatusText: String {
        let title = model.workActivity.title
        let status = model.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !status.isEmpty, status != "准备就绪", status != title else { return title }
        return "\(title)：\(status)"
    }

    private var synchronizingModuleName: String? {
        if model.synchronizingModuleIDs.count > 1 { return "正在处理 \(model.synchronizingModuleIDs.count) 个模块" }
        guard let id = model.synchronizingModuleID else { return nil }
        return model.modules.first(where: { $0.id == id })?.name
    }

    private var synchronizationProgress: Double {
        guard model.synchronizationTotalCount > 0 else { return 0 }
        return min(
            max(Double(model.synchronizationCompletedCount) / Double(model.synchronizationTotalCount), 0),
            1
        )
    }
}

private struct PendingModuleSavesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("待处理保存队列", subtitle: "按提交顺序执行；失败项目可单独重试或取消", systemImage: "tray.full")

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Design.Palette.error)
                            .textSelection(.enabled)
                    }
                    if model.pendingModuleSaves.isEmpty {
                        ContentUnavailableView("保存队列为空", systemImage: "checkmark.circle", description: Text("所有待保存更改已处理完毕。"))
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        GroupedCardStack(dividerInset: 0) {
                            ForEach(model.pendingModuleSaves) { item in
                                HStack(alignment: .center, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.draft.name)
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(item.errorMessage ?? (model.activePendingModuleSaveID == item.id ? "正在保存…" : "等待当前任务完成"))
                                            .font(.caption)
                                            .foregroundStyle(item.errorMessage == nil ? Color.secondary : Design.Palette.error)
                                            .textSelection(.enabled)
                                    }
                                    Spacer()
                                    if item.errorMessage != nil {
                                        Button("重试") { perform { try await model.retryPendingModuleSave(id: item.id) } }
                                            .controlSize(.small)
                                    }
                                    Button("取消") { perform { try await model.cancelPendingModuleSave(id: item.id) } }
                                        .controlSize(.small)
                                        .disabled(model.activePendingModuleSaveID == item.id)
                                }
                                .padding(.vertical, 8)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Design.Palette.canvas)

            SheetActionFooter {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 540, height: 380)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.pending-saves-panel")
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await action(); errorMessage = nil }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
