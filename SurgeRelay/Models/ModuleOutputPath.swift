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

struct LocalModuleOutputSnapshot: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case present
        case missing
        case unavailable(String)
    }

    var path: String
    var state: State
    var hasManagementHeader = false

    var message: String {
        switch state {
        case .present: "本地文件存在"
        case .missing: "尚未写入本地文件"
        case .unavailable(let message): message
        }
    }

    var systemImage: String {
        switch state {
        case .present: "doc.badge.checkmark"
        case .missing: "doc.badge.plus"
        case .unavailable: "exclamationmark.triangle"
        }
    }

    static func read(relativePath: String, rootDirectoryPath: String) -> Self {
        let root = rootDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            return Self(path: "", state: .unavailable("请先设置本地模块根目录"))
        }
        let path = URL(filePath: root, directoryHint: .isDirectory).appending(path: relativePath).path
        guard let url = LocalSourcePathResolver.fileURL(relativePath: relativePath, rootDirectoryPath: root) else {
            return Self(path: path, state: .unavailable("本地输出路径无效"))
        }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                return Self(path: path, state: .unavailable("本地输出路径被目录或其他文件占用"))
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 16 * 1024) ?? Data()
            return Self(path: path, state: .present,
                        hasManagementHeader: ManagedPublishedFile.hasManagementHeader(header))
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return Self(path: path, state: .missing)
            }
            return Self(path: path, state: .unavailable("无法检查本地文件：\(error.localizedDescription)"))
        }
    }
}

enum ModuleOutputPathInspector {
    static func notice(
        for relativePath: String,
        modules: [RelayModule],
        editingModuleID: UUID?
    ) -> ModuleOutputPathNotice? {
        let normalizedPath = relativePath.lowercased()
        if let owner = modules.first(where: { module in
            module.id != editingModuleID && module.publishedRelativePath.lowercased() == normalizedPath
        }) {
            return ModuleOutputPathNotice(message: "该路径已被“\(owner.name)”使用，保存时会自动加编号避免覆盖。", isWarning: true)
        }
        return nil
    }
}
