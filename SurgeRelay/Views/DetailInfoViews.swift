import AppKit
import SwiftUI

struct DetailInfoSection<Content: View>: View {
    let title: String
    var trailingActionTitle: String? = nil
    var trailingAction: (() -> Void)? = nil
    private let content: () -> Content

    init(
        _ title: String,
        trailingActionTitle: String? = nil,
        trailingAction: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.trailingActionTitle = trailingActionTitle
        self.trailingAction = trailingAction
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                Spacer(minLength: 8)
                if let trailingActionTitle, let trailingAction {
                    Button(trailingActionTitle, action: trailingAction)
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            GroupedCardStack {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailInfoRow: View {
    let label: String
    let value: String
    let icon: String
    var monospaced = false
    var copyValue: String?
    var trailingActionTitle: String? = nil
    var trailingSystemImage: String? = nil
    var trailingAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: Design.Row.spacing) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Design.Palette.icon)
                .frame(width: Design.Row.iconWidth, alignment: .center)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: Design.Row.labelWidth, alignment: .leading)
            valueContent
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Design.Row.verticalPadding)
    }

    @ViewBuilder
    private var valueContent: some View {
        if copyValue != nil || trailingAction != nil {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    valueText(fixedHorizontal: true)
                    Spacer(minLength: 4)
                    actionButtons
                }
                VStack(alignment: .leading, spacing: 6) {
                    valueText(fixedHorizontal: false)
                    HStack(spacing: 6) { actionButtons }
                }
            }
        } else {
            valueText(fixedHorizontal: false)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let trailingAction, let trailingActionTitle {
            Button(action: trailingAction) {
                if let trailingSystemImage {
                    Label(trailingActionTitle, systemImage: trailingSystemImage)
                        .font(.system(size: 11, weight: .medium))
                } else {
                    Text(trailingActionTitle)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        if let copyValue {
            TextCopyButton(text: copyValue)
                .layoutPriority(1)
        }
    }

    private func valueText(fixedHorizontal: Bool) -> some View {
        Text(value)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(fixedHorizontal ? 1 : (monospaced ? 3 : nil))
            .truncationMode(.middle)
            .fixedSize(horizontal: fixedHorizontal, vertical: true)
            .frame(maxWidth: fixedHorizontal ? nil : .infinity, alignment: .leading)
    }
}

struct DetailControlRow<Content: View>: View {
    let label: String
    let icon: String
    var subtitle: String? = nil
    private let content: () -> Content

    init(
        label: String,
        icon: String,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.icon = icon
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        HStack(alignment: .center, spacing: Design.Row.spacing) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Design.Palette.icon)
                .frame(width: Design.Row.iconWidth, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: Design.Row.labelWidth, alignment: .leading)
            Spacer(minLength: 8)
            content()
        }
        .padding(.vertical, Design.Row.verticalPadding)
    }
}
