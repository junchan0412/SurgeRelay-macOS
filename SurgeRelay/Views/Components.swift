import AppKit
import SwiftUI

private struct ModuleIconCacheDirectoryKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

extension EnvironmentValues {
    var moduleIconCacheDirectory: URL? {
        get { self[ModuleIconCacheDirectoryKey.self] }
        set { self[ModuleIconCacheDirectoryKey.self] = newValue }
    }
}

struct ModuleIconView: View {
    @Environment(\.moduleIconCacheDirectory) private var cacheDirectory
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
            let previousImage = cachedImage
            hasLoadedCachedImage = false
            let url = ModuleIconStore.cachedURL(for: module.id, cacheDirectory: cacheDirectory)
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            guard !Task.isCancelled else { return }
            if let image = data.flatMap(NSImage.init(data:)) {
                cachedImage = image
            } else if previousImage == nil {
                cachedImage = nil
            }
            hasLoadedCachedImage = true
        }
    }

    private var cacheIdentity: String {
        "\(cacheDirectory?.path ?? "")|\(module.id.uuidString)|\(module.iconURL ?? "")|\(module.lastUpdatedAt?.timeIntervalSinceReferenceDate ?? 0)"
    }

    private func moduleImage(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .background(Design.Palette.elevated, in: iconShape)
            .clipShape(iconShape)
            .overlay {
                iconShape
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: Design.Separator.hairline)
            }
    }

    private var placeholder: some View {
        Image(systemName: placeholderSymbol)
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(Design.Palette.accent.opacity(0.85))
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [
                        Design.Palette.accent.opacity(0.14),
                        Design.Palette.accent.opacity(0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: iconShape
            )
            .overlay {
                iconShape
                    .strokeBorder(Design.Palette.accent.opacity(0.16), lineWidth: Design.Separator.hairline)
            }
    }

    private var placeholderSymbol: String {
        switch module.outputFormat {
        case .surge: "bolt.horizontal.fill"
        case .loon: "wind"
        case .egern: "shield.lefthalf.filled"
        case .quantumultX: "arrow.triangle.branch"
        case .shadowrocket: "paperplane.fill"
        case .stash: "shippingbox.fill"
        }
    }

    private var iconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * ModuleIconView.cornerRadiusRatio, style: .continuous)
    }

    static let cornerRadiusRatio: CGFloat = 0.24
}

struct StatusPill: View {
    let state: ModuleUpdateState
    var detail: String?

    private var color: Color {
        state.tintColor
    }

    var body: some View {
        HStack(spacing: 4) {
            if state == .updating {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: state.systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.11), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(color.opacity(0.22), lineWidth: Design.Separator.hairline)
        }
        .contentTransition(.opacity)
        .animation(.snappy(duration: 0.18), value: state)
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
    var semanticStatus: SemanticStatus {
        switch self {
        case .never: .neutral
        case .updating: .info
        case .current: .success
        case .failed: .error
        }
    }

    var tintColor: Color { semanticStatus.color }
}

extension RelayModule {
    var failureSummary: String? {
        guard let lastError else { return nil }
        let summary = UpdateFailureFormatter.summary(from: lastError)
        return summary.isEmpty ? nil : summary
    }

    var iconSourceDescription: String {
        if customIconURL != nil {
            return "自定义图标（写入输出）"
        }
        if iconURL != nil {
            return "来源图标"
        }
        return "默认图标"
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
            withAnimation(.snappy(duration: 0.18)) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.snappy(duration: 0.18)) { copied = false }
            }
        } label: {
            Label(copied ? copiedTitle : title,
                  systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(copied ? Design.Palette.success : nil)
        .foregroundStyle(copied ? Design.Palette.success : .primary)
        .disabled(text.isEmpty)
    }
}

struct SheetHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    @ViewBuilder var trailing: Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Design.Palette.accent)
                    .frame(width: 32, height: 32)
                    .background(Design.Palette.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Design.Palette.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Design.Separator.color)
                .frame(height: Design.Separator.hairline)
        }
    }
}

struct SheetActionFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Design.Spacing.md) {
            content
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Design.Palette.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Design.Separator.color)
                .frame(height: Design.Separator.hairline)
        }
    }
}

// MARK: - Native macOS Design System

