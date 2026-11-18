import AppKit
import SwiftUI

struct LocalModuleImportPreviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedCandidateIDs: Set<String>
    @State private var candidates: [LocalModuleScanCandidate]
    @State private var skippedFiles: [LocalModuleScanSkippedFile]
    @State private var isImporting = false
    @State private var isRefreshing = false
    @State private var refreshError: String?
    @State private var editedFields: [String: Set<WritableKeyPath<LocalModuleScanCandidate, String>>] = [:]
    @State private var sourceWatcher = LocalSourceWatcher()

    init(
        candidates: [LocalModuleScanCandidate],
        skippedFiles: [LocalModuleScanSkippedFile],
        selectedCandidateIDs: Binding<Set<String>>
    ) {
        _candidates = State(initialValue: candidates)
        _skippedFiles = State(initialValue: skippedFiles)
        _selectedCandidateIDs = selectedCandidateIDs
    }

    private var selectedCandidates: [LocalModuleScanCandidate] {
        candidates.filter { selectedCandidateIDs.contains($0.id) }
    }

    private var hasInvalidSelection: Bool {
        selectedCandidates.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var selfAuthoredCandidateCount: Int {
        candidates.filter { $0.initialSource == .selfAuthored }.count
    }

    private var subscribedCandidateCount: Int {
        candidates.filter { $0.initialSource.isSubscribed }.count
    }

    private var remoteCandidateCount: Int {
        candidates.filter { $0.initialSource.isRemote }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                "导入本地模块",
                subtitle: refreshError ?? "发现 \(candidates.count) 个可导入文件，跳过 \(skippedFiles.count) 个文件；已有本地文件位置保持不变。",
                systemImage: "folder.badge.plus"
            ) {
                Button(isRefreshing ? "刷新中…" : "刷新") {
                    Task { await refreshCandidates() }
                }
                .controlSize(.small)
                .disabled(isRefreshing || isImporting || model.isWorking)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    importSummaryStrip
                    if !candidates.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("可导入模块")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)
                            ForEach(candidates) { candidate in
                                importCandidateCard(candidate: candidate)
                            }
                        }
                    }
                    if !skippedFiles.isEmpty {
                        skippedFilesSection
                    }
                    if candidates.isEmpty && skippedFiles.isEmpty {
                        ContentUnavailableView("没有可导入文件", systemImage: "folder")
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.visible)
            .background(Design.Palette.canvas)

            SheetActionFooter {
                Button("全选") {
                    selectedCandidateIDs = Set(candidates.map(\.id))
                }
                .controlSize(.small)
                Button("全不选") {
                    selectedCandidateIDs.removeAll()
                }
                .controlSize(.small)
                Spacer()
                Text(selectionSummary)
                    .font(.caption)
                    .foregroundStyle(hasInvalidSelection ? Design.Palette.error : .secondary)
                Button("取消", role: .cancel) { dismiss() }
                    .disabled(isImporting)
                Button(isImporting ? "正在导入…" : "导入所选") {
                    Task { await importSelectedCandidates() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCandidates.isEmpty || hasInvalidSelection || isImporting || model.isWorking)
            }
        }
        .frame(width: 760, height: 560)
        .task(id: directoryWatchKey) {
            let paths = LocalSourceSyncPlanner.minimalDirectorySet(ModuleOutputFormat.allCases.compactMap { format in
                let storage = model.settings.localStorage(for: format)
                guard storage.isEnabled, !storage.directory.isEmpty else { return nil }
                return LocalSourceSyncPlanner.canonicalDirectoryPath(storage.directory)
            })
            let events = sourceWatcher.start(paths: paths)
            await refreshCandidates()
            if let events {
                for await _ in events {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    await refreshCandidates()
                }
            }
        }
        .onChange(of: model.isWorking) { _, isWorking in
            if !isWorking { Task { await refreshCandidates() } }
        }
        .onDisappear { sourceWatcher.stop() }
    }

    private var importSummaryStrip: some View {
        HStack(spacing: 8) {
            MetadataPill("\(candidates.count) 个可导入", systemImage: "doc.text", tint: Design.Palette.accent)
            if selfAuthoredCandidateCount > 0 {
                MetadataPill("\(selfAuthoredCandidateCount) 个自写", systemImage: "pencil.and.outline")
            }
            if subscribedCandidateCount > 0 {
                MetadataPill("\(subscribedCandidateCount) 个订阅", systemImage: "link")
            }
            if remoteCandidateCount > 0 {
                MetadataPill("\(remoteCandidateCount) 个远程", systemImage: "globe")
            }
            MetadataPill("\(selectedCandidates.count) 个已选", systemImage: "checkmark.circle", tint: Design.Palette.success)
            if !skippedFiles.isEmpty {
                MetadataPill("\(skippedFiles.count) 个跳过", systemImage: "exclamationmark.triangle", tint: Design.Palette.warning)
            }
            Spacer(minLength: 0)
        }
    }

    private var selectionSummary: String {
        if hasInvalidSelection { return "已选择项需要填写名称" }
        guard !candidates.isEmpty else { return "没有可导入文件" }
        return "已选择 \(selectedCandidates.count) / \(candidates.count)"
    }

    private var skippedFilesSection: some View {
        DetailInfoSection("已跳过（\(skippedFiles.count)）") {
            DisclosureGroup("查看跳过原因") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(skippedFiles) { file in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.relativePath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                Text(file.reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                .padding(.top, 6)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
        }
    }

    private func importCandidateCard(candidate: LocalModuleScanCandidate) -> some View {
        let isSelected = selectedCandidateIDs.contains(candidate.id)
        return HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: selectionBinding(forID: candidate.id))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名模块" : candidate.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                    MetadataPill(candidate.relationshipSummary)
                    Spacer()
                    Text(candidate.localStorageRelativePath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Text("名称")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextField("模块名称", text: textBinding(forID: candidate.id, keyPath: \.name))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                    }
                    HStack(spacing: 6) {
                        Text("标签")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextField("可选分类", text: textBinding(forID: candidate.id, keyPath: \.category))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(width: 150)
                    }
                }
                .disabled(!isSelected)

                Text(candidate.sourceURL.removingPercentEncoding ?? candidate.sourceURL)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Palette.surface, in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .strokeBorder(isSelected ? Design.Palette.accent.opacity(0.45) : Design.Palette.stroke, lineWidth: 1)
        }
        .opacity(isSelected ? 1 : 0.62)
    }

    private func selectionBinding(forID id: String) -> Binding<Bool> {
        Binding(
            get: { selectedCandidateIDs.contains(id) },
            set: { isSelected in
                if isSelected {
                    selectedCandidateIDs.insert(id)
                } else {
                    selectedCandidateIDs.remove(id)
                }
            }
        )
    }

    private func textBinding(forID id: String, keyPath: WritableKeyPath<LocalModuleScanCandidate, String>) -> Binding<String> {
        Binding(
            get: { candidates.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: {
                guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
                editedFields[id, default: []].insert(keyPath)
                candidates[index][keyPath: keyPath] = $0
            }
        )
    }

    private var directoryWatchKey: String {
        ModuleOutputFormat.allCases.map { format in
            let storage = model.settings.localStorage(for: format)
            return "\(format.rawValue):\(storage.isEnabled):\(storage.directory)"
        }.joined(separator: "|") + ":\(model.moduleRevision)"
    }

    private func refreshCandidates() async {
        guard !isImporting, !model.isWorking else { return }
        let watchKey = directoryWatchKey
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let report = try await model.scanExistingLocalModules(reportsProgress: false)
            guard !Task.isCancelled, watchKey == directoryWatchKey else { return }
            let previous = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
            candidates = report.candidates.map { scanned in
                var candidate = scanned
                if let fields = editedFields[candidate.id], let draft = previous[candidate.id],
                   draft.rootDirectoryPath == candidate.rootDirectoryPath {
                    for keyPath in fields { candidate[keyPath: keyPath] = draft[keyPath: keyPath] }
                }
                return candidate
            }
            let retainedIDs = Set(candidates.compactMap { candidate in
                previous[candidate.id]?.rootDirectoryPath == candidate.rootDirectoryPath ? candidate.id : nil
            })
            selectedCandidateIDs.formIntersection(retainedIDs)
            editedFields = editedFields.filter { retainedIDs.contains($0.key) }
            skippedFiles = report.skippedFiles
            refreshError = nil
        } catch is CancellationError {
        } catch {
            refreshError = "刷新失败：\(error.localizedDescription)"
        }
    }

    private func importSelectedCandidates() async {
        let selected = selectedCandidates
        guard !selected.isEmpty, !hasInvalidSelection else { return }
        isImporting = true
        await model.importLocalModules(selected)
        isImporting = false
        dismiss()
    }
}
