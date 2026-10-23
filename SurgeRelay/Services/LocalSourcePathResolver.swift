import Foundation

enum LocalSourcePathResolver {
    static func canonicalDirectoryURL(for path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(filePath: trimmed, directoryHint: .isDirectory)
            .standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    static func pathIdentity(_ relativePath: String) -> String {
        relativePath.replacingOccurrences(of: "\\", with: "/")
            .precomposedStringWithCanonicalMapping.lowercased()
    }

    static func storageRelativePath(for module: RelayModule, rootDirectoryPath: String) -> String? {
        relativePath(forSourceURL: module.sourceURL, rootDirectoryPath: rootDirectoryPath)
    }

    static func fileName(forSourceURL sourceURL: String, rootDirectoryPath: String) -> String? {
        relativePath(forSourceURL: sourceURL, rootDirectoryPath: rootDirectoryPath)?
            .split(separator: "/").last.map(String.init)
    }

    static func relativePath(forSourceURL sourceURL: String, rootDirectoryPath: String) -> String? {
        guard let url = URL(string: sourceURL), url.isFileURL,
              let root = canonicalDirectoryURL(for: rootDirectoryPath) else { return nil }
        let source = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard source.path.hasPrefix(rootPrefix) else { return nil }
        return String(source.path.dropFirst(rootPrefix.count))
    }

    static func fileURL(relativePath: String, rootDirectoryPath: String) -> URL? {
        let components = relativePath.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let root = canonicalDirectoryURL(for: rootDirectoryPath) else { return nil }
        let candidate = root.appending(path: components.joined(separator: "/"))
            .standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path.hasPrefix(rootPrefix) ? candidate : nil
    }
}
