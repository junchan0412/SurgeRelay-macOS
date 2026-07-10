import SwiftUI

private struct ModuleDetailMetadataPill: Identifiable {
    let title: String
    let systemImage: String

    var id: String { "\(systemImage)|\(title)" }
}

private struct ModuleDetailSummaryMetric: Identifiable {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var id: String { "\(systemImage)|\(title)|\(value)" }
}

struct ModuleDetailSummaryHeader: View {
    let module: RelayModule
    let combinedModuleEnabled: Bool
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                ModuleIconView(module: module, size: 56)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(module.name)
                            .font(.title2.weight(.semibold))
                            .lineLimit(2)
                            .textSelection(.enabled)
                        metadataPillLayout
                    }
                    Spacer(minLength: 0)
                    Button("编辑模块…", systemImage: "pencil", action: onEdit)
                }
            }
            summaryMetricLayout
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.24), lineWidth: 0.5)
        }
    }

    private var metadataPills: [ModuleDetailMetadataPill] {
        var pills = [
            ModuleDetailMetadataPill(
                title: module.displayStorageLocationTitle,
                systemImage: module.displayStorageLocationSystemImage
            ),
            ModuleDetailMetadataPill(title: module.initialSource.title, systemImage: module.initialSource.systemImage)
        ]
        if !module.category.isEmpty {
            pills.append(ModuleDetailMetadataPill(title: module.category, systemImage: "tag"))
        }
        if module.scriptHubSubscription != nil {
            pills.append(ModuleDetailMetadataPill(title: "Script-Hub", systemImage: "link"))
        }
        let folder = ModuleOutputFolder.normalized(module.outputFolder)
        if folder != ModuleOutputFolder.root {
            pills.append(ModuleDetailMetadataPill(
                title: ModuleOutputFolder.displayTitle(for: folder),
                systemImage: "folder"
            ))
        }
        pills.append(ModuleDetailMetadataPill(
            title: module.publishesStandalone ? "独立发布" : "不发布独立模块",
            systemImage: module.publishesStandalone ? "checkmark.circle" : "pause.circle"
        ))
        if combinedModuleEnabled {
            pills.append(ModuleDetailMetadataPill(
                title: module.isEnabled ? "包含在总模块" : "不进总模块",
                systemImage: "square.stack.3d.up"
            ))
        }
        return pills
    }

    private var summaryMetrics: [ModuleDetailSummaryMetric] {
        [
            ModuleDetailSummaryMetric(
                title: "输出",
                value: summaryOutputValue,
                systemImage: module.publishesStandalone ? "doc.badge.gearshape" : "pause.circle",
                tint: .secondary
            ),
            ModuleDetailSummaryMetric(
                title: "更新",
                value: summaryUpdateValue,
                systemImage: module.state.systemImage,
                tint: module.state.tintColor
            ),
            ModuleDetailSummaryMetric(
                title: "图标",
                value: module.iconSourceDescription,
                systemImage: module.iconURL == nil ? "shippingbox" : "photo",
                tint: .secondary
            )
        ]
    }

    private var summaryOutputValue: String {
        guard module.publishesStandalone else { return "不发布独立模块" }
        return module.publishedRelativePath
    }

    private var summaryUpdateValue: String {
        if module.state == .failed, let failureSummary {
            return failureSummary
        }
        if let lastUpdatedAt = module.lastUpdatedAt {
            return lastUpdatedAt.formatted(date: .abbreviated, time: .shortened)
        }
        return module.state.title
    }

    private var failureSummary: String? {
        module.failureSummary
    }

    private var summaryMetricLayout: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 152), spacing: 8, alignment: .top)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(summaryMetrics) { metric in
                summaryMetric(metric)
            }
        }
    }

    private func summaryMetric(_ metric: ModuleDetailSummaryMetric) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: metric.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(metric.tint)
                .frame(width: 18, height: 18)
                .background(metric.tint.opacity(0.14), in: .rect(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                Text(metric.value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var metadataPillLayout: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                StatusPill(state: module.state, detail: failureSummary)
                ForEach(metadataPills) { pill in
                    metadataPill(pill.title, systemImage: pill.systemImage)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                StatusPill(state: module.state, detail: failureSummary)
                ForEach(metadataPills) { pill in
                    metadataPill(pill.title, systemImage: pill.systemImage)
                }
            }
        }
    }

    private func metadataPill(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.45), in: Capsule())
    }
}
