import Foundation

enum GitHubRepositoryPath {
    static func validateUniqueRepositoryPaths(_ files: [PublishFile], settings: GitHubSettings) throws {
        var paths = Set<String>()
        for file in files {
            let path = repositoryPath(for: file.name, settings: settings)
            guard paths.insert(path).inserted else {
                throw RelayError.invalidOutput("GitHub 发布列表包含重复路径：\(path)")
            }
        }
    }

    static func repositoryPath(for fileName: String, settings: GitHubSettings) -> String {
        let directory = repositoryDirectory(settings: settings)
        return [directory, fileName].filter { !$0.isEmpty }.joined(separator: "/")
    }

    static func repositoryDirectory(settings: GitHubSettings) -> String {
        settings.directory
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    static func blobsByRepositoryPath(from tree: [GitHubAPI.TreeItem]) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: tree.compactMap { item in
                guard item.type == "blob", let sha = item.sha else { return nil }
                return (item.path, sha)
            }
        )
    }

    static func moduleDirectories(from tree: [GitHubAPI.TreeItem], settings: GitHubSettings) -> [String] {
        var folders = Set<String>()
        for item in tree {
            guard let relativePath = relativeModulePath(for: item.path, settings: settings) else { continue }
            let components = relativePath.split(separator: "/").map(String.init)
            guard components.first?.lowercased() != "assets" else { continue }
            let directoryComponents = item.type == "tree" ? components : Array(components.dropLast())
            guard !directoryComponents.isEmpty else { continue }
            for index in 1...directoryComponents.count {
                let folder = ModuleOutputFolder.normalized(directoryComponents.prefix(index).joined(separator: "/"))
                if !folder.isEmpty { folders.insert(folder) }
            }
        }
        return folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func relativeModulePath(for repositoryPath: String, settings: GitHubSettings) -> String? {
        let directory = repositoryDirectory(settings: settings)
        guard !directory.isEmpty else { return repositoryPath }
        guard repositoryPath.hasPrefix(directory + "/") else { return nil }
        let relative = String(repositoryPath.dropFirst(directory.count + 1))
        return relative.isEmpty ? nil : relative
    }

    static func commitMessage(changedCount: Int, deletedCount: Int) -> String {
        switch (changedCount, deletedCount) {
        case (_, 0):
            "Update \(changedCount) files via Surge Relay"
        case (0, _):
            "Remove \(deletedCount) stale files via Surge Relay"
        default:
            "Update \(changedCount) files and remove \(deletedCount) stale files via Surge Relay"
        }
    }

    static func encodedRepositoryPath(for fileName: String, settings: GitHubSettings) -> String {
        repositoryPath(for: fileName, settings: settings)
            .split(separator: "/")
            .map { encodedPathComponent(String($0)) }
            .joined(separator: "/")
    }

    static func encodedPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
