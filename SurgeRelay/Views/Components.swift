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
            // Keep the previous image visible while reloading so sidebar rows
            // do not flash placeholders during background status updates.
            let previousImage = cachedImage
            hasLoadedCachedImage = false
            let url = ModuleIconStore.cachedURL(for: module.id)
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
            .padding(.horizontal, Design.Spacing.md + 1)
            .padding(.vertical, Design.Spacing.xs + 1)
            .background(color.opacity(0.12), in: Capsule())
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
        HStack(spacing: Design.Spacing.lg) {
            content
        }
        .padding(.horizontal, Design.Spacing.xl)
        .padding(.vertical, Design.Spacing.md + 2)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Design.Separator.color.opacity(0.14))
                .frame(height: Design.Separator.hairline)
        }
    }
}

// MARK: - Design system

/// Shared design tokens for consistent spacing, radii, separators, and row
/// metrics across the app. Native counterpart to the token set that already
/// exists for the Web UI in `WebResources/app.css`, so the two front-ends share
/// one visual language. Previously every screen hardcoded its own values, which
/// left the Detail / Editor / Settings row families visibly out of sync.
enum Design {
    enum Palette {
        static let accent = adaptive(0x207566, 0x79CDBA)
        static let canvas = adaptive(0xF4F6F5, 0x181C1C)
        static let surface = adaptive(0xFFFFFF, 0x232827)
        static let stroke = adaptive(0xDDE3E0, 0x3C4441)
        static let success = adaptive(0x28734D, 0x81CCA0)
        static let warning = adaptive(0x9A5D13, 0xEDBE72)
        static let error = adaptive(0xB34036, 0xF59387)

        private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                               green: CGFloat((value >> 8) & 0xFF) / 255,
                               blue: CGFloat(value & 0xFF) / 255, alpha: 1)
            })
        }
    }

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 10
        static let card: CGFloat = 14
        static let large: CGFloat = 18
    }

    enum Separator {
        static let color = Color(nsColor: .separatorColor)
        static let opacity: Double = 0.16
        static let hairline: CGFloat = 0.5
    }

    /// Metrics shared by every label / value / control row (Detail, Editor,
    /// Settings) so the three families stay pixel-consistent.
    enum Row {
        static let labelWidth: CGFloat = 108
        static let iconWidth: CGFloat = 20
        static let spacing: CGFloat = 12
        static let verticalPadding: CGFloat = 6
        static let separatorInset: CGFloat = 32
    }

    enum Card {
        static let padding: CGFloat = 14
        static let verticalPadding: CGFloat = 10
        static let radius: CGFloat = Radius.card
        static let strokeOpacity: Double = 0.18
    }
}

/// A single semantic mapping for status colors, replacing the scattered inline
/// `.green` / `.orange` / `.red` used across the sidebar, detail, and settings.
enum SemanticStatus {
    case neutral
    case info
    case success
    case warning
    case error

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .info: .blue
        case .success: Design.Palette.success
        case .warning: Design.Palette.warning
        case .error: Design.Palette.error
        }
    }
}

extension View {
    /// Standard card chrome: material fill, continuous corners, hairline stroke.
    func detailCard(radius: CGFloat = Design.Card.radius) -> some View {
        background(Design.Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        Design.Palette.stroke,
                        lineWidth: Design.Separator.hairline
                    )
            }
    }

    /// Standard hairline row separator, inset to align under the value column.
    func rowSeparator(inset: CGFloat = Design.Row.separatorInset) -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(Design.Separator.color.opacity(Design.Separator.opacity))
                .frame(height: Design.Separator.hairline)
                .padding(.leading, inset)
        }
    }
}

/// Compact metadata capsule (icon + text) used to summarize a module's
/// attributes. Consolidates the four near-identical pill recipes that used to
/// live in the summary header, combined view, editor header, and import sheet.
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
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .foregroundStyle(tint ?? .secondary)
        .padding(.horizontal, Design.Spacing.md)
        .padding(.vertical, Design.Spacing.xs)
        .background((tint ?? Color.primary).opacity(tint == nil ? 0.06 : 0.12), in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                (tint ?? Color.primary).opacity(tint == nil ? 0.08 : 0.0),
                lineWidth: Design.Separator.hairline
            )
        }
    }
}
