import SwiftUI

@MainActor
struct ModuleSidebarStatusCard: View {
    @Environment(AppModel.self) private var model
    @State private var showsErrorDetails = false
    @State private var showsPendingSaves = false

    var body: some View {
        ViewThatFits(in: .vertical) {
            statusContent.fixedSize(horizontal: false, vertical: true)
            ScrollView {
                statusContent
            }
        }
        .frame(maxHeight: 190)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Design.Separator.color.opacity(Design.Separator.opacity))
                .frame(height: Design.Separator.hairline)
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
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("错误详情").font(.headline)
                        Spacer()
                        TextCopyButton(text: error, title: "复制错误")
                        Button("关闭") { showsErrorDetails = false }
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("work.close-error-details")
                    }
                    ScrollView {
                        Text(error)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)
                }
                .padding(16)
                .frame(width: 520, height: 360)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("work.error-detail-content")
            }
        }
    }

    private var statusContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.pendingModuleSaves.isEmpty {
                Button {
                    showsPendingSaves = true
                } label: {
                    Label(pendingSaveTitle, systemImage: "list.bullet.rectangle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("work.pending-saves")
                Divider()
            }
            if let error = model.presentedError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Design.Palette.warning)
                        .accessibilityHidden(true)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(error)
                    Spacer(minLength: 4)
                    Button {
                        model.presentedError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
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
                    .accessibilityIdentifier("work.error-details")
                .transition(.opacity)
                Divider()
            }

            if !model.workActivity.isActive,
               model.presentedError == nil,
               automaticPublishText == nil,
               !model.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               model.statusMessage != "准备就绪" {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(model.statusMessage)
                }
                Divider()
            }

            if let attempt = model.selectedPublishAttempt, !attempt.retryDestinations.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("所选模块发布结果").font(.caption.weight(.medium))
                    ForEach(attempt.results) { result in
                        Text("\(result.destination.title)：\(result.message)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(result.message)
                    }
                    Button("重试未完成目标") {
                        Task { await model.retrySelectedPublish() }
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isWorking)
                    .help("使用当前模块内容，只重试未完成的发布目标")
                    .accessibilityIdentifier("publish.retry-targets")
                }
                Divider()
            }

            if model.workActivity.isActive {
                if model.workActivity.kind == .updatingModules,
                   let name = synchronizingModuleName,
                   model.synchronizationTotalCount > 0 {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(name)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentTransition(.identity)
                            Spacer(minLength: 4)
                            Text("\(model.synchronizationCompletedCount)/\(model.synchronizationTotalCount)")
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(model.synchronizationCompletedCount)))
                                .animation(.smooth(duration: 0.25), value: model.synchronizationCompletedCount)
                        }
                        .font(.caption)
                        ProgressView(value: synchronizationProgress)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .animation(.smooth(duration: 0.25), value: synchronizationProgress)
                            .accessibilityLabel("模块更新进度")
                            .accessibilityValue("已完成 \(model.synchronizationCompletedCount) 个，共 \(model.synchronizationTotalCount) 个模块")
                            .accessibilityIdentifier("work.progress")
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                        Text(workActivityStatusText)
                            .font(.caption)
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
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .help(stages.map { "\($0.moduleName)：\($0.detail ?? $0.stage.title)" }.joined(separator: "\n"))
                    .accessibilityIdentifier("work.stages")
                }
                if model.workActivity.canCancel {
                    Button {
                        model.cancelCurrentWork()
                    } label: {
                        Label(model.workCancellationRequested ? "正在取消…" : "取消当前任务", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(!model.canCancelCurrentWork)
                    .accessibilityIdentifier("work.cancel")
                }
                Divider()
            }

            if let automaticPublishText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "paperplane.circle.fill")
                        .foregroundStyle(Design.Palette.accent)
                        .accessibilityHidden(true)
                    Text(automaticPublishText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .transition(.opacity)
                Divider()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("最新更新时间")
                    .font(.caption.weight(.medium))
                Text(latestUpdateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("待处理保存队列").font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("按提交顺序保存；当前任务结束后自动处理。失败项目会保留，可重试或取消。")
                .font(.callout).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(Design.Palette.error).textSelection(.enabled)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.pendingModuleSaves) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.draft.name).font(.headline)
                                Spacer()
                                if item.errorMessage != nil {
                                    Button("重试") { perform { try await model.retryPendingModuleSave(id: item.id) } }
                                }
                                Button("取消") { perform { try await model.cancelPendingModuleSave(id: item.id) } }
                                    .disabled(model.activePendingModuleSaveID == item.id)
                            }
                            Text(item.errorMessage ?? (model.activePendingModuleSaveID == item.id ? "正在保存…" : "等待当前任务完成"))
                                .font(.caption)
                                .foregroundStyle(item.errorMessage == nil ? Color.secondary : Design.Palette.error)
                                .textSelection(.enabled)
                            Divider()
                        }
                    }
                    if model.pendingModuleSaves.isEmpty {
                        Text("所有排队保存已处理完成").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 380)
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
