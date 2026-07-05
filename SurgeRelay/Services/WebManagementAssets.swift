import Foundation

enum WebManagementAssets {
    static let webContentSecurityPolicy = "default-src 'self'; img-src 'self' data: http: https:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"

    static func iconURL(for module: RelayModule) -> String? {
        if cachedIconData(for: module) != nil {
            return "/api/modules/\(module.id.uuidString.lowercased())/icon"
        }
        return module.iconURL
    }

    static func iconResponse(for module: RelayModule) -> WebHTTPResponse {
        guard let icon = cachedIconData(for: module) else {
            return .error(status: 404, message: "没有可用的模块图标。")
        }
        return WebHTTPResponse(
            contentType: icon.contentType,
            headers: ["Cache-Control": "private, max-age=3600"],
            body: icon.data
        )
    }

    static func imageContentType(_ data: Data) -> String? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if data.count >= 12,
           data.starts(with: [0x52, 0x49, 0x46, 0x46]),
           data.dropFirst(8).starts(with: [0x57, 0x45, 0x42, 0x50]) {
            return "image/webp"
        }
        if let prefix = String(data: data.prefix(512), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           prefix.hasPrefix("<svg") || (prefix.hasPrefix("<?xml") && prefix.contains("<svg")) {
            return "image/svg+xml"
        }
        return nil
    }

    static func assetResponse(for path: String) -> WebHTTPResponse {
        let relativePath = path == "/" ? "index.html" : String(path.drop(while: { $0 == "/" }))
        guard !relativePath.contains(".."), let resourceRoot = Bundle.main.resourceURL else {
            return .error(status: 404, message: "页面不存在。")
        }
        let bundledRoot = resourceRoot.appending(path: "WebResources", directoryHint: .isDirectory)
        let requestedURL = bundledRoot.appending(path: relativePath)
        let legacyFlattenedURL = resourceRoot.appending(path: URL(filePath: relativePath).lastPathComponent)
        let bundledIndexURL = bundledRoot.appending(path: "index.html")
        let legacyIndexURL = resourceRoot.appending(path: "index.html")
        let fileURL: URL
        if FileManager.default.fileExists(atPath: requestedURL.path) {
            fileURL = requestedURL
        } else if FileManager.default.fileExists(atPath: legacyFlattenedURL.path) {
            // Older project files copied WebResources into the bundle root.
            fileURL = legacyFlattenedURL
        } else if FileManager.default.fileExists(atPath: bundledIndexURL.path) {
            fileURL = bundledIndexURL
        } else {
            fileURL = legacyIndexURL
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return .error(status: 404, message: "Web 页面资源尚未安装。")
        }
        let contentType = switch fileURL.pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js": "text/javascript; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "webmanifest": "application/manifest+json; charset=utf-8"
        default: "application/octet-stream"
        }
        return WebHTTPResponse(
            contentType: contentType,
            headers: [
                "Cache-Control": "no-cache, must-revalidate",
                "Content-Security-Policy": webContentSecurityPolicy
            ],
            body: data
        )
    }

    private static func cachedIconData(for module: RelayModule) -> (data: Data, contentType: String)? {
        let url = ModuleIconStore.cachedURL(for: module.id)
        guard let data = try? Data(contentsOf: url),
              !data.isEmpty,
              let contentType = imageContentType(data) else {
            return nil
        }
        return (data, contentType)
    }
}
