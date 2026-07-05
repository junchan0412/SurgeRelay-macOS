import Foundation

struct LocalModuleRootDiagnosticSnapshot: Codable, Equatable, Sendable {
    var path: String
    var exists: Bool
    var isDirectory: Bool
    var isWritable: Bool
    var folderCount: Int
    var moduleFileCount: Int
    var status: String
    var error: String?

    static func current(path rawPath: String, fileManager: FileManager = .default) -> LocalModuleRootDiagnosticSnapshot {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return LocalModuleRootDiagnosticSnapshot(
                path: "",
                exists: false,
                isDirectory: false,
                isWritable: false,
                folderCount: 0,
                moduleFileCount: 0,
                status: "未设置本地模块根目录",
                error: nil
            )
        }

        let root = URL(filePath: trimmed, directoryHint: .isDirectory).standardizedFileURL
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory)
        guard exists else {
            return LocalModuleRootDiagnosticSnapshot(
                path: root.path,
                exists: false,
                isDirectory: false,
                isWritable: false,
                folderCount: 0,
                moduleFileCount: 0,
                status: "目录不存在",
                error: nil
            )
        }
        guard isDirectory.boolValue else {
            return LocalModuleRootDiagnosticSnapshot(
                path: root.path,
                exists: true,
                isDirectory: false,
                isWritable: false,
                folderCount: 0,
                moduleFileCount: 0,
                status: "路径不是文件夹",
                error: nil
            )
        }

        let isWritable = fileManager.isWritableFile(atPath: root.path)
        var folderCount = 0
        var moduleFileCount = 0
        var scanError: String?
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                do {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey])
                    if values.isPackage == true { continue }
                    if values.isDirectory == true {
                        folderCount += 1
                    } else if values.isRegularFile == true, url.pathExtension.lowercased() == "sgmodule" {
                        moduleFileCount += 1
                    }
                } catch {
                    scanError = error.localizedDescription
                    break
                }
            }
        } else {
            scanError = "无法枚举目录内容"
        }

        let status = if let scanError {
            "目录可访问，但扫描不完整：\(scanError)"
        } else if !isWritable {
            "目录存在，但当前不可写"
        } else {
            "目录可用"
        }
        return LocalModuleRootDiagnosticSnapshot(
            path: root.path,
            exists: true,
            isDirectory: true,
            isWritable: isWritable,
            folderCount: folderCount,
            moduleFileCount: moduleFileCount,
            status: status,
            error: scanError
        )
    }
}
