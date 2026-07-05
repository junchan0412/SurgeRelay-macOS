import Foundation

enum ModuleMerger {
    private struct ParsedModule {
        var module: RelayModule
        var sections: [(name: String, lines: [String])]
        var requirements: [String]
        var system: String?
        var authors: [String]
    }

    static func merge(_ components: [(RelayModule, String)], engineRevision: String?) throws -> String {
        let parsed = components.map {
            parse(
                module: $0.0,
                content: SurgeModuleSanitizer.sanitize(
                    ModuleArgumentProcessor.materialize($0.1, overrides: [:])
                )
            )
        }
        guard parsed.contains(where: { !$0.sections.isEmpty }) else {
            throw RelayError.invalidOutput("没有找到可合并的 Surge 配置段。")
        }

        var output: [String] = [
            "#!name=Surge Relay",
            "#!desc=由 Surge Relay 整合 \(components.count) 个模块",
            "#!author=Surge Relay" + mergedAuthors(parsed),
            "#!category=Surge Relay",
        ]

        let requirements = Array(Set(parsed.flatMap(\.requirements).compactMap(sanitizeRequirement))).sorted()
        if !requirements.isEmpty {
            output.append("#!requirement=" + requirements.map { "(\($0))" }.joined(separator: " && "))
        }

        let sectionNames = orderedSectionNames(parsed)
        for sectionName in sectionNames {
            let groups = parsed.compactMap { item -> (RelayModule, [String])? in
                guard let section = item.sections.first(where: { $0.name.caseInsensitiveCompare(sectionName) == .orderedSame }) else { return nil }
                return (item.module, section.lines)
            }
            let lines = mergeLines(groups, sectionName: sectionName)
            guard !lines.isEmpty else { continue }
            output.append("")
            output.append("[\(sectionName)]")
            output.append(contentsOf: lines)
        }

        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func parse(module: RelayModule, content: String) -> ParsedModule {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var sections: [(String, [String])] = []
        var currentIndex: Int?
        var requirements: [String] = []
        var system: String?
        var authors: [String] = []

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]"), line.count > 2 {
                let name = String(line.dropFirst().dropLast())
                sections.append((name, []))
                currentIndex = sections.count - 1
                continue
            }
            if let currentIndex {
                if !line.isEmpty { sections[currentIndex].1.append(raw) }
                continue
            }
            if line.hasPrefix("#!requirement=") {
                requirements.append(String(line.dropFirst("#!requirement=".count)))
            } else if line.hasPrefix("#!system=") {
                system = String(line.dropFirst("#!system=".count))
            } else if line.hasPrefix("#!author=") {
                authors.append(String(line.dropFirst("#!author=".count)))
            }
        }
        return ParsedModule(
            module: module,
            sections: sections,
            requirements: requirements,
            system: system,
            authors: authors
        )
    }

    private static func mergedAuthors(_ modules: [ParsedModule]) -> String {
        let authors = Array(Set(modules.flatMap(\.authors))).sorted()
        return authors.isEmpty ? "" : " · " + authors.joined(separator: " · ")
    }

    private static func orderedSectionNames(_ modules: [ParsedModule]) -> [String] {
        let preferred = ["General", "MITM", "Rule", "Host", "URL Rewrite", "Header Rewrite", "Body Rewrite", "Map Local", "Script"]
        var names: [String] = []
        for name in preferred where modules.contains(where: { $0.sections.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) }) {
            names.append(name)
        }
        for name in modules.flatMap({ $0.sections.map(\.name) })
        where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            names.append(name)
        }
        return names
    }

    private static func mergeLines(_ groups: [(RelayModule, [String])], sectionName: String) -> [String] {
        if sectionName.caseInsensitiveCompare("General") == .orderedSame {
            return mergeKeyValueLines(groups)
        }
        if sectionName.caseInsensitiveCompare("MITM") == .orderedSame {
            return mergeKeyValueLines(groups)
        }
        var output: [String] = []
        var seen = Set<String>()
        for (_, lines) in groups {
            let useful = lines.filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && !isCommentOnly(trimmed)
            }
            guard !useful.isEmpty else { continue }
            for line in useful where seen.insert(line).inserted {
                output.append(line)
            }
        }
        return output
    }

    private static func mergeKeyValueLines(_ groups: [(RelayModule, [String])]) -> [String] {
        var order: [String] = []
        var values: [String: (key: String, value: String)] = [:]
        for (module, lines) in groups {
            _ = module
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty, !isCommentOnly(trimmedLine) else { continue }
                let pieces = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2 else { continue }
                let key = pieces[0].trimmingCharacters(in: .whitespaces)
                let value = pieces[1].trimmingCharacters(in: .whitespaces)
                let normalized = key.lowercased()
                if values[normalized] == nil { order.append(normalized) }
                if let existing = values[normalized],
                   let combined = combineDirective(existing.value, value) {
                    values[normalized] = (existing.key, combined)
                } else if values[normalized] == nil {
                    // 组件数组与模块列表顺序相同；同名配置由更靠上的模块优先决定。
                    values[normalized] = (key, value)
                }
            }
        }
        return order.compactMap { values[$0].map { "\($0.key) = \($0.value)" } }
    }

    private static func combineDirective(_ lhs: String, _ rhs: String) -> String? {
        let directives = ["%APPEND%", "%INSERT%"]
        guard let leftDirective = directives.first(where: lhs.hasPrefix),
              let rightDirective = directives.first(where: rhs.hasPrefix) else { return nil }
        let left = lhs.dropFirst(leftDirective.count).trimmingCharacters(in: .whitespaces)
        let right = rhs.dropFirst(rightDirective.count).trimmingCharacters(in: .whitespaces)
        var seen = Set<String>()
        let items = (left + "," + right).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        // A merged module has one directive per key. Keep the highest-priority
        // module's placement semantics while retaining every module's values.
        return leftDirective + " " + items.joined(separator: ", ")
    }

    // 仅供预览器在内存中识别模块来源；该标识不会写入最终 sgmodule。
    static func toggleKey(for module: RelayModule) -> String {
        "Relay_" + module.id.uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func isCommentOnly(_ line: String) -> Bool {
        line.hasPrefix("#") || line.hasPrefix("//") || line.hasPrefix(";")
    }

    private static func sanitizeRequirement(_ requirement: String) -> String? {
        let deviceVariables = ["SYSTEM", "SYSTEM_VERSION", "DEVICE_MODEL"]
        guard deviceVariables.contains(where: requirement.contains) else { return requirement }
        let pattern = #"CORE_VERSION\s*(?:>=|<=|==|=|>|<)\s*[0-9]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let matches = expression.matches(in: requirement, range: NSRange(requirement.startIndex..., in: requirement))
        let coreClauses = matches.compactMap { Range($0.range, in: requirement).map { String(requirement[$0]) } }
        return coreClauses.isEmpty ? nil : coreClauses.joined(separator: " && ")
    }
}

