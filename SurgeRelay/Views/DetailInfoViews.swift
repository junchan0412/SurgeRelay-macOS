import AppKit
import SwiftUI

struct DetailInfoSection<Content: View>: View {
    let title: String
    private let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.md + 2) {
            Text(title)
                .font(.headline)
                .padding(.leading, Design.Spacing.xxs)
            VStack(alignment: .leading, spacing: Design.Spacing.md) {
                content()
            }
            .padding(.horizontal, Design.Card.padding)
            .padding(.vertical, Design.Card.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .detailCard()
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

    var body: some View {
        HStack(alignment: .top, spacing: Design.Row.spacing) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: Design.Row.iconWidth, alignment: .center)
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: Design.Row.labelWidth, alignment: .leading)
            valueContent
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Design.Row.verticalPadding)
        .rowSeparator()
    }

    @ViewBuilder
    private var valueContent: some View {
        if let copyValue {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Design.Spacing.md + 2) {
                    valueText(fixedHorizontal: true)
                    TextCopyButton(text: copyValue)
                        .layoutPriority(1)
                }
                VStack(alignment: .leading, spacing: 8) {
                    valueText(fixedHorizontal: false)
                    TextCopyButton(text: copyValue)
                }
            }
        } else {
            valueText(fixedHorizontal: false)
        }
    }

    private func valueText(fixedHorizontal: Bool) -> some View {
        Text(value)
            .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
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
    private let content: () -> Content

    init(label: String, icon: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.icon = icon
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: Design.Row.spacing) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: Design.Row.iconWidth, alignment: .center)
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: Design.Row.labelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Design.Row.verticalPadding)
        .rowSeparator()
    }
}
