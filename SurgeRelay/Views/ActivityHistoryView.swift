import SwiftUI

struct ActivityHistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var issuesOnly = false
    @State private var confirmsClear = false
    @State private var searchText = ""
    @State private var searchMatches: [UpdateHistoryEntry] = []
    @State private var completedSearch: SearchRequest?

    private struct SearchRequest: Equatable, Sendable {
        let history: [UpdateHistoryEntry]
        let query: String
        let issuesOnly: Bool
    }

    private var scopedEntries: [UpdateHistoryEntry] {
        model.updateHistory.filter { !issuesOnly || $0.outcome == .failed || $0.outcome == .cachedAfterFailure }
    }

    private var searchRequest: SearchRequest {
        SearchRequest(history: model.updateHistory,
                      query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                      issuesOnly: issuesOnly)
    }

    var body: some View {
        let request = searchRequest
        let scope = scopedEntries
        let isSearching = !request.query.isEmpty && completedSearch != request
        let entries = request.query.isEmpty ? scope : searchMatches
        let lastEntryID = entries.last?.id

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("活动记录").font(.system(size: 32, weight: .bold))
                    Text("回看每一次更新、缓存回退与发布结果。")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            filterPicker
                            Spacer(minLength: 0)
                            clearButton(disabled: scope.isEmpty)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            filterPicker
                            clearButton(disabled: scope.isEmpty)
                        }
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("搜索模块、结果、详情或文件", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .onExitCommand { searchText = "" }
                            .accessibilityLabel("搜索活动记录")
                            .accessibilityIdentifier("activity.search")
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("清除活动搜索（Esc）")
                            .accessibilityLabel("清除活动搜索")
                            .accessibilityIdentifier("activity.clear-search")
                        }
                    }
                    Text(isSearching ? "正在搜索…" : request.query.isEmpty
                         ? "\(entries.count) 条记录"
                         : "\(entries.count) 条匹配 · 共 \(scope.count) 条记录")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityIdentifier("activity.result-count")
                }
                if isSearching && entries.isEmpty {
                    ProgressView("正在搜索活动记录…")
                        .frame(maxWidth: .infinity, minHeight: 260).detailCard()
                } else if entries.isEmpty {
                    emptyState(hasQuery: !request.query.isEmpty)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            ActivityHistoryRow(entry: entry, showsDetails: true)
                            if entry.id != lastEntryID { Divider().padding(.leading, 58) }
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
        .task(id: request) { await searchHistory(request) }
        .confirmationDialog(issuesOnly ? "清空 \(scope.count) 条关注记录？" : "清空全部 \(scope.count) 条活动记录？",
                            isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("清空记录", role: .destructive) { model.clearUpdateHistory(issuesOnly: issuesOnly) }
        } message: {
            Text((issuesOnly
                 ? "仅清除更新失败与缓存回退记录；其他活动记录、模块与发布文件都会保留。"
                 : "所有活动记录会被清除，模块和发布文件会保留。")
                 + (request.query.isEmpty ? "" : "清空范围包含搜索中未显示的记录。"))
        }
    }

    private var filterPicker: some View {
        Picker("显示记录", selection: $issuesOnly) {
            Text("全部活动").tag(false)
            Text("需要关注").tag(true)
        }
        .pickerStyle(.segmented).frame(width: 220)
        .accessibilityIdentifier("activity.filter")
    }

    private func clearButton(disabled: Bool) -> some View {
        Button(issuesOnly ? "清空关注记录" : "清空全部记录", systemImage: "trash") { confirmsClear = true }
            .buttonStyle(.borderless).disabled(disabled)
            .help(issuesOnly ? "清空全部更新失败与缓存回退记录" : "清空全部活动记录")
            .accessibilityIdentifier("activity.clear")
    }

    private func emptyState(hasQuery: Bool) -> some View {
        ContentUnavailableView {
            Label(hasQuery ? "没有匹配的活动" : issuesOnly ? "没有异常记录" : "还没有活动记录",
                  systemImage: hasQuery ? "magnifyingglass" : issuesOnly ? "checkmark.circle" : "clock")
        } description: {
            Text(hasQuery ? "试试模块名、更新结果、提交编号或发布文件名。"
                 : issuesOnly ? "更新失败和缓存回退会显示在这里。" : "更新模块或发布后，可以在这里查看结果。")
        } actions: {
            if hasQuery {
                Button("清除搜索") { searchText = "" }
            } else if issuesOnly {
                Button("查看全部活动") { issuesOnly = false }
            } else {
                Button("返回工作台") { model.selectedModuleID = AppModel.overviewSelectionID }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260).detailCard()
    }

    private func searchHistory(_ request: SearchRequest) async {
        guard !request.query.isEmpty else {
            searchMatches = []
            completedSearch = request
            return
        }
        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        let matches = await Task.detached(priority: .userInitiated) {
            request.history.filter { entry in
                guard !request.issuesOnly || entry.outcome == .failed || entry.outcome == .cachedAfterFailure else { return false }
                let values = [entry.moduleName, entry.outcome.title, entry.message, entry.commitSHA ?? ""]
                    + entry.publishedFiles + entry.deletedFiles
                return values.contains { $0.localizedStandardContains(request.query) }
            }
        }.value
        guard !Task.isCancelled else { return }
        searchMatches = matches
        completedSearch = request
    }
}

private struct ActivityPublishedFiles: View {
    let entry: UpdateHistoryEntry

    var body: some View {
        DisclosureGroup("文件变更：\(entry.publishedFiles.count) 个更新，\(entry.deletedFiles.count) 个删除") {
            VStack(alignment: .leading, spacing: 8) {
                if !entry.publishedFiles.isEmpty {
                    Label("上传 / 更新", systemImage: "arrow.up.doc")
                        .fontWeight(.medium)
                    Text(entry.publishedFiles.joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
                if !entry.deletedFiles.isEmpty {
                    Label("删除", systemImage: "trash")
                        .fontWeight(.medium)
                    Text(entry.deletedFiles.joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
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

    private var copyText: String {
        var lines = [entry.moduleName, entry.date.formatted(date: .long, time: .standard),
                     entry.outcome.title, entry.message]
        if let commitSHA = entry.commitSHA { lines.append("Commit: \(commitSHA)") }
        if !entry.publishedFiles.isEmpty { lines.append("上传 / 更新：\n" + entry.publishedFiles.joined(separator: "\n")) }
        if !entry.deletedFiles.isEmpty { lines.append("删除：\n" + entry.deletedFiles.joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 21)).foregroundStyle(color)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.moduleName).font(.system(size: 14, weight: .medium)).lineLimit(showsDetails ? 2 : 1)
                        .help(entry.moduleName)
                    Text(entry.outcome.title).font(.system(size: 12)).foregroundStyle(color).fixedSize()
                    Spacer(minLength: 8)
                    Text(entry.date, format: .dateTime.month(.twoDigits).day().hour().minute())
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize()
                        .help(entry.date.formatted(date: .long, time: .standard))
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
                    if entry.publishedChangeCount > 0 {
                        ActivityPublishedFiles(entry: entry)
                            .padding(.top, 4)
                    }
                    TextCopyButton(text: copyText, title: "拷贝记录")
                        .padding(.top, 4)
                        .help("拷贝 \(entry.moduleName) 的完整活动记录")
                        .accessibilityHint("包含日期、结果、详情与发布文件")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
