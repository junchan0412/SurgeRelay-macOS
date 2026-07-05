import Foundation

struct ConversionResult: Sendable {
    var content: String
    var requestURL: URL
    var assets: [GeneratedAsset] = []
}

struct GeneratedAsset: Sendable {
    var relativePath: String
    var data: Data
}

struct UpstreamUpdateResult: Sendable {
    var revision: String
    var changed: Bool
    var scripts: [String: Data]
    var sourceDescription: String
    var upstreamRevision: String
    var scriptHashes: [String: String]
}
