import Foundation

enum ModuleMetadataParser {
    static func iconURL(in content: String, relativeTo source: String? = nil) -> URL? {
        let pattern = #"(?im)^\s*#!icon\s*=\s*(.+?)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content) else { return nil }

        let value = String(content[range])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !value.isEmpty else { return nil }

        let baseURL = source.flatMap(URL.init(string:))
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }

    /// The module's own display name from its metadata header (`#!name=…`),
    /// used by Surge `.sgmodule` and Loon plugins. Returns nil when absent
    /// (e.g. most Quantumult X rewrite `.conf` files have no name field).
    static func displayName(in content: String) -> String? {
        let pattern = #"(?im)^\s*#!\s*name\s*=\s*(.+?)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content) else { return nil }
        let value = String(content[range])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty ? nil : value
    }

    static func category(in content: String) -> String? {
        let pattern = #"(?im)^\s*#!\s*category\s*=\s*(.+?)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content) else { return nil }
        let value = String(content[range])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty ? nil : value
    }

    static func applyingDisplayName(_ name: String, to content: String) -> String {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let line = "#!name=\(name.trimmingCharacters(in: .whitespacesAndNewlines))"
        guard let expression = try? NSRegularExpression(pattern: #"(?im)^\s*#!name\s*=.*$"#) else {
            return line + "\n" + normalized
        }
        let range = NSRange(normalized.startIndex..., in: normalized)
        if expression.firstMatch(in: normalized, range: range) != nil {
            return expression.stringByReplacingMatches(
                in: normalized,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: line)
            )
        }
        return line + "\n" + normalized
    }

    static func applyingCategory(_ category: String, to content: String) -> String {
        let value = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return content.replacingOccurrences(of: "\r\n", with: "\n")
        }
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let line = "#!category=\(value)"
        guard let expression = try? NSRegularExpression(pattern: #"(?im)^\s*#!category\s*=.*$"#) else {
            return line + "\n" + normalized
        }
        let range = NSRange(normalized.startIndex..., in: normalized)
        if expression.firstMatch(in: normalized, range: range) != nil {
            return expression.stringByReplacingMatches(
                in: normalized,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: line)
            )
        }
        if let nameExpression = try? NSRegularExpression(pattern: #"(?im)^\s*#!name\s*=.*$"#),
           let match = nameExpression.firstMatch(in: normalized, range: range),
           let nameRange = Range(match.range, in: normalized) {
            var updated = normalized
            updated.insert(contentsOf: "\n\(line)", at: nameRange.upperBound)
            return updated
        }
        return line + "\n" + normalized
    }

    static func removingIconMetadata(from content: String) -> String {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized
            .components(separatedBy: "\n")
            .filter { !isIconMetadataLine($0) }
            .joined(separator: "\n")
    }

    static func applyingModuleMetadata(name: String, category: String, to content: String) -> String {
        removingIconMetadata(from: applyingCategory(category, to: applyingDisplayName(name, to: content)))
    }

    private static func isIconMetadataLine(_ line: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: #"(?i)^\s*#!\s*icon\s*="#) else {
            return false
        }
        return expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
}

struct ModuleArgumentDefinition: Identifiable, Hashable, Sendable {
    var id: String { key }
    let key: String
    let defaultValue: String
}

struct ModuleArgumentInfo: Hashable, Sendable {
    var definitions: [ModuleArgumentDefinition] = []
    var helpText: String?
}

enum ModuleArgumentProcessor {
    static func info(in content: String) -> ModuleArgumentInfo {
        guard let value = metadataValue(named: "arguments", in: content) else {
            return ModuleArgumentInfo()
        }
        let definitions = parse(value).map { ModuleArgumentDefinition(key: $0.0, defaultValue: $0.1) }
        let help = metadataValue(named: "arguments-desc", in: content)
            .map { $0.replacingOccurrences(of: "\\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
        return ModuleArgumentInfo(definitions: definitions, helpText: help?.isEmpty == false ? help : nil)
    }

    static func materialize(_ content: String, overrides: [String: String]) -> String {
        let info = info(in: content)
        var resolved = content.replacingOccurrences(of: "\r\n", with: "\n")
        for definition in info.definitions {
            let value = overrides[definition.key] ?? definition.defaultValue
            resolved = resolved.replacingOccurrences(of: "%\(definition.key)%", with: value)
            resolved = resolved.replacingOccurrences(of: "{{{\(definition.key)}}}", with: value)
        }

        var output: [String] = []
        var previousWasEmpty = false
        for line in resolved.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isArgumentMetadata(trimmed) { continue }
            if isCommentOnly(trimmed) { continue }
            if trimmed.isEmpty {
                guard !previousWasEmpty, !output.isEmpty else { continue }
                previousWasEmpty = true
            } else {
                previousWasEmpty = false
            }
            output.append(line)
        }
        while output.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { output.removeLast() }
        return output.joined(separator: "\n") + "\n"
    }

    private static func parse(_ value: String) -> [(String, String)] {
        if value.contains("=") {
            return value.split(separator: "&").compactMap { pair in
                let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2 else { return nil }
                let key = String(pieces[0]).removingPercentEncoding ?? String(pieces[0])
                let value = String(pieces[1]).removingPercentEncoding ?? String(pieces[1])
                return normalizedPair(key, value)
            }
        }
        return value.split(separator: ",").compactMap { pair in
            let pieces = pair.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return nil }
            return normalizedPair(String(pieces[0]), String(pieces[1]))
        }
    }

    private static func normalizedPair(_ key: String, _ value: String) -> (String, String)? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'")) {
            value.removeFirst()
            value.removeLast()
        }
        return (key, value)
    }

    private static func metadataValue(named name: String, in content: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?im)^\\s*#!\\s*\(escapedName)\\s*=\\s*(.*?)\\s*$"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: content,
                range: NSRange(content.startIndex..., in: content)
              ),
              let range = Range(match.range(at: 1), in: content) else { return nil }
        return String(content[range])
    }

    private static func isArgumentMetadata(_ line: String) -> Bool {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)^#!\s*arguments(?:-desc)?\s*="#
        ) else { return false }
        return expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func isCommentOnly(_ line: String) -> Bool {
        guard !line.isEmpty, !line.hasPrefix("#!") else { return false }
        return line.hasPrefix("#") || line.hasPrefix("//") || line.hasPrefix(";")
    }
}
