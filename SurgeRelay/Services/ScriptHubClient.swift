import Foundation

actor ScriptHubClient {
    private static let convertPathExpression = try? NSRegularExpression(
        pattern: #"script-path\s*=\s*(http://script\.hub/convert/_start_/.*?/_end_/[^,\s]+)"#
    )

    private let engineStore: EngineStore
    private let embeddedEngine: EmbeddedScriptHubEngine
    private let httpClient: BoundedHTTPClient

    init(
        engineStore: EngineStore = EngineStore(),
        embeddedEngine: EmbeddedScriptHubEngine = EmbeddedScriptHubEngine(),
        session: URLSession = .shared
    ) {
        self.engineStore = engineStore
        self.embeddedEngine = embeddedEngine
        self.httpClient = BoundedHTTPClient(configuration: session.configuration)
    }

    func conversionURL(module: RelayModule, baseURL: String) throws -> URL {
        guard let sourceURL = URL(string: module.updateSourceURL),
              ["http", "https"].contains(sourceURL.scheme?.lowercased()) else {
            throw RelayError.invalidSourceURL
        }

        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard trimmedBase.hasPrefix("http://") || trimmedBase.hasPrefix("https://") else {
            throw RelayError.invalidServiceURL
        }

        let source = sourceURL.absoluteString.components(separatedBy: "#").first ?? sourceURL.absoluteString
        let fileName = FilenameSanitizer.baseName(from: module.outputFileName)
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "module"
        let type = module.sourceFormat.scriptHubType(for: sourceURL)
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "target", value: "surge-module")
        ] + module.scriptHubOptions.queryItems()
        guard let query = components.percentEncodedQuery else { throw RelayError.invalidServiceURL }
        let raw = "\(trimmedBase)/file/_start_/\(source)/_end_/\(fileName).sgmodule?\(query)"

        guard let url = URL(string: raw) else { throw RelayError.invalidServiceURL }
        return url
    }

    func convert(module: RelayModule, github: GitHubSettings? = nil, sourceData: Data? = nil) async throws -> ConversionResult {
        try Task.checkCancellation()
        guard let sourceURL = URL(string: module.updateSourceURL) else { throw RelayError.invalidSourceURL }
        if module.sourceFormat.isNativeSurgeModule(for: sourceURL) {
            let data: Data
            if let sourceData {
                data = sourceData
            } else if sourceURL.isFileURL {
                data = try SourceRevisionService.readLocalSource(sourceURL)
            } else {
                guard ["http", "https"].contains(sourceURL.scheme?.lowercased()) else {
                    throw RelayError.invalidSourceURL
                }
                var request = URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
                request.setValue("SurgeRelay/2.0", forHTTPHeaderField: "User-Agent")
                let (responseData, response) = try await httpClient.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    let body = String(data: responseData, encoding: .utf8) ?? ""
                    throw RelayError.httpFailure(status: status, message: String(body.prefix(240)))
                }
                data = responseData
            }
            guard let content = String(data: data, encoding: .utf8) else {
                throw RelayError.invalidOutput("来源不是有效的 UTF-8 模块文本。")
            }
            let namedContent = ModuleMetadataParser.applyingModuleMetadata(
                name: module.name,
                category: module.category,
                desc: module.moduleDescription,
                iconURL: module.customIconURL,
                to: content
            )
            let subscription = scriptHubSubscription(for: module)
            let subscribedContent = ModuleMetadataParser.applyingScriptHubSubscription(subscription, to: namedContent)
            let sanitized = SurgeModuleSanitizer.sanitize(subscribedContent)
            try validate(sanitized)
            return ConversionResult(content: sanitized, requestURL: sourceURL)
        }
        let url = try conversionURL(module: module, baseURL: "http://script.hub")
        let script = try await engineStore.script(named: "Rewrite-Parser.js")
        let converter = try await engineStore.script(named: "script-converter.js")
        let content = try await embeddedEngine.convert(
            script: script,
            scriptConverterScript: converter,
            requestURL: url
        )
        try validate(content)
        let materialized = try await materializeConvertedScripts(
            in: content,
            module: module,
            converterScript: converter,
            github: github
        )
        let namedContent = ModuleMetadataParser.applyingModuleMetadata(
            name: module.name,
            category: module.category,
            desc: module.moduleDescription,
            iconURL: module.customIconURL,
            to: materialized.content
        )
        let subscription = scriptHubSubscription(for: module)
        let subscribedContent = ModuleMetadataParser.applyingScriptHubSubscription(subscription, to: namedContent)
        let sanitized = SurgeModuleSanitizer.sanitize(subscribedContent)
        try validate(sanitized)
        return ConversionResult(content: sanitized, requestURL: url, assets: materialized.assets)
    }

    func validate(_ content: String) throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RelayError.invalidOutput("服务器返回了空内容。") }
        if trimmed.contains("Script Hub 重写转换: ❌") || trimmed.hasPrefix("<!DOCTYPE html") {
            throw RelayError.invalidOutput(String(trimmed.prefix(240)))
        }
        let markers = ["#!name=", "[General]", "[MITM]", "[Script]", "[URL Rewrite]", "[Header Rewrite]", "[Rule]"]
        guard markers.contains(where: trimmed.contains) else {
            throw RelayError.invalidOutput("没有检测到 Surge 模块标记或可用配置段。")
        }
    }

    private func scriptHubSubscription(for module: RelayModule) -> ScriptHubSubscriptionInfo? {
        ModuleMetadataParser.scriptHubSubscription(for: module)
    }

    private func materializeConvertedScripts(
        in content: String,
        module: RelayModule,
        converterScript: String,
        github: GitHubSettings?
    ) async throws -> (content: String, assets: [GeneratedAsset]) {
        guard let expression = Self.convertPathExpression else {
            return (content, [])
        }
        let matches = expression.matches(in: content, range: NSRange(content.startIndex..., in: content))
        let urls = matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: content) else { return nil }
            return String(content[range])
        }
        let uniqueURLs = Array(Set(urls)).sorted()
        guard !uniqueURLs.isEmpty else { return (content, []) }
        guard let github, github.isConfigured else {
            throw RelayError.invalidOutput("启用“脚本转换”后，需要先在 GitHub 发布中配置仓库，以托管转换后的脚本文件。")
        }

        var rewritten = content
        var assets: [GeneratedAsset] = []
        for source in uniqueURLs {
            try Task.checkCancellation()
            guard let requestURL = URL(string: source) else { throw RelayError.invalidServiceURL }
            let converted = try await embeddedEngine.convert(script: converterScript, requestURL: requestURL)
            guard !converted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RelayError.invalidOutput("脚本转换返回了空内容。")
            }
            let hash = String(Data(source.utf8).sha256String.prefix(12))
            let tail = source.components(separatedBy: "/_end_/").last?.components(separatedBy: "?").first ?? "script.js"
            var fileName = FilenameSanitizer.baseName(from: tail.removingPercentEncoding ?? tail)
            if fileName.isEmpty { fileName = "script.js" }
            if !fileName.lowercased().hasSuffix(".js") { fileName += ".js" }
            let relativePath = "assets/\(module.id.uuidString.lowercased())/\(hash)-\(fileName)"
            guard let remoteURL = github.publicURL(for: relativePath) else {
                throw RelayError.invalidOutput("私有仓库需要先配置 Cloudflare Worker 公共地址，才能发布转换后的脚本。")
            }
            rewritten = rewritten.replacingOccurrences(of: source, with: remoteURL.absoluteString)
            assets.append(GeneratedAsset(relativePath: relativePath, data: Data(converted.utf8)))
        }
        return (rewritten, assets)
    }
}
