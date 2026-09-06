import SwiftUI

struct ActivityHistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var issuesOnly = false
    @State private var confirmsClear = false

    private var entries: [UpdateHistoryEntry] {
        model.updateHistory.filter { !issuesOnly || $0.outcome == .failed || $0.outcome == .cachedAfterFailure }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("活动记录").font(.system(size: 32, weight: .bold))
                    Text("回看每一次更新、缓存回退与发布结果。")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                HStack {
                    Picker("显示记录", selection: $issuesOnly) {
                        Text("全部活动").tag(false)
                        Text("需要关注").tag(true)
                    }.pickerStyle(.segmented).frame(width: 220)
                    Spacer()
                    Text("\(entries.count) 条记录").font(.callout).foregroundStyle(.secondary)
                    Button("清空记录", systemImage: "trash") { confirmsClear = true }
                        .buttonStyle(.borderless).disabled(model.updateHistory.isEmpty)
                }
                if entries.isEmpty {
                    ContentUnavailableView(
                        issuesOnly ? "没有异常记录" : "还没有活动记录",
                        systemImage: issuesOnly ? "checkmark.circle" : "clock",
                        description: Text(issuesOnly ? "更新失败和缓存回退会显示在这里。" : "更新模块或发布后，可以在这里查看结果。")
                    ).frame(maxWidth: .infinity, minHeight: 260).detailCard()
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            ActivityHistoryRow(entry: entry, showsDetails: true)
                            if entry.id != entries.last?.id { Divider().padding(.leading, 58) }
                        }
                    }.detailCard()
                }
                Text("保留最近 200 条活动。清空记录不会删除模块或发布文件。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 940, alignment: .leading).padding(32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Design.Palette.canvas)
        .accessibilityIdentifier("workspace.activity")
        .confirmationDialog("清空所有活动记录？", isPresented: $confirmsClear) {
            Button("清空记录", role: .destructive) { model.clearUpdateHistory() }
        } message: { Text("模块和发布文件会保留。") }
    }
}

struct ActivityHistoryRow: View {
    @Environment(AppModel.self) private var model
    let entry: UpdateHistoryEntry
    var showsDetails = false

    private var color: Color {
        switch entry.outcome {
        case .failed: Design.Palette.error
        case .cachedAfterFailure: Design.Palette.warning
        case .updated, .published: Design.Palette.success
        case .unchanged: .secondary
        }
    }

    private var symbol: String {
        switch entry.outcome {
        case .failed: "exclamationmark.circle"
        case .cachedAfterFailure: "clock.arrow.circlepath"
        case .updated: "arrow.down.circle"
        case .published: "arrow.up.circle"
        case .unchanged: "checkmark.circle"
        }
    }

    private var moduleExists: Bool {
        entry.moduleID.map { id in model.modules.contains { $0.id == id } } ?? false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 21)).foregroundStyle(color)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.moduleName).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text(entry.outcome.title).font(.system(size: 12)).foregroundStyle(color)
                    Spacer(minLength: 8)
                    Text(entry.date, format: .dateTime.month(.twoDigits).day().hour().minute())
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(entry.message).font(.system(size: 13)).foregroundStyle(.secondary)
                    .lineLimit(showsDetails ? nil : 1).textSelection(.enabled)
                if showsDetails {
                    HStack(spacing: 12) {
                        if entry.duration > 0 {
                            Text("耗时 \(entry.duration.formatted(.number.precision(.fractionLength(2)))) 秒")
                                .monospacedDigit()
                        }
                        if moduleExists {
                            Button("查看模块") { model.selectedModuleID = entry.moduleID }
                                .buttonStyle(.borderless)
                        }
                        if let commitSHA = entry.commitSHA,
                           let url = GitHubPublishSnapshot.commitURL(for: commitSHA, settings: model.settings.github).flatMap(URL.init(string:)) {
                            Link("查看提交 \(String(commitSHA.prefix(7)))", destination: url)
                        }
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
