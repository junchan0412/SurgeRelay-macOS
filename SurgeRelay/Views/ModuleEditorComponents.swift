import SwiftUI

struct ModuleEditorPreviewCard: View {
    let title: String
    let subtitle: String
    let publishedRelativePath: String
    let iconURL: URL?
    let iconIsInvalid: Bool
    let iconSourceTitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            DraftModuleIconPreview(
                url: iconURL,
                size: 54,
                isInvalid: iconIsInvalid
            )
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(publishedRelativePath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Label(iconSourceTitle, systemImage: iconIsInvalid ? "exclamationmark.triangle" : "photo")
                    .font(.caption)
                    .foregroundStyle(iconIsInvalid ? .orange : .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 0.5)
        }
    }
}

struct ModuleEditorSection<Content: View>: View {
    let title: String
    private let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.headline)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 11) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.18), lineWidth: 0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ModuleEditorInfoRow<Content: View>: View {
    let title: String
    let icon: String
    private let content: () -> Content

    init(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            Text(title)
                .font(.callout.weight(.medium))
                .frame(width: 108, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.14))
                .frame(height: 0.5)
                .padding(.leading, 30)
        }
    }
}

struct ModuleEditorControlRow<Content: View>: View {
    let title: String
    let icon: String
    private let content: () -> Content

    init(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content
    }

    var body: some View {
        ModuleEditorInfoRow(title, icon: icon) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ModuleEditorTextFieldRow: View {
    let title: String
    let icon: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        ModuleEditorControlRow(title, icon: icon) {
            TextField(title, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct ModuleEditorToggleRow: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        ModuleEditorControlRow(title, icon: icon) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

struct ModuleEditorOutputPathRow: View {
    let relativePath: String
    let notice: ModuleOutputPathNotice?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    outputPathText(fixedHorizontal: true)
                    TextCopyButton(text: relativePath)
                        .layoutPriority(1)
                }
                VStack(alignment: .leading, spacing: 8) {
                    outputPathText(fixedHorizontal: false)
                    TextCopyButton(text: relativePath)
                }
            }
            if let notice {
                Label(notice.message, systemImage: notice.isWarning ? "exclamationmark.triangle" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(notice.isWarning ? .orange : .secondary)
            }
        }
    }

    private func outputPathText(fixedHorizontal: Bool) -> some View {
        Text(relativePath)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: fixedHorizontal, vertical: true)
            .frame(maxWidth: fixedHorizontal ? nil : .infinity, alignment: .leading)
    }
}

struct ModuleEditorFolderPicker: View {
    @Binding var outputFolder: String
    let folders: [String]
    let onCreateFolder: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { ModuleOutputFolder.normalized(outputFolder) },
                set: { outputFolder = $0 }
            )) {
                ForEach(folders, id: \.self) { folder in
                    Text(ModuleOutputFolder.displayTitle(for: folder)).tag(folder)
                }
            }
            .labelsHidden()

            Button(action: onCreateFolder) {
                Image(systemName: "folder.badge.plus")
            }
            .help("新建存放文件夹")
        }
    }
}

struct ModuleEditorStorageLocationPicker: View {
    @Binding var storageLocation: ModuleStorageLocation

    var body: some View {
        Picker("模块存放", selection: $storageLocation) {
            ForEach(ModuleStorageLocation.allCases) { location in
                Label(location.title, systemImage: location.systemImage)
                    .tag(location)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 260, alignment: .leading)
    }
}

struct DraftModuleIconPreview: View {
    let url: URL?
    let size: CGFloat
    var isInvalid = false

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        previewContainer(
                            placeholder.overlay { ProgressView().controlSize(.mini) },
                            isWarning: isInvalid
                        )
                    case let .success(image):
                        previewContainer(image.resizable().scaledToFill(), isWarning: isInvalid)
                    case .failure:
                        previewContainer(warningPlaceholder, isWarning: true)
                    @unknown default:
                        previewContainer(placeholder, isWarning: isInvalid)
                    }
                }
            } else {
                previewContainer(placeholder, isWarning: isInvalid)
            }
        }
        .accessibilityHidden(true)
    }

    private func previewContainer<Content: View>(_ content: Content, isWarning: Bool) -> some View {
        content
        .frame(width: size, height: size)
        .background(.quaternary.opacity(0.35), in: iconShape)
        .clipShape(iconShape)
        .overlay {
            iconShape
                .strokeBorder(
                    isWarning ? Color.orange.opacity(0.72) : Color(nsColor: .separatorColor).opacity(0.45),
                    lineWidth: isWarning ? 1 : 0.5
                )
        }
    }

    private var placeholder: some View {
        Image(systemName: isInvalid ? "exclamationmark.triangle" : "photo")
            .font(.system(size: size * 0.45))
            .foregroundStyle(isInvalid ? .orange : .secondary)
            .frame(width: size, height: size)
    }

    private var warningPlaceholder: some View {
        Image(systemName: "exclamationmark.triangle")
            .font(.system(size: size * 0.45))
            .foregroundStyle(.orange)
            .frame(width: size, height: size)
    }

    private var iconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * ModuleIconView.cornerRadiusRatio, style: .continuous)
    }
}
