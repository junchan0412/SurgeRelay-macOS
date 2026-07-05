import Foundation

enum SurgeModuleSanitizer {
    private struct Section {
        var header: String
        var name: String
        var lines: [String]
    }

    static func sanitize(_ content: String) -> String {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let input = normalized.components(separatedBy: "\n")
        var preamble: [String] = []
        var sections: [Section] = []
        var currentIndex: Int?
        var generatedScripts: [String] = []

        for rawLine in input {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 {
                let name = String(trimmed.dropFirst().dropLast())
                sections.append(Section(header: trimmed, name: name, lines: []))
                currentIndex = sections.count - 1
                continue
            }

            guard let currentIndex else {
                preamble.append(rawLine)
                continue
            }

            let sectionName = sections[currentIndex].name
            if sectionName.caseInsensitiveCompare("Body Rewrite") == .orderedSame,
               isEmptyBodyRewrite(trimmed) {
                continue
            }
            if sectionName.caseInsensitiveCompare("Map Local") == .orderedSame,
               let script = convertedLoonScript(from: trimmed, existing: existingScriptNames(in: sections) + generatedScripts) {
                if !generatedScripts.contains(script) {
                    generatedScripts.append(script)
                }
                continue
            }
            sections[currentIndex].lines.append(rawLine)
        }

        if !generatedScripts.isEmpty {
            if let index = sections.firstIndex(where: { $0.name.caseInsensitiveCompare("Script") == .orderedSame }) {
                if !sections[index].lines.isEmpty,
                   sections[index].lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    sections[index].lines.append("")
                }
                sections[index].lines.append(contentsOf: generatedScripts)
            } else {
                sections.append(Section(header: "[Script]", name: "Script", lines: generatedScripts))
            }
        }

        var output = preamble
        for section in sections {
            if !output.isEmpty,
               output.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                output.append("")
            }
            output.append(section.header)
            output.append(contentsOf: section.lines)
        }
        while output.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            output.removeLast()
        }
        return output.joined(separator: "\n") + "\n"
    }

    private static func isEmptyBodyRewrite(_ line: String) -> Bool {
        guard line.range(
            of: #"^http-(?:request|response)(?:-jq)?\s+\S+"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else { return false }
        let parts = line.split(
            maxSplits: 2,
            omittingEmptySubsequences: true,
            whereSeparator: \.isWhitespace
        )
        guard parts.count == 3 else { return true }
        let value = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard parts[0].lowercased().hasSuffix("-jq") else { return value.isEmpty }
        let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return unquoted.isEmpty
    }

    private static func convertedLoonScript(from line: String, existing: [String]) -> String? {
        let pattern = #"^(.+?)\s+url\s+script-(request|response)-(body|header)\s+(https?://\S+)(?:\s+.*)?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let patternRange = Range(match.range(at: 1), in: line),
              let directionRange = Range(match.range(at: 2), in: line),
              let bodyRange = Range(match.range(at: 3), in: line),
              let urlRange = Range(match.range(at: 4), in: line) else { return nil }

        let urlString = String(line[urlRange])
        let baseName = URL(string: urlString)?.deletingPathExtension().lastPathComponent ?? ""
        let identifier = uniqueScriptName(from: baseName, existing: existing)
        let direction = String(line[directionRange]).lowercased()
        let requiresBody = String(line[bodyRange]).caseInsensitiveCompare("body") == .orderedSame ? "1" : "0"
        return "\(identifier) = type=http-\(direction), pattern=\(line[patternRange]), requires-body=\(requiresBody), script-path=\(urlString)"
    }

    private static func existingScriptNames(in sections: [Section]) -> [String] {
        guard let script = sections.first(where: { $0.name.caseInsensitiveCompare("Script") == .orderedSame }) else {
            return []
        }
        return script.lines.compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func uniqueScriptName(from raw: String, existing: [String]) -> String {
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || "_-".unicodeScalars.contains(scalar)
                ? Character(String(scalar))
                : "_"
        }
        let trimmed = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        let base = trimmed.isEmpty ? "converted_script" : trimmed
        let unavailable = Set(existing.map { name in
            name.split(separator: "=", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? name.lowercased()
        })
        guard unavailable.contains(base.lowercased()) else { return base }
        var suffix = 2
        while unavailable.contains("\(base)_\(suffix)".lowercased()) { suffix += 1 }
        return "\(base)_\(suffix)"
    }
}
