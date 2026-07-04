import Foundation

@MainActor
struct ModulePreviewContentProvider {
    typealias ComponentExists = (UUID) async -> Bool
    typealias ComponentReader = (UUID) async throws -> String
    typealias ComponentWriter = (String, UUID) async throws -> Void
    typealias CombinedReader = () async throws -> Data
    typealias Materializer = (String, [String: String]) async -> String
    typealias ArgumentInfoReader = (String) async -> ModuleArgumentInfo
    typealias MetadataApplier = (String, String, String) async -> String

    let hasComponent: ComponentExists
    let readComponent: ComponentReader
    let readConvertedComponent: ComponentReader
    let writeComponent: ComponentWriter
    let readCombined: CombinedReader
    let materialize: Materializer
    let argumentInfo: ArgumentInfoReader
    let applyingModuleMetadata: MetadataApplier

    func previewContent(for module: RelayModule) async throws -> String {
        let content = try await componentContent(for: module)
        let materialized = await materialize(content, module.argumentOverrides)
        return await applyingModuleMetadata(module.name, module.category, materialized)
    }

    func moduleArgumentInfo(for module: RelayModule) async -> ModuleArgumentInfo {
        guard let content = try? await convertedComponentContent(for: module) else {
            return ModuleArgumentInfo()
        }
        return await argumentInfo(content)
    }

    func combinedPreviewContent(combinedModuleEnabled: Bool) async throws -> String {
        guard combinedModuleEnabled else {
            throw RelayError.invalidOutput("总模块功能已关闭。")
        }
        let data = try await readCombined()
        guard let content = String(data: data, encoding: .utf8) else {
            throw RelayError.invalidOutput("最终模块缓存不是有效的 UTF-8 文本。")
        }
        return await materialize(content, [:])
    }

    func convertedPreviewContent(for module: RelayModule) async throws -> String {
        let content = try await convertedComponentContent(for: module)
        return await materialize(content, module.argumentOverrides)
    }

    func componentContent(for module: RelayModule) async throws -> String {
        if await hasComponent(module.id) {
            return try await readComponent(module.id)
        }
        return try await recoverLocalSourceContent(for: module)
    }

    func convertedComponentContent(for module: RelayModule) async throws -> String {
        do {
            return try await readConvertedComponent(module.id)
        } catch {
            return try await recoverLocalSourceContent(for: module)
        }
    }

    private func recoverLocalSourceContent(for module: RelayModule) async throws -> String {
        guard let sourceURL = URL(string: module.sourceURL), sourceURL.isFileURL else {
            throw RelayError.invalidOutput("模块尚无转换缓存，请先更新该模块。")
        }
        guard module.sourceFormat.isNativeSurgeModule(for: sourceURL) else {
            throw RelayError.invalidOutput("本地来源尚无转换缓存，请先更新该模块。")
        }
        do {
            let data = try Data(contentsOf: sourceURL.standardizedFileURL)
            guard let content = String(data: data, encoding: .utf8) else {
                throw RelayError.invalidOutput("原始本地模块不是有效的 UTF-8 文本。")
            }
            let sanitized = SurgeModuleSanitizer.sanitize(content)
            try? await writeComponent(sanitized, module.id)
            return sanitized
        } catch let error as RelayError {
            throw error
        } catch {
            throw RelayError.invalidOutput("模块缓存缺失，且无法读取原始本地文件：\(error.localizedDescription)")
        }
    }
}
