import Foundation

/// 一个可以直接从磁盘刷新的本地 `file://` 模块来源。
struct LocalModuleSourceFile: Identifiable, Equatable, Sendable {
    var moduleID: UUID
    var url: URL
    /// 上一次同步时记录的来源内容哈希；为 nil 表示尚未记录过。
    var recordedContentHash: String?

    var id: UUID { moduleID }
}

/// 本地来源文件在磁盘上发生改动后的自动同步决策。
///
/// 这些规则和 `SourceRevisionService.check(_:)` 使用同一个判据（来源内容的
/// sha256），因此监听到的改动集合与随后 `updateAll(only:)` 的实际转换结果一致。
enum LocalSourceSyncPlanner {
    /// 单次扫描允许读取的来源文件大小上限，与来源检查保持一致。
    static let maximumSourceFileBytes = 20 * 1024 * 1024

    /// 可以从本地文件刷新的模块来源。
    ///
    /// 只有“转换前来源”本身就是本地文件的模块才在此列：带 Script-Hub
    /// `#SUBSCRIBED` 的本地模块其更新来源是远程地址，改动应由来源检查而不是
    /// 文件监听驱动。
    static func sourceFiles(in modules: [RelayModule]) -> [LocalModuleSourceFile] {
        modules.compactMap { module in
            guard let url = URL(string: module.updateSourceURL), url.isFileURL else { return nil }
            return LocalModuleSourceFile(
                moduleID: module.id,
                url: url.standardizedFileURL,
                recordedContentHash: module.sourceContentHash
            )
        }
    }

    /// 需要递归监听的目录：本地模块根目录，加上根目录之外的来源文件所在目录。
    ///
    /// FSEvents 默认递归监听，因此父目录已经覆盖的路径会被剔除，避免重复回调。
    static func watchedDirectories(
        modules: [RelayModule],
        localModuleDirectory: String
    ) -> [String] {
        var candidates: [String] = []
        let root = localModuleDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !root.isEmpty {
            candidates.append(URL(filePath: root, directoryHint: .isDirectory).standardizedFileURL.path)
        }
        for source in sourceFiles(in: modules) {
            candidates.append(source.url.deletingLastPathComponent().standardizedFileURL.path)
        }
        return minimalDirectorySet(candidates.map(canonicalDirectoryPath))
    }

    /// 目录的规范路径。
    ///
    /// FSEvents 只监听字面路径：经过符号链接的路径（例如 `/tmp`）注册后收不到任何
    /// 事件。`URL.resolvingSymlinksInPath()` 在 macOS 上会把 `/private/tmp` 反向
    /// 折叠回 `/tmp`，所以这里直接用 `realpath`；路径不存在时保留原值。
    static func canonicalDirectoryPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 去重并剔除被其他候选目录包含的路径。
    static func minimalDirectorySet(_ paths: [String]) -> [String] {
        let normalized = Set(paths.map { path -> String in
            path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }).filter { !$0.isEmpty }
        return normalized
            .filter { path in
                !normalized.contains { other in
                    other != path && path.hasPrefix(other == "/" ? "/" : other + "/")
                }
            }
            .sorted()
    }

    /// 读取来源文件的当前内容哈希。文件缺失、无法读取或体积超限时记为 nil。
    ///
    /// 缺失文件交给正常的更新流程报错，这里不把它当成“已改动”，避免 iCloud
    /// 尚未下载完成时触发一轮注定失败的转换。
    static func contentHashes(for sourceFiles: [LocalModuleSourceFile]) -> [UUID: String] {
        var hashes: [UUID: String] = [:]
        for source in sourceFiles {
            guard let data = try? Data(contentsOf: source.url),
                  !data.isEmpty,
                  data.count <= maximumSourceFileBytes else { continue }
            hashes[source.moduleID] = data.sha256String
        }
        return hashes
    }

    /// 磁盘内容与上次记录不一致、需要重新转换的模块。
    static func changedModuleIDs(
        sourceFiles: [LocalModuleSourceFile],
        currentHashes: [UUID: String]
    ) -> Set<UUID> {
        var changed: Set<UUID> = []
        for source in sourceFiles {
            guard let currentHash = currentHashes[source.moduleID] else { continue }
            if currentHash != source.recordedContentHash {
                changed.insert(source.moduleID)
            }
        }
        return changed
    }

    static func detectedStatus(changedCount: Int, firstModuleName: String?) -> String {
        guard changedCount > 0 else { return "本地模块文件没有变化" }
        if changedCount == 1, let firstModuleName {
            return "检测到 \(firstModuleName) 的本地文件已修改，正在同步…"
        }
        return "检测到 \(changedCount) 个本地模块文件已修改，正在同步…"
    }
}
