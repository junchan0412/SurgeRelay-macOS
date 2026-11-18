import AppKit
import SwiftUI

struct SettingsForm<Content: View>: View {
    private let content: () -> Content
    private let contentMaxWidth: CGFloat = 680
    private let horizontalPadding: CGFloat = 22

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(
                360,
                min(contentMaxWidth, geometry.size.width - horizontalPadding * 2)
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content()
                }
                .frame(width: contentWidth, alignment: .topLeading)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(width: geometry.size.width, alignment: .top)
            }
            .scrollIndicators(.visible)
            .background(Design.Palette.canvas)
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    private let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            GroupedCardStack {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsInfoRow<Content: View>: View {
    let title: String
    let icon: String
    private let content: () -> Content

    init(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content
    }

    var body: some View {
        HStack(alignment: .center, spacing: Design.Row.spacing) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Design.Palette.icon)
                .frame(width: Design.Row.iconWidth, alignment: .center)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: Design.Row.labelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Design.Row.verticalPadding)
    }
}

struct SettingsControlRow<Content: View>: View {
    let title: String
    let icon: String
    private let content: () -> Content

    init(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content
    }

    var body: some View {
        SettingsInfoRow(title, icon: icon) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsCopyableValue: View {
    let value: String
    var monospaced = false
    var copyValue: String?

    init(value: String, monospaced: Bool = false, copyValue: String? = nil) {
        self.value = value
        self.monospaced = monospaced
        self.copyValue = copyValue
    }

    var body: some View {
        if let copyValue {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    SettingsValueText(value: value, monospaced: monospaced, fixedHorizontal: true)
                    Spacer(minLength: 4)
                    TextCopyButton(text: copyValue)
                        .layoutPriority(1)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingsValueText(value: value, monospaced: monospaced, fixedHorizontal: false)
                    TextCopyButton(text: copyValue)
                }
            }
        } else {
            SettingsValueText(value: value, monospaced: monospaced, fixedHorizontal: false)
        }
    }
}

struct SettingsValueText: View {
    let value: String
    var monospaced: Bool
    var fixedHorizontal: Bool

    init(value: String, monospaced: Bool = false, fixedHorizontal: Bool = false) {
        self.value = value
        self.monospaced = monospaced
        self.fixedHorizontal = fixedHorizontal
    }

    var body: some View {
        Text(value)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: fixedHorizontal, vertical: true)
            .frame(maxWidth: fixedHorizontal ? nil : .infinity, alignment: .leading)
    }
}

struct SettingsCopyableInfoRow: View {
    let title: String
    let value: String
    let icon: String
    var monospaced = false
    var copyValue: String?

    init(_ title: String, value: String, icon: String, monospaced: Bool = false, copyValue: String? = nil) {
        self.title = title
        self.value = value
        self.icon = icon
        self.monospaced = monospaced
        self.copyValue = copyValue
    }

    init(title: String, value: String, icon: String, monospaced: Bool = false, copyValue: String? = nil) {
        self.title = title
        self.value = value
        self.icon = icon
        self.monospaced = monospaced
        self.copyValue = copyValue
    }

    var body: some View {
        SettingsInfoRow(title, icon: icon) {
            SettingsCopyableValue(
                value: value,
                monospaced: monospaced,
                copyValue: copyValue
            )
        }
    }
}

struct SettingsPathSelectionControl: View {
    let path: String
    let chooseAction: () -> Void

    init(path: String, chooseAction: @escaping () -> Void) {
        self.path = path
        self.chooseAction = chooseAction
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                SettingsCopyableValue(value: path, monospaced: true, copyValue: path)
                Button("选择…", action: chooseAction)
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 6) {
                SettingsCopyableValue(value: path, monospaced: true, copyValue: path)
                Button("选择…", action: chooseAction)
                    .controlSize(.small)
            }
        }
    }
}

struct SettingsTextFieldRow: View {
    let title: String
    let icon: String
    let text: Binding<String>
    var prompt: String?

    init(_ title: String, icon: String, text: Binding<String>, prompt: String? = nil) {
        self.title = title
        self.icon = icon
        self.text = text
        self.prompt = prompt
    }

    var body: some View {
        SettingsControlRow(title, icon: icon) {
            if let prompt {
                TextField(title, text: text, prompt: Text(prompt))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(title, text: text)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

struct SettingsSecureFieldRow: View {
    let title: String
    let icon: String
    let text: Binding<String>

    init(_ title: String, icon: String, text: Binding<String>) {
        self.title = title
        self.icon = icon
        self.text = text
    }

    var body: some View {
        SettingsControlRow(title, icon: icon) {
            SecureField(title, text: text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let icon: String
    let isOn: Binding<Bool>

    init(_ title: String, icon: String, isOn: Binding<Bool>) {
        self.title = title
        self.icon = icon
        self.isOn = isOn
    }

    var body: some View {
        SettingsControlRow(title, icon: icon) {
            HStack {
                Spacer(minLength: 0)
                Toggle(title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }
}
