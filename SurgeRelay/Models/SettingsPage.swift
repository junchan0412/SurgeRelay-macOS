import Foundation

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, workspaces, publishing, credentials, webManagement, diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .workspaces: "工作区与模板"
        case .publishing: "发布"
        case .credentials: "凭据"
        case .webManagement: "Web 管理"
        case .diagnostics: "诊断"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .workspaces: "square.stack.3d.up"
        case .publishing: "square.and.arrow.up"
        case .credentials: "key"
        case .webManagement: "network"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}