actor ModuleProcessingWorker {
    func materialize(_ content: String, overrides: [String: String]) -> String {
        ModuleArgumentProcessor.materialize(content, overrides: overrides)
    }

    func argumentInfo(in content: String) -> ModuleArgumentInfo {
        ModuleArgumentProcessor.info(in: content)
    }

    func applyingDisplayName(_ name: String, to content: String) -> String {
        ModuleMetadataParser.applyingDisplayName(name, to: content)
    }

    func applyingModuleMetadata(name: String, category: String, to content: String) -> String {
        ModuleMetadataParser.applyingModuleMetadata(name: name, category: category, to: content)
    }

    func iconURL(in content: String, relativeTo source: String?) -> URL? {
        ModuleMetadataParser.iconURL(in: content, relativeTo: source)
    }

    func contentFingerprint(of content: String, assets: [GeneratedAsset]) -> String {
        var data = Data(content.utf8)
        for asset in assets.sorted(by: { $0.relativePath < $1.relativePath }) {
            data.append(0)
            data.append(contentsOf: asset.relativePath.utf8)
            data.append(0)
            data.append(asset.data)
        }
        return data.sha256String
    }

    func merge(_ components: [(RelayModule, String)], engineRevision: String?) throws -> String {
        try ModuleMerger.merge(components, engineRevision: engineRevision)
    }
}
