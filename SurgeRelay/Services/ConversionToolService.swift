import Foundation

actor ConversionToolService {
    private let engineStore: EngineStore
    private let embeddedEngine: EmbeddedScriptHubEngine
    private let httpClient: BoundedHTTPClient

    init(engineStore: EngineStore = EngineStore(), embeddedEngine: EmbeddedScriptHubEngine = EmbeddedScriptHubEngine(),
         session: URLSession = .shared) {
        self.engineStore = engineStore
        self.embeddedEngine = embeddedEngine
        httpClient = BoundedHTTPClient(configuration: session.configuration)
    }

    nonisolated static func requiresEngine(_ draft: ConversionToolDraft) -> Bool {
        if draft.kind == .ruleSet { return true }
        if draft.compatibilityOnly || !draft.evalScriptOriginal.isEmpty || !draft.evalScriptModified.isEmpty ||
            !draft.evalURLOriginal.isEmpty || !draft.evalURLModified.isEmpty { return true }
        return draft.sourceFormat == .quantumultX && draft.outputFormat != .quantumultX
    }

    nonisolated static func validate(_ draft: ConversionToolDraft) throws {
        _ = try target(for: draft)
        if draft.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let url = URL(string: draft.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.isFileURL || (["http", "https"].contains(url.scheme?.lowercased()) && url.host?.isEmpty == false) else {
                throw RelayError.invalidSourceURL
            }
        } else if draft.sourceText.utf8.count > ScriptHubWorkerFiles.maximumOutputBytes {
            throw RelayError.invalidOutput("转换来源超过 20 MB 限制。")
        }
    }

    func convert(draft: ConversionToolDraft) async throws -> ConversionToolResult {
        try Task.checkCancellation()
        let target = try Self.target(for: draft)
        let ext = draft.kind == .ruleSet ? "list" : "js"
        let suppliedName = draft.outputName.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = suppliedName.lowercased().hasSuffix(".\(ext)") ? String(suppliedName.dropLast(ext.count + 1)) : suppliedName
        let base = FilenameSanitizer.baseName(from: stem)
        let fileName = "\(base.isEmpty ? "Converted" : base).\(ext)"
        let source = try await source(for: draft)
        try Task.checkCancellation()
        var content: String
        if Self.requiresEngine(draft) {
            let script = try await engineStore.script(named: draft.kind == .ruleSet ? "rule-parser.js" : "script-converter.js")
            let type = draft.kind == .ruleSet ? "rule-set"
                : draft.sourceFormat == .quantumultX && draft.outputFormat != .quantumultX ? "qx-script" : "surge-script"
            let requestURL = try Self.requestURL(sourceURL: source.url, fileName: fileName, type: type, target: target, draft: draft)
            let input = draft.kind == .ruleSet ? Data(QuantumultXOutputConverter.normalizingRuleSource(source.text).utf8) : source.data
            content = try await embeddedEngine.convert(script: script, requestURL: requestURL,
                sourceData: input, sourceURL: source.url)
        } else {
            content = draft.prependScript.isEmpty ? source.text : draft.prependScript + "\n" + source.text
        }
        try Task.checkCancellation()
        if draft.kind == .ruleSet {
            if content.contains("Script Hub 规则集转换: ❌") { throw RelayError.invalidOutput(String(content.prefix(4_000))) }
            if draft.outputFormat == .quantumultX {
                content = try QuantumultXOutputConverter.ruleSet(content, policy: draft.policy)
            }
        } else {
            if draft.sourceFormat == .quantumultX && draft.outputFormat != .quantumultX {
                content = QuantumultXOutputConverter.adaptingConvertedQuantumultXScript(content)
            }
            if draft.outputFormat == .quantumultX && (draft.sourceFormat != .quantumultX || draft.compatibilityOnly) {
                content = try QuantumultXOutputConverter.adaptingScript(content, argument: nil)
            }
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RelayError.invalidOutput("转换没有产生可用内容，请检查来源和目标格式。")
        }
        guard content.utf8.count <= ScriptHubWorkerFiles.maximumOutputBytes else {
            throw RelayError.invalidOutput("转换输出超过 20 MB 限制。")
        }
        try Task.checkCancellation()
        return ConversionToolResult(fileName: fileName, content: content, outputFormat: draft.outputFormat, kind: draft.kind)
    }

    private func source(for draft: ConversionToolDraft) async throws -> (url: URL, data: Data, text: String) {
        let url: URL
        let data: Data
        if !draft.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            url = URL(string: "https://relay.invalid/conversion-source.txt")!
            data = Data(draft.sourceText.utf8)
        } else {
            guard let sourceURL = URL(string: draft.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  sourceURL.isFileURL || (["http", "https"].contains(sourceURL.scheme?.lowercased()) && sourceURL.host?.isEmpty == false) else {
                throw RelayError.invalidSourceURL
            }
            var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            url = components?.url ?? sourceURL
            if url.isFileURL { data = try SourceRevisionService.readLocalSource(url) }
            else {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
                request.setValue("SurgeRelay/2.0", forHTTPHeaderField: "User-Agent")
                for header in draft.requestHeaders.components(separatedBy: .newlines) {
                    guard let separator = header.firstIndex(of: ":") else { continue }
                    let name = header[..<separator].trimmingCharacters(in: .whitespaces)
                    let value = header[header.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, !value.isEmpty { request.setValue(value, forHTTPHeaderField: name) }
                }
                let response = try await httpClient.data(for: request)
                if let http = response.1 as? HTTPURLResponse,
                   let retryAfter = SourceRetryAfterError.response(http, requestedURL: url) { throw retryAfter }
                let status = (response.1 as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    throw RelayError.httpFailure(status: status, message: String(String(decoding: response.0, as: UTF8.self).prefix(240)))
                }
                data = response.0
            }
        }
        guard data.count <= ScriptHubWorkerFiles.maximumOutputBytes else {
            throw RelayError.invalidOutput("转换来源超过 20 MB 限制。")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw RelayError.invalidOutput("来源不是有效的 UTF-8 文本。")
        }
        return (url, data, text)
    }

    private static func target(for draft: ConversionToolDraft) throws -> String {
        if draft.kind == .script {
            guard draft.sourceFormat != .automatic else {
                throw RelayError.invalidOutput("请选择脚本来源客户端：Quantumult X、Surge 或 Loon。")
            }
            if draft.wrapResponse && (draft.sourceFormat != .quantumultX || draft.outputFormat == .quantumultX) {
                throw RelayError.invalidOutput("包装响应仅适用于 Quantumult X 脚本转换到通用客户端。")
            }
            return "surge-script"
        }
        if draft.outputFormat == .quantumultX {
            guard draft.ruleOutputStyle == .ruleSet else {
                throw RelayError.invalidOutput("Quantumult X 支持规则集输出；域名集和剩余规则请使用 Surge、Egern 或 Stash。")
            }
            let policy = draft.policy.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !policy.isEmpty, !draft.policy.contains(","), !draft.policy.contains(where: \.isNewline) else {
                throw RelayError.invalidOutput("Quantumult X 策略不能为空，也不能包含逗号或换行。")
            }
            return "surge-rule-set"
        }
        let family: String
        switch draft.outputFormat {
        case .surge, .egern: family = "surge"
        case .stash: family = "stash"
        case .loon: family = "loon"
        case .shadowrocket: family = "shadowrocket"
        case .quantumultX: family = "surge"
        }
        if draft.ruleOutputStyle != .ruleSet, family != "surge", family != "stash" {
            throw RelayError.invalidOutput("\(draft.outputFormat.title) 不支持域名集或非域名剩余规则输出，请选择规则集。")
        }
        let suffix = draft.ruleOutputStyle == .ruleSet ? "rule-set" : draft.ruleOutputStyle == .domainSet ? "domain-set" : "domain-set2"
        return "\(family)-\(suffix)"
    }

    private static func requestURL(sourceURL: URL, fileName: String, type: String, target: String,
                                   draft: ConversionToolDraft) throws -> URL {
        var items = [URLQueryItem(name: "type", value: type), URLQueryItem(name: "target", value: target)]
        func add(_ name: String, _ value: String) { if !value.isEmpty { items.append(URLQueryItem(name: name, value: value)) } }
        add("headers", draft.requestHeaders)
        add("evalScriptori", draft.evalScriptOriginal)
        add("evalScriptmodi", draft.evalScriptModified)
        add("evalUrlori", draft.evalURLOriginal)
        add("evalUrlmodi", draft.evalURLModified)
        if draft.kind == .ruleSet {
            add("y", draft.includeKeywords)
            add("x", draft.excludeKeywords)
            add("sni", draft.sni)
            if draft.noResolve { add("nore", "true") }
        } else {
            add("prepend", draft.prependScript)
            if draft.compatibilityOnly { add("compatibilityOnly", "true") }
            if draft.wrapResponse { add("wrap_response", "true") }
        }
        var components = URLComponents()
        components.queryItems = items
        let path = draft.kind == .ruleSet ? "file" : "convert"
        guard let query = components.percentEncodedQuery,
              let name = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "http://script.hub/\(path)/_start_/\(sourceURL.absoluteString)/_end_/\(name)?\(query)") else {
            throw RelayError.invalidServiceURL
        }
        return url
    }
}
