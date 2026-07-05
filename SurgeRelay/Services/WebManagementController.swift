import Foundation

enum WebManagementController {
    static func accessModeTitle(settings: AppSettings) -> String {
        settings.webServerAllowRemoteAccess ? "局域网" : "仅本机"
    }

    static func host(settings: AppSettings, processInfo: ProcessInfo = .processInfo) -> String {
        guard settings.webServerAllowRemoteAccess else { return "127.0.0.1" }
        var host = processInfo.hostName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if !host.contains(".") { host += ".local" }
        return host
    }

    static func url(settings: AppSettings, accessToken: String, includingToken: Bool) -> URL? {
        guard settings.webServerEnabled else { return nil }
        return WebManagementURLFactory.url(
            host: host(settings: settings),
            port: settings.webServerPort,
            accessToken: accessToken,
            includingToken: includingToken
        )
    }
}