enum Design {
    enum Palette {
        static let accent = adaptive(0x1A68E8, 0x5E9EFF)
        static let canvas = adaptive(0xF5F6F8, 0x18191C)
        static let surface = adaptive(0xFFFFFF, 0x222429)
        static let elevated = adaptive(0xEEF0F4, 0x2A2D34)
        static let codeBackground = adaptive(0xFAFBFC, 0x141518)
        static let codeGutter = adaptive(0xF1F3F6, 0x1A1C20)
        static let stroke = adaptive(0xE1E4EA, 0x31343C)
        static let rowDivider = adaptive(0xECEEF2, 0x2B2E36)
        static let icon = adaptive(0x646A73, 0x9CA3AF)
        static let success = adaptive(0x15803D, 0x4ADE80)
        static let warning = adaptive(0xB45309, 0xFBBF24)
        static let error = adaptive(0xDC2626, 0xF87171)

        static let nsCanvas = adaptiveNSColor(light: 0xF5F6F8, dark: 0x18191C)
        static let nsCodeBackground = adaptiveNSColor(light: 0xFAFBFC, dark: 0x141518)
        static let nsCodeGutter = adaptiveNSColor(light: 0xF1F3F6, dark: 0x1A1C20)
        static let nsStroke = adaptiveNSColor(light: 0xE1E4EA, dark: 0x31343C)
        static let nsAccent = adaptiveNSColor(light: 0x1A68E8, dark: 0x5E9EFF)

        private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
            Color(nsColor: adaptiveNSColor(light: light, dark: dark))
        }

        private static func adaptiveNSColor(light: UInt32, dark: UInt32) -> NSColor {
            NSColor(name: nil) { appearance in
                let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                    green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255,
                    alpha: 1
                )
            }
        }
    }

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 20
        static let xxxl: CGFloat = 28
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let card: CGFloat = 10
        static let large: CGFloat = 12
    }

    enum Separator {
        static let color = Design.Palette.stroke
        static let rowColor = Design.Palette.rowDivider
        static let opacity: Double = 1
        static let hairline: CGFloat = 1
    }

    enum Row {
        static let labelWidth: CGFloat = 112
        static let iconWidth: CGFloat = 18
        static let spacing: CGFloat = 10
        static let verticalPadding: CGFloat = 9
        static let separatorInset: CGFloat = 28
    }

    enum Card {
        static let padding: CGFloat = 16
        static let verticalPadding: CGFloat = 6
        static let radius: CGFloat = Radius.card
        static let strokeOpacity: Double = 1
    }
}

enum SemanticStatus {
    case neutral
    case info
    case success
    case warning
    case error

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .info: Design.Palette.accent
        case .success: Design.Palette.success
        case .warning: Design.Palette.warning
        case .error: Design.Palette.error
        }
    }
}

/// Renders grouped form rows with automatic inset separators *between* items
/// and never after the last item, matching macOS System Settings grouped cards.
struct GroupedCardStack<Content: View>: View {
    var dividerInset: CGFloat = Design.Row.separatorInset
    var horizontalPadding: CGFloat = Design.Card.padding
    var verticalPadding: CGFloat = Design.Card.verticalPadding
    @ViewBuilder var content: Content

    var body: some View {
        Group(subviews: content) { subviews in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(subviews.indices, id: \.self) { index in
                    subviews[index]
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if index < subviews.count - 1 {
                        Rectangle()
                            .fill(Design.Separator.rowColor)
                            .frame(height: 1)
                            .padding(.leading, dividerInset)
                    }
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailCard()
    }
}

extension View {
    /// Crisp native macOS grouped card surface with subtle border and elevation.
    func detailCard(radius: CGFloat = Design.Card.radius) -> some View {
        background(Design.Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Design.Palette.stroke, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.025), radius: 3, x: 0, y: 1)
    }

    /// Kept for explicit opt-in separators where needed.
    func rowSeparator(inset: CGFloat = Design.Row.separatorInset) -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(Design.Separator.rowColor)
                .frame(height: 1)
                .padding(.leading, inset)
        }
    }
}

struct MetadataPill: View {
    let text: String
    var systemImage: String?
    var tint: Color?

    init(_ text: String, systemImage: String? = nil, tint: Color? = nil) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint ?? .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            tint == nil ? Design.Palette.elevated : (tint ?? .primary).opacity(0.11),
            in: Capsule()
        )
        .overlay {
            Capsule().strokeBorder(
                tint == nil ? Design.Palette.stroke : (tint ?? .primary).opacity(0.22),
                lineWidth: 1
            )
        }
    }
}
