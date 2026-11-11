import Foundation

actor ScriptHubClient {
    private static let convertPathExpression = try? NSRegularExpression(
        pattern: #"https?://script\.hub/convert/_start_/.*?/_end_/[^,\s\"']+"#
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
              sourceURL.isFileURL || ["http", "https"].contains(sourceURL.scheme?.lowercased()) else {
            throw RelayError.invalidSourceURL
        }

        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard trimmedBase.hasPrefix("http://") || trimmedBase.hasPrefix("https://") else {
            throw RelayError.invalidServiceURL
        }

        let source = sourceURL.absoluteString.components(separatedBy: "#").first ?? sourceURL.absoluteString
        let fileName = URL(filePath: module.outputFileName).deletingPathExtension().lastPathComponent
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "module"
        let type = module.sourceFormat == .automatic && ModuleSourceFormat.definitiveFormat(for: sourceURL) == nil
            ? "all-module" : module.sourceFormat.scriptHubType(for: sourceURL)
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "target", value: module.outputFormat == .quantumultX ? "surge-module" : module.outputFormat.scriptHubTarget)
        ] + module.scriptHubOptions.queryItems()
        guard let query = components.percentEncodedQuery else { throw RelayError.invalidServiceURL }
        let raw = "\(trimmedBase)/file/_start_/\(source)/_end_/\(fileName).\(module.outputFormat == .quantumultX ? "sgmodule" : module.outputFormat.fileExtension)?\(query)"

        guard let url = URL(string: raw) else { throw RelayError.invalidServiceURL }
        return url
    }

    func convert(module: RelayModule, github: GitHubSettings? = nil, sourceData: Data? = nil) async throws -> ConversionResult {
        var result = try await convertMeasured(module: module, github: github, sourceData: sourceData)
        result.outputFormat = module.outputFormat
        result.stageMetrics = StageMetricsContext.current?.snapshot
        return result
    }

    private func convertMeasured(module: RelayModule, github: GitHubSettings?, sourceData: Data?) async throws -> ConversionResult {
        let metrics = StageMetricsContext.current
        let started = ContinuousClock.now
        let priorDownloads = metrics?.duration(for: .download) ?? 0
        let priorConversion = metrics?.duration(for: .conversion) ?? 0
        var completed = false
        var nativeOutputBytes: Int64?
        defer {
            let nested = (metrics?.duration(for: .download) ?? 0) - priorDownloads + (metrics?.duration(for: .conversion) ?? 0) - priorConversion
            metrics?.record(StageMetric(stage: .conversion, duration: max(0, StageMetricsRecorder.elapsed(since: started) - nested),
                                        bytesWritten: nativeOutputBytes, failedAttempts: completed || Task.isCancelled ? 0 : 1,
                                        result: completed ? .completed : Task.isCancelled ? .cancelled : .failed,
                                        reason: nativeOutputBytes == nil ? "转换后处理" : "原生模块处理", isPartial: !completed))
        }
        try Task.checkCancellation()
        guard let sourceURL = URL(string: module.updateSourceURL) else { throw RelayError.invalidSourceURL }
        var sourceModule = module
        var input = sourceData
        let inspectsSource = module.sourceFormat == .automatic && ModuleSourceFormat.definitiveFormat(for: sourceURL) == nil
        if input == nil, inspectsSource || sourceURL.isFileURL || module.outputFormat.isNativeOutput(for: sourceURL, sourceFormat: module.sourceFormat) {
            if sourceURL.isFileURL {
                input = try SourceRevisionService.readLocalSource(sourceURL)
            } else {
                guard ["http", "https"].contains(sourceURL.scheme?.lowercased()) else {
                    throw RelayError.invalidSourceURL
                }
                var request = URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
                request.setValue("SurgeRelay/2.0", forHTTPHeaderField: "User-Agent")
                for header in module.scriptHubOptions.requestHeaders.components(separatedBy: .newlines) {
                    guard let split = header.firstIndex(of: ":") else { continue }
                    let name = header[..<split].trimmingCharacters(in: .whitespaces)
                    let value = header[header.index(after: split)...].trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, !value.isEmpty { request.setValue(value, forHTTPHeaderField: name) }
                }
                let (responseData, _) = try await fetchSource(request)
                input = responseData
            }
        }
        if inspectsSource, let input {
            guard let text = String(data: input, encoding: .utf8) else {
                throw RelayError.invalidOutput("来源不是有效的 UTF-8 配置文本。")
            }
            if let detected = Self.sourceFormat(in: text) { sourceModule.sourceFormat = detected }
        }
        if let data = input, (!inspectsSource || sourceModule.sourceFormat != .automatic),
           module.outputFormat.isNativeOutput(for: sourceURL, sourceFormat: sourceModule.sourceFormat) {
            guard let content = String(data: data, encoding: .utf8) else {
                throw RelayError.invalidOutput("来源不是有效的 UTF-8 模块文本。")
            }
            let namedContent = ModuleMetadataParser.applyingModuleMetadata(
                name: module.name,
                category: module.category,
                desc: module.moduleDescription,
                iconURL: module.customIconURL,
                to: content,
                outputFormat: module.outputFormat
            )
            let subscription = scriptHubSubscription(for: sourceModule)
            let subscribedContent = ModuleMetadataParser.applyingScriptHubSubscription(subscription, to: namedContent)
            let sanitized = module.outputFormat == .surge ? SurgeModuleSanitizer.sanitize(subscribedContent) : subscribedContent
            try validate(sanitized, outputFormat: module.outputFormat)
            completed = true
            nativeOutputBytes = Int64(sanitized.utf8.count)
            return ConversionResult(content: sanitized, requestURL: sourceURL, stageMetrics: metrics?.snapshot)
        }
        let url = try conversionURL(module: sourceModule, baseURL: "http://script.hub")
        let script = try await engineStore.script(named: "Rewrite-Parser.js")
        let converter = try await engineStore.script(named: "script-converter.js")
        var injectionURL = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        injectionURL?.fragment = nil
        var content = try await embeddedEngine.convert(
            script: script,
            scriptConverterScript: converter,
            requestURL: url,
            sourceData: input,
            sourceURL: injectionURL?.url
        )
        let materialized: (content: String, assets: [GeneratedAsset])
        if module.outputFormat == .quantumultX {
            content = ModuleArgumentProcessor.materialize(content, overrides: module.argumentOverrides, preservingWhitespace: true)
            let quantumult = try QuantumultXOutputConverter.convert(content)
            materialized = try await materializeQuantumultXScripts(quantumult, module: module, converterScript: converter, github: github)
        } else {
            try validate(content, outputFormat: module.outputFormat)
            materialized = try await materializeConvertedScripts(in: content, module: module, converterScript: converter, github: github)
        }
        let namedContent = ModuleMetadataParser.applyingModuleMetadata(
            name: module.name,
            category: module.category,
            desc: module.moduleDescription,
            iconURL: module.customIconURL,
            to: materialized.content,
            outputFormat: module.outputFormat
        )
        let subscription = scriptHubSubscription(for: sourceModule)
        let subscribedContent = ModuleMetadataParser.applyingScriptHubSubscription(subscription, to: namedContent)
        let sanitized = module.outputFormat == .surge ? SurgeModuleSanitizer.sanitize(subscribedContent) : subscribedContent
        try validate(sanitized, outputFormat: module.outputFormat)
        completed = true
        return ConversionResult(content: sanitized, requestURL: url, assets: materialized.assets, stageMetrics: metrics?.snapshot)
    }

    private func fetchSource(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let started = ContinuousClock.now
        var bytes: Int64?
        var status: Int?
        var failure: (any Error)?
        defer { StageMetricsContext.current?.recordDownload(since: started, bytesRead: bytes, statusCode: status, error: failure) }
        do {
            let response = try await httpClient.data(for: request)
            bytes = Int64(response.0.count)
            status = (response.1 as? HTTPURLResponse)?.statusCode
            if let http = response.1 as? HTTPURLResponse, let url = request.url,
               let retryAfter = SourceRetryAfterError.response(http, requestedURL: url) { throw retryAfter }
            guard let status, (200..<300).contains(status) else {
                throw RelayError.httpFailure(status: status ?? 0, message: String(String(decoding: response.0, as: UTF8.self).prefix(240)))
            }
            return response
        } catch { failure = error; throw error }
    }

    private static func sourceFormat(in content: String) -> ModuleSourceFormat? {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix(";") && !$0.hasPrefix("//") }
        let headers = Set(lines.filter { $0.hasPrefix("[") && $0.hasSuffix("]") }.map { $0.lowercased() })
        let loon = headers.contains("[rewrite]") || lines.contains(where: {
            $0.range(of: #"^http-(?:request|response)\s+.+\s+script-path\s*="#, options: .regularExpression) != nil
        })
        let surge = !headers.isDisjoint(with: ["[url rewrite]", "[header rewrite]", "[body rewrite]", "[map local]", "[panel]"]) || lines.contains(where: {
            $0.range(of: #"^.+?\s*=\s*type\s*="#, options: .regularExpression) != nil
        })
        let quantumult = !headers.isDisjoint(with: ["[rewrite_local]", "[filter_local]", "[task_local]"]) || lines.contains(where: {
            $0.range(of: #"^\S+\s+url\s+(?:reject|30[27]|script-|request-|response-)"#, options: .regularExpression) != nil
        })
        if loon && !surge && !quantumult { return .loon }
        if surge && !loon && !quantumult { return .surge }
        if quantumult && !loon && !surge { return .quantumultX }
        return nil
    }

    func validate(_ content: String, outputFormat: ModuleOutputFormat = .surge) throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RelayError.invalidOutput("服务器返回了空内容。") }
        if trimmed.contains("Script Hub 重写转换: ❌") || trimmed.hasPrefix("<!DOCTYPE html") {
            throw RelayError.invalidOutput(String(trimmed.prefix(240)))
        }
        let markers: [String]
        switch outputFormat {
        case .surge, .egern, .shadowrocket:
            markers = ["#!name=", "[General]", "[MITM]", "[Script]", "[URL Rewrite]", "[Header Rewrite]", "[Body Rewrite]", "[Map Local]", "[Rule]"]
        case .loon:
            markers = ["#!name=", "[General]", "[MITM]", "[Script]", "[Rewrite]", "[Rule]", "[Argument]"]
        case .stash:
            markers = ["http:", "rules:", "cron:", "tiles:", "script-providers:"]
        case .quantumultX:
            markers = ["[rewrite_local]", "[filter_local]", "[mitm]", "[task_local]", " url ", "hostname =", "hostname="]
        }
        guard markers.contains(where: trimmed.contains) else {
            throw RelayError.invalidOutput("没有检测到 \(outputFormat.title) 的有效配置内容。")
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
            guard let range = Range(match.range, in: content) else { return nil }
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
            var converted = try await embeddedEngine.convert(script: converterScript, requestURL: requestURL)
            if Self.isQuantumultXConversion(requestURL) {
                converted = QuantumultXOutputConverter.adaptingConvertedQuantumultXScript(converted)
            }
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

    private func materializeQuantumultXScripts(
        _ output: (content: String, scripts: [QuantumultXOutputConverter.Script]),
        module: RelayModule,
        converterScript: String,
        github: GitHubSettings?
    ) async throws -> (content: String, assets: [GeneratedAsset]) {
        guard !output.scripts.isEmpty else { return (output.content, []) }
        guard let github, github.isConfigured else {
            throw RelayError.invalidOutput("Quantumult X 跨格式脚本转换需要在 GitHub 发布中配置仓库，以托管转换后的脚本。")
        }
        var content = output.content
        var assets: [GeneratedAsset] = []
        for (index, script) in output.scripts.enumerated() {
            try Task.checkCancellation()
            let text: String
            switch script.content {
            case .inline(let body): text = body
            case .remote(let sourceURL, let argument):
                let original: String
                if sourceURL.host == "script.hub", sourceURL.path.contains("/convert/_start_/") {
                    let converted = try await embeddedEngine.convert(script: converterScript, requestURL: sourceURL)
                    original = Self.isQuantumultXConversion(sourceURL)
                        ? QuantumultXOutputConverter.adaptingConvertedQuantumultXScript(converted) : converted
                } else {
                    let data = try await scriptResourceData(from: sourceURL)
                    guard let body = String(data: data, encoding: .utf8) else {
                        throw RelayError.invalidOutput("Quantumult X 转换脚本不是 UTF-8 文本。")
                    }
                    original = body
                }
                text = try QuantumultXOutputConverter.adaptingScript(original, argument: argument)
            case .response(let sourceURL, let status, let headers):
                let data = try await scriptResourceData(from: sourceURL)
                text = try QuantumultXOutputConverter.responseScript(data: data, status: status, headers: headers)
            }
            let path = "assets/\(module.id.uuidString.lowercased())/qx-script-\(index + 1).js"
            guard let url = github.publicURL(for: path) else {
                throw RelayError.invalidOutput("私有仓库需要先配置 Cloudflare Worker 公共地址，才能发布 Quantumult X 转换脚本。")
            }
            content = content.replacingOccurrences(of: script.placeholder, with: url.absoluteString)
            assets.append(GeneratedAsset(relativePath: path, data: Data(text.utf8)))
        }
        return (content, assets)
    }

    private static func isQuantumultXConversion(_ url: URL) -> Bool {
        guard let argument = url.absoluteString.components(separatedBy: "/_end_/").last,
              let components = URLComponents(string: "http://relay.invalid/" + argument) else { return false }
        return components.queryItems?.first(where: { $0.name == "type" })?.value == "qx-script"
    }

    private func scriptResourceData(from sourceURL: URL) async throws -> Data {
        do {
            let (data, _) = try await fetchSource(URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60))
            return data
        } catch {
            if UpdateFailureFormatter.isActionableNetworkFailure(error) {
                throw ScriptHubResourceError(resourceURL: sourceURL, underlying: error)
            }
            throw error
        }
    }
}
