import Foundation
import CryptoKit

actor ModuleProcessingWorker {
    func materialize(_ content: String, overrides: [String: String]) -> String {
        ModuleArgumentProcessor.materialize(content, overrides: overrides)
    }

    func argumentInfo(in content: String) -> ModuleArgumentInfo {
        ModuleArgumentProcessor.info(in: content)
    }

    func applyingDisplayName(_ name: String, to content: String) -> String {
        ModuleMetadataParser.applyingDisplayName(name, to: content)
    }

    func applyingModuleMetadata(
        name: String,
        category: String,
        desc: String = "",
        iconURL: String? = nil,
        to content: String
    ) -> String {
        ModuleMetadataParser.applyingModuleMetadata(
            name: name,
            category: category,
            desc: desc,
            iconURL: iconURL,
            to: content
        )
    }

    func iconURL(in content: String, relativeTo source: String?) -> URL? {
        ModuleMetadataParser.iconURL(in: content, relativeTo: source)
    }

    func contentFingerprint(of content: String, assets: [GeneratedAsset]) -> String {
        var hash = SHA256()
        hash.update(data: Data(content.utf8))
        for asset in assets.sorted(by: { $0.relativePath < $1.relativePath }) {
            hash.update(data: Data([0]))
            hash.update(data: Data(asset.relativePath.utf8))
            hash.update(data: Data([0]))
            hash.update(data: asset.data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

}
