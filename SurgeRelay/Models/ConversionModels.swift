import Foundation

struct ConversionResult: Sendable {
    var content: String
    var requestURL: URL
    var assets: [GeneratedAsset] = []
    var stageMetrics: [StageMetric]? = nil
    var outputFormat: ModuleOutputFormat = .surge
}

struct GeneratedAsset: Sendable {
    var relativePath: String
    var data: Data
}

struct ScriptHubResourceError: LocalizedError, Sendable {
    var resourceURL: URL
    var underlying: any Error

    var errorDescription: String? {
        var components = URLComponents(url: resourceURL, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        return "脚本资源获取失败：\(components?.string ?? resourceURL.lastPathComponent)\n\(underlying.localizedDescription)"
    }
}

struct UpstreamUpdateResult: Sendable {
    var revision: String
    var changed: Bool
    var scripts: [String: Data]
    var sourceDescription: String
    var upstreamRevision: String
    var scriptHashes: [String: String]
}
