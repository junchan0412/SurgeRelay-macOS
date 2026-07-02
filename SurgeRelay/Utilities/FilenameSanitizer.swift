import Foundation

enum FilenameSanitizer {
    static func baseName(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutExtension = trimmed.lowercased().hasSuffix(".sgmodule")
            ? String(trimmed.dropLast(".sgmodule".count))
            : trimmed
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return withoutExtension
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
    }

    static func sgmoduleName(from value: String) -> String {
        let base = baseName(from: value)
        return base.isEmpty ? "Untitled.sgmodule" : "\(base).sgmodule"
    }

    static func existingFileBaseName(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        let fileName = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        let withoutExtension = fileName.lowercased().hasSuffix(".sgmodule")
            ? String(fileName.dropLast(".sgmodule".count))
            : fileName
        let forbidden = CharacterSet(charactersIn: ":*?\"<>|")
        return withoutExtension
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    static func existingSgmoduleName(from value: String) -> String {
        let base = existingFileBaseName(from: value)
        return base.isEmpty ? "Untitled.sgmodule" : "\(base).sgmodule"
    }

    static func suggestedName(from sourceURL: String) -> String {
        guard let url = URL(string: sourceURL) else { return "" }
        let candidate = url.deletingPathExtension().lastPathComponent
        return baseName(from: candidate)
    }
}
