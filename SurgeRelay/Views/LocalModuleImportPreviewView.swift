import AppKit
import SwiftUI

struct LocalModuleImportPreviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedCandidateIDs: Set<String>
    @State private var candidates: [LocalModuleScanCandidate]
    private let skippedFiles: [LocalModuleScanSkippedFile]
    @State private var isImporting = false

    init(
        candidates: [LocalModuleScanCandidate],
        skippedFiles: [LocalModuleScanSkippedFile],
        selectedCandidateIDs: Binding<Set<String>>
    ) {
        _candidates = State(initialValue: candidates)
        self.skippedFiles = skippedFiles
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

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("导入本地模块").font(.title2.bold())
                Text("发现 \(candidates.count) 个可导入文件，跳过 \(skippedFiles.count) 个文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    importSummaryCard
                    if !candidates.isEmpty {
                        importSection("可导入") {
                            ForEach(candidates.indices, id: \.self) { index in
                                importCandidateCard(index: index)
                            }
                        }
                    }
                    if !skippedFiles.isEmpty {
                        skippedFilesSection
                    }
                    if candidates.isEmpty && skippedFiles.isEmpty {
                        ContentUnavailableView("没有可导入文件", systemImage: "folder")
                            .frame(maxWidth: .infinity, minHeight: 260)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.visible)
            .frame(minHeight: 300)

            Divider()

            HStack {
                Button("全选") {
                    selectedCandidateIDs = Set(candidates.map(\.id))
                }
                Button("全不选") {
                    selectedCandidateIDs.removeAll()
                }
                Spacer()
                Text(selectionSummary)
                    .font(.caption)
                    .foregroundStyle(hasInvalidSelection ? .red : .secondary)
                Button("取消", role: .cancel) { dismiss() }
                Button("导入") {
                    Task { await importSelectedCandidates() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCandidates.isEmpty || hasInvalidSelection || isImporting || model.isWorking)
            }
            .padding(20)
        }
        .frame(width: 780, height: 560)
    }

    private var importSummaryCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 52)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text("本地模块扫描")
                    .font(.title3.weight(.semibold))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { summaryPills }
                    VStack(alignment: .leading, spacing: 6) { summaryPills }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.24), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var summaryPills: some View {
        importPill("\(candidates.count) 个可导入", systemImage: "doc.text")
        if selfAuthoredCandidateCount > 0 {
            importPill("\(selfAuthoredCandidateCount) 个自写模块", systemImage: "pencil.and.outline")
        }
        if subscribedCandidateCount > 0 {
            importPill("\(subscribedCandidateCount) 个订阅来源", systemImage: "link")
        }
        importPill("\(selectedCandidates.count) 个已选择", systemImage: "checkmark.circle")
        if !skippedFiles.isEmpty {
            importPill("\(skippedFiles.count) 个跳过", systemImage: "exclamationmark.triangle", isWarning: true)
        }
    }

    private var selectionSummary: String {
        if hasInvalidSelection { return "已选择项需要填写名称" }
        guard !candidates.isEmpty else { return "没有可导入文件" }
        return "已选择 \(selectedCandidates.count) / \(candidates.count)"
    }

    private var skippedFilesSection: some View {
        importSection("已跳过") {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(skippedFiles) { file in
                        skippedFileRow(file)
                    }
                }
                .padding(.top, 6)
            } label: {
                Label("\(skippedFiles.count) 个文件", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func importCandidateCard(index: Int) -> some View {
        let candidate = candidates[index]
        let isSelected = selectedCandidateIDs.contains(candidate.id)
        return HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: selectionBinding(forID: candidate.id))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 14)

            Image(systemName: "doc.text")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isSelected ? .secondary : .tertiary)
                .frame(width: 34, height: 34)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名模块" : candidate.name)
                        .font(.headline)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                    Text("\(candidate.relationshipSummary) · \(candidate.relativePath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("来源")
                            .foregroundStyle(.secondary)
                        Text(candidate.sourceURL.removingPercentEncoding ?? candidate.sourceURL)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("名称")
                            .foregroundStyle(.secondary)
                        TextField("模块名称", text: textBinding(index: index, keyPath: \.name))
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("标签")
                            .foregroundStyle(.secondary)
                        TextField("Surge category", text: textBinding(index: index, keyPath: \.category))
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("文件夹")
                            .foregroundStyle(.secondary)
                        Picker("", selection: outputFolderBinding(index: index)) {
                            ForEach(outputFolderOptions(preserving: candidate.outputFolder), id: \.self) { folder in
                                Text(ModuleOutputFolder.displayTitle(for: folder)).tag(folder)
                            }
                        }
                        .labelsHidden()
                    }
                }
                .font(.callout)
                .disabled(!isSelected)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(isSelected ? 0.22 : 0.12), lineWidth: 0.5)
        }
        .opacity(isSelected ? 1 : 0.58)
    }

    private func skippedFileRow(_ file: LocalModuleScanSkippedFile) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.relativePath)
                    .font(.caption)
                    .textSelection(.enabled)
                Text(file.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func importPill(_ title: String, systemImage: String, isWarning: Bool = false) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(isWarning ? .orange : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.45), in: Capsule())
    }

    private func importSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func textBinding(index: Int, keyPath: WritableKeyPath<LocalModuleScanCandidate, String>) -> Binding<String> {
        Binding(
            get: { candidates[index][keyPath: keyPath] },
            set: { candidates[index][keyPath: keyPath] = $0 }
        )
    }

    private func outputFolderBinding(index: Int) -> Binding<String> {
        Binding(
            get: { ModuleOutputFolder.normalized(candidates[index].outputFolder) },
            set: { candidates[index].outputFolder = $0 }
        )
    }

    private func outputFolderOptions(preserving selected: String) -> [String] {
        ModuleOutputFolder.options(
            from: model.moduleOutputFolderOptions(
                storageLocation: .local,
                preserving: selected
            ) + candidates.map(\.outputFolder),
            preserving: selected
        )
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
