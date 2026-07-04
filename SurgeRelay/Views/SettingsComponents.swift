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
                VStack(alignment: .leading, spacing: 20) {
                    content()
                }
                .frame(width: contentWidth, alignment: .topLeading)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(width: geometry.size.width, alignment: .top)
            }
            .scrollIndicators(.visible)
            .background(Color(nsColor: .windowBackgroundColor))
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

struct SettingsWindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWhenReady(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWhenReady(nsView)
    }

    private func configureWhenReady(_ view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
        }
    }
}

enum SettingsTabMetrics {
    static let selectorWidth: CGFloat = 406
    static let selectorHeight: CGFloat = 40
    static let itemHeight: CGFloat = 30
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
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
