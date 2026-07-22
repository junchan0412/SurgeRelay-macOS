import Foundation

struct ScriptHubSubscriptionInfo: Codable, Hashable, Sendable {
    var subscriptionURL: String
    var originalURL: String
    var outputName: String?
    var sourceType: String?
    var target: String?
    var category: String?
    var options: ScriptHubOptions

    var sourceFormat: ModuleSourceFormat? {
        // Prefer definitive URL extension signals over a conflicting Script-Hub type query.
        // Some historical conversions store type=qx-rewrite even when originalURL is a .sgmodule.
        if let original = URL(string: originalURL),
           let definitive = ModuleSourceFormat.definitiveFormat(for: original) {
            return definitive
        }
        switch sourceType?.lowercased() {
        case "qx-rewrite": return .quantumultX
        case "loon-plugin": return .loon
        case "surge-module": return .surge
        default:
            if let original = URL(string: originalURL) {
                return ModuleSourceFormat.inferredFormat(for: original)
            }
            return nil
        }
    }

    var displaySummary: String {
        let type = sourceFormat?.shortTitle ?? sourceType ?? "未知格式"
        let targetText = target.map { " -> \($0)" } ?? ""
        return "Script-Hub \(type)\(targetText)"
    }
}

enum ModuleMetadataParser {
    static func scriptHubSubscription(in content: String) -> ScriptHubSubscriptionInfo? {
        guard let value = ModuleMetadataLineReader.subscribedValue(in: content) else { return nil }
        return parseScriptHubSubscriptionURL(value)
    }

    static func iconURL(in content: String, relativeTo source: String? = nil) -> URL? {
        guard let rawValue = ModuleMetadataLineReader.hashBangValue(named: "icon", in: content) else {
            return nil
        }
        let value = rawValue
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
        guard let rawValue = ModuleMetadataLineReader.hashBangValue(named: "name", in: content) else {
            return nil
        }
        let value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty ? nil : value
    }

    static func category(in content: String) -> String? {
        guard let rawValue = ModuleMetadataLineReader.hashBangValue(named: "category", in: content) else {
            return nil
        }
        let value = rawValue
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
        ModuleMetadataLineReader.hashBangName(in: line)?.caseInsensitiveCompare("icon") == .orderedSame
    }

    private static func parseScriptHubSubscriptionURL(_ value: String) -> ScriptHubSubscriptionInfo? {
        let startMarker = "/_start_/"
        let endMarker = "/_end_/"
        guard let start = value.range(of: startMarker),
              let end = value.range(of: endMarker, range: start.upperBound..<value.endIndex) else {
            return nil
        }

        let originalPart = String(value[start.upperBound..<end.lowerBound])
        let tail = String(value[end.upperBound...])
        let pieces = tail.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let outputName = pieces.first.map(String.init)
            .map { $0.removingPercentEncoding ?? $0 }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let query = pieces.count > 1 ? String(pieces[1]) : ""
        let queryItems = decodedQueryItems(from: query)
        guard let originalURL = normalizedOriginalURL(originalPart) else { return nil }
        let sourceType = queryItems["type"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScriptHubSubscriptionInfo(
            subscriptionURL: value,
            originalURL: originalURL,
            outputName: outputName?.isEmpty == false ? outputName : nil,
            sourceType: sourceType?.isEmpty == false ? sourceType : nil,
            target: queryItems["target"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            category: queryItems["category"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            options: ScriptHubOptions(query: queryItems)
        )
    }

    private static func decodedQueryItems(from query: String) -> [String: String] {
        guard !query.isEmpty else { return [:] }
        var components = URLComponents()
        components.percentEncodedQuery = query
        if let items = components.queryItems {
            var values: [String: String] = [:]
            for item in items {
                guard let value = item.value else { continue }
                values[item.name] = value
            }
            return values
        }

        var values: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let name = String(pieces[0]).removingPercentEncoding ?? String(pieces[0])
            let value = String(pieces[1]).removingPercentEncoding ?? String(pieces[1])
            values[name] = value
        }
        return values
    }

    private static func normalizedOriginalURL(_ value: String) -> String? {
        let decoded = (value.removingPercentEncoding ?? value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }
        if let url = URL(string: decoded),
           ["http", "https"].contains(url.scheme?.lowercased()) {
            return url.absoluteString
        }
        let encoded = decoded.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? decoded
        if let url = URL(string: encoded),
           ["http", "https"].contains(url.scheme?.lowercased()) {
            return url.absoluteString
        }
        return decoded
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
        ModuleMetadataLineReader.hashBangValue(named: name, in: content)
    }

    private static func isArgumentMetadata(_ line: String) -> Bool {
        guard let name = ModuleMetadataLineReader.hashBangName(in: line)?.lowercased() else {
            return false
        }
        return name == "arguments" || name == "arguments-desc"
    }

}

private enum ModuleMetadataLineReader {
    static func hashBangValue(named name: String, in content: String) -> String? {
        for line in content.split(whereSeparator: { $0.isNewline }) {
            let parsed = parseHashBangLine(String(line))
            guard parsed?.name.caseInsensitiveCompare(name) == .orderedSame else { continue }
            return parsed?.value
        }
        return nil
    }

    static func hashBangName(in line: String) -> String? {
        parseHashBangLine(line)?.name
    }

    static func subscribedValue(in content: String) -> String? {
        for line in content.split(whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#") else { continue }
            let body = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            let token = "SUBSCRIBED"
            guard body.count >= token.count,
                  body.prefix(token.count).caseInsensitiveCompare(token) == .orderedSame else {
                continue
            }
            var remainder = body.dropFirst(token.count)
            guard remainder.first.map({ $0.isWhitespace || $0 == "=" }) == true else { continue }
            while remainder.first.map({ $0.isWhitespace || $0 == "=" }) == true {
                remainder.removeFirst()
            }
            let value = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func parseHashBangLine(_ line: String) -> (name: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#!") else { return nil }
        let body = trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = body.firstIndex(of: "=") else { return nil }
        let name = body[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let value = body[body.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, value)
    }
}
