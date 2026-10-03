import Foundation

enum ManagedPublishedFile {
    private static let marker = "# Surge Relay managed output"
    private static let pathPrefix = "# surge-relay-relative-path: "

    static func dataWrapping(_ data: Data, relativePath: String) -> Data {
        guard requiresInlineMarker(relativePath), !isManaged(data) else { return data }
        let markerLines = "\(marker)\n\(pathPrefix)\(relativePath)"
        if let content = String(data: data, encoding: .utf8) {
            var lines = content.components(separatedBy: "\n")
            var insertionIndex = 0
            while insertionIndex < lines.count {
                let line = lines[insertionIndex]
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\r", with: "")
                guard line.hasPrefix("#!") else { break }
                insertionIndex += 1
            }
            lines.insert(contentsOf: markerLines.components(separatedBy: "\n"), at: insertionIndex)
            return Data(lines.joined(separator: "\n").utf8)
        }
        let header = "\(markerLines)\n"
        var result = Data(header.utf8)
        result.append(data)
        return result
    }

    static func isManaged(_ data: Data) -> Bool {
        guard let content = String(data: data, encoding: .utf8) else { return false }
        return content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .prefix(64)
            .contains { $0.trimmingCharacters(in: .whitespaces) == marker }
    }

    static func requiresInlineMarker(_ relativePath: String) -> Bool {
        ["sgmodule", "module"].contains((relativePath as NSString).pathExtension.lowercased())
    }

    static func isManaged(_ data: Data, relativePath: String) -> Bool {
        if requiresInlineMarker(relativePath) { return isManaged(data) }
        let header = String(decoding: data.prefix(16 * 1024), as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let lines = Array(header.components(separatedBy: "\n").prefix(64))
        for index in lines.indices.dropLast() where lines[index] == marker {
            if lines[index + 1] == pathPrefix + relativePath { return true }
        }
        return false
    }

    static func validatedConflictVersions(
        at url: URL,
        allowingKnownManagedPath: Bool,
        relativePath: String? = nil
    ) throws -> [NSFileVersion] {
        let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        for version in versions {
            let data = try Data(contentsOf: version.url)
            let managed = relativePath.map { isManaged(data, relativePath: $0) } ?? isManaged(data)
            guard managed || allowingKnownManagedPath else {
                throw RelayError.invalidOutput("检测到不属于 Surge Relay 的 iCloud 冲突版本，已停止操作。")
            }
        }
        return versions
    }

    static func resolve(_ versions: [NSFileVersion], at url: URL) throws {
        guard !versions.isEmpty else { return }
        for version in versions { version.isResolved = true }
        try NSFileVersion.removeOtherVersionsOfItem(at: url)
    }
}
