import AppKit
import SwiftUI

struct ModuleIconView: View {
    let module: RelayModule
    var size: CGFloat = 28
    @State private var cachedImage: NSImage?
    @State private var hasLoadedCachedImage = false

    var body: some View {
        Group {
            if let image = cachedImage {
                moduleImage(Image(nsImage: image))
            } else if hasLoadedCachedImage,
                      let iconURL = module.iconURL.flatMap(URL.init(string:)) {
                AsyncImage(url: iconURL) { phase in
                    switch phase {
                    case .empty:
                        placeholder
                            .overlay { ProgressView().controlSize(.mini) }
                    case let .success(image):
                        moduleImage(image)
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: cacheIdentity) {
            cachedImage = nil
            hasLoadedCachedImage = false
            let url = ModuleIconStore.cachedURL(for: module.id)
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            guard !Task.isCancelled else { return }
            cachedImage = data.flatMap(NSImage.init(data:))
            hasLoadedCachedImage = true
        }
    }

    private var cacheIdentity: String {
        "\(module.id.uuidString)|\(module.iconURL ?? "")|\(module.lastUpdatedAt?.timeIntervalSinceReferenceDate ?? 0)"
    }

    private func moduleImage(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .background(.quaternary.opacity(0.35), in: iconShape)
            .clipShape(iconShape)
            .overlay {
                iconShape
                    .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
            }
    }

    private var placeholder: some View {
        Image(systemName: "shippingbox")
            .font(.system(size: size * 0.48, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.quaternary.opacity(0.55), in: iconShape)
    }

    private var iconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * ModuleIconView.cornerRadiusRatio, style: .continuous)
    }

    /// Continuous-corner ratio calibrated so the transparent corner matches the
    /// app icon artwork (SummaryIcon): at this ratio a `.continuous` rounded rect
    /// reproduces the icon's measured corner extent (316/1024 of the side).
    static let cornerRadiusRatio: CGFloat = 0.26
}

struct RelayCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

struct StatusPill: View {
    let state: ModuleUpdateState
    var detail: String?

    private var color: Color {
        state.tintColor
    }

    var body: some View {
        Label(title, systemImage: state.systemImage)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .help(title)
    }

    private var title: String {
        guard state == .failed,
              let detail,
              !detail.isEmpty else {
            return state.title
        }
        return "\(state.title)：\(detail)"
    }
}

extension ModuleUpdateState {
    var tintColor: Color {
        switch self {
        case .never: .secondary
        case .updating: .blue
        case .current: .green
        case .failed: .red
        }
    }
}

extension RelayModule {
    var failureSummary: String? {
        guard let lastError else { return nil }
        let summary = UpdateFailureFormatter.summary(from: lastError)
        return summary.isEmpty ? nil : summary
    }

    var iconSourceDescription: String {
        if customIconURL != nil {
            return "自定义图标（仅展示）"
        }
        if iconURL != nil {
            return "来源元数据（仅展示）"
        }
        return "默认图标"
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        RelayCard {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.14), in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(value).font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct URLCopyButton: View {
    let url: URL

    var body: some View {
        TextCopyButton(text: url.absoluteString, title: "拷贝地址")
    }
}

struct TextCopyButton: View {
    let text: String
    var title = "拷贝"
    var copiedTitle = "已拷贝"
    @State private var copied = false

    var body: some View {
        Button {
            guard !copied else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.snappy) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            Label(copied ? copiedTitle : title,
                  systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(copied ? .green : .accentColor)
        .disabled(text.isEmpty)
    }
}

struct SheetActionFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.14))
                .frame(height: 0.5)
        }
    }
}
