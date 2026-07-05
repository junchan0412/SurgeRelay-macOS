import Foundation

enum ModuleOutputFolder {
    static let root = ""

    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        guard !trimmed.isEmpty else { return root }

        let components = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return components.joined(separator: "/")
    }

    static func displayTitle(for folder: String) -> String {
        let normalized = normalized(folder)
        return normalized.isEmpty ? "根目录" : normalized
    }

    static func relativePath(
        fileName: String,
        folder: String,
        preservesExistingFileName: Bool = false
    ) -> String {
        let normalizedFolder = normalized(folder)
        let normalizedFileName = preservesExistingFileName
            ? FilenameSanitizer.existingSgmoduleName(from: fileName)
            : FilenameSanitizer.sgmoduleName(from: fileName)
        return [normalizedFolder, normalizedFileName].filter { !$0.isEmpty }.joined(separator: "/")
    }

    static func components(_ folder: String) -> [String] {
        normalized(folder).split(separator: "/").map(String.init)
    }

    static func options(from folders: [String], preserving selected: String? = nil) -> [String] {
        var values = Set([root])
        for folder in folders {
            values.insert(normalized(folder))
        }
        if let selected {
            values.insert(normalized(selected))
        }
        return values.sorted { lhs, rhs in
            if lhs.isEmpty { return true }
            if rhs.isEmpty { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}

struct ModuleOutputPathNotice: Equatable, Sendable {
    let message: String
    let isWarning: Bool
}

enum ModuleOutputPathInspector {
    static func notice(
        for relativePath: String,
        publishesStandalone: Bool,
        modules: [RelayModule],
        editingModuleID: UUID?,
        combinedFileName: String
    ) -> ModuleOutputPathNotice? {
        if !publishesStandalone {
            return ModuleOutputPathNotice(message: "未开启独立发布时，不会写出这个独立模块文件。", isWarning: false)
        }
        let normalizedPath = relativePath.lowercased()
        let combinedPath = ModuleOutputFolder.relativePath(
            fileName: combinedFileName,
            folder: ModuleOutputFolder.root
        ).lowercased()
        if normalizedPath == combinedPath {
            return ModuleOutputPathNotice(message: "该路径与总模块文件冲突，保存时会自动加编号避免覆盖。", isWarning: true)
        }
        if let owner = modules.first(where: { module in
            module.id != editingModuleID && module.publishedRelativePath.lowercased() == normalizedPath
        }) {
            return ModuleOutputPathNotice(message: "该路径已被“\(owner.name)”使用，保存时会自动加编号避免覆盖。", isWarning: true)
        }
        return nil
    }
}
