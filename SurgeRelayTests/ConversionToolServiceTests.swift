import Foundation
import JavaScriptCore
import XCTest
@testable import SurgeRelay

final class ConversionToolServiceTests: XCTestCase {
    func testPublicDraftDefaultsOmittedFieldsAndRejectsUnknownEnums() throws {
        let draft = try JSONDecoder().decode(ConversionToolDraft.self, from: Data(#"{"sourceText":"DOMAIN,example.com"}"#.utf8))
        XCTAssertEqual(draft.kind, .ruleSet)
        XCTAssertEqual(draft.outputFormat, .surge)
        XCTAssertEqual(draft.sourceFormat, .quantumultX)
        XCTAssertEqual(draft.ruleOutputStyle, .ruleSet)
        XCTAssertEqual(draft.policy, "REJECT")
        XCTAssertFalse(draft.noResolve)
        XCTAssertThrowsError(try JSONDecoder().decode(ConversionToolDraft.self, from: Data(#"{"kind":"proxy"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(ConversionToolDraft.self, from: Data(#"{"outputFormat":"unknown"}"#.utf8)))
    }

    func testEngineAdmissionKeepsNativeScriptsLocalAndRunsActualTransformations() {
        var draft = ConversionToolDraft(kind: .script, sourceText: "$done({});", outputFormat: .quantumultX)
        XCTAssertFalse(ConversionToolService.requiresEngine(draft))
        draft.outputFormat = .egern
        XCTAssertTrue(ConversionToolService.requiresEngine(draft))
        draft.sourceFormat = .loon
        XCTAssertFalse(ConversionToolService.requiresEngine(draft))
        draft.outputFormat = .quantumultX
        XCTAssertFalse(ConversionToolService.requiresEngine(draft))
        draft.compatibilityOnly = true
        XCTAssertTrue(ConversionToolService.requiresEngine(draft))
        draft.compatibilityOnly = false
        draft.evalScriptModified = "body += '\\n// modified';"
        XCTAssertTrue(ConversionToolService.requiresEngine(draft))
        draft.kind = .ruleSet
        XCTAssertTrue(ConversionToolService.requiresEngine(draft))
    }

    func testValidationRejectsActualUnsupportedInputsBeforeEnginePreparation() {
        XCTAssertThrowsError(try ConversionToolService.validate(ConversionToolDraft()))
        var draft = ConversionToolDraft(sourceText: "DOMAIN,example.com", outputFormat: .quantumultX)
        for policy in ["", "REJECT,OTHER", "REJECT\n", "REJECT\nOTHER"] {
            draft.policy = policy
            XCTAssertThrowsError(try ConversionToolService.validate(draft))
        }
        draft.policy = "Proxy Group"
        XCTAssertNoThrow(try ConversionToolService.validate(draft))
        for format in [ModuleOutputFormat.loon, .quantumultX, .shadowrocket] {
            draft.outputFormat = format
            draft.ruleOutputStyle = .domainSet
            XCTAssertThrowsError(try ConversionToolService.validate(draft))
        }
        draft.kind = .script
        draft.sourceFormat = .automatic
        XCTAssertThrowsError(try ConversionToolService.validate(draft))
    }

    func testNativeScriptPreservesTextAndTextInputWinsOverStoredURL() async throws {
        let code = "// ❌ is script content\nconst text = '原生';\n$done({body: text});\n"
        let draft = ConversionToolDraft(kind: .script, sourceURL: "invalid saved URL", sourceText: code,
            outputName: "Native.js", outputFormat: .quantumultX)
        let result = try await ConversionToolService().convert(draft: draft)
        XCTAssertEqual(result.fileName, "Native.js")
        XCTAssertEqual(result.content, code)
        XCTAssertEqual(result.kind, .script)
        XCTAssertEqual(result.outputFormat, .quantumultX)
    }

    func testCompatibleFamilyScriptToQuantumultXUsesLocalAdapter() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = ConversionToolDraft(kind: .script, sourceText: "$done({body: 'changed'});", outputFormat: .quantumultX,
            sourceFormat: .loon, prependScript: "const configured = true;")
        let service = ConversionToolService(engineStore: EngineStore(cacheDirectory: root))
        let result = try await service.convert(draft: draft)
        XCTAssertTrue(result.content.contains("$httpClient[method]"))
        XCTAssertTrue(result.content.contains("const configured = true;"))
        XCTAssertTrue(result.content.contains("$done({body: 'changed'});"))
        XCTAssertFalse(result.content.contains("#!"))
    }

    func testQuantumultXRuleOutputHasPolicyAndNoConfigurationSections() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = EngineStore(cacheDirectory: root)
        try await engine.save(scripts: ["rule-parser.js": Data("$done({body:'#规则数量:2\\nDOMAIN,example.com\\nIP-CIDR6,::1/128,no-resolve\\n'});".utf8)])
        let draft = ConversionToolDraft(sourceText: "host,example.com,REJECT", outputName: "My.rules.list",
            outputFormat: .quantumultX, policy: "Proxy Group")
        let result = try await ConversionToolService(engineStore: engine).convert(draft: draft)
        XCTAssertEqual(result.fileName, "My.rules.list")
        XCTAssertEqual(result.content, "host, example.com, Proxy Group\nip6-cidr, ::1/128, Proxy Group\n")
        XCTAssertFalse(result.content.contains("["))
        XCTAssertThrowsError(try QuantumultXOutputConverter.ruleSet("URL-REGEX,^https://example.com", policy: "REJECT")) {
            XCTAssertTrue($0.localizedDescription.contains("模块转换"))
        }
    }

    func testRuleTargetsAndDomainStylesUseActualUpstreamNames() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = EngineStore(cacheDirectory: root)
        let script = """
        const target = $request.url.split('target=')[1].split('&')[0];
        const body = target.includes('domain-set') ? '.example.com' : target === 'stash-rule-set' ? 'payload:\\n  - DOMAIN,example.com' : 'DOMAIN,example.com';
        $done({body: body});
        """
        try await engine.save(scripts: ["rule-parser.js": Data(script.utf8)])
        let service = ConversionToolService(engineStore: engine)
        for format in ModuleOutputFormat.allCases {
            let draft = ConversionToolDraft(sourceText: "DOMAIN,example.com", outputFormat: format)
            let result = try await service.convert(draft: draft)
            XCTAssertEqual(result.fileName, "Converted.list")
            XCTAssertEqual(result.outputFormat, format)
            XCTAssertEqual(result.kind, .ruleSet)
            XCTAssertTrue(result.content.contains(format == .stash ? "payload:" : format == .quantumultX ? "host, example.com, reject" : "DOMAIN,example.com"))
        }
        for format in [ModuleOutputFormat.surge, .egern, .stash] {
            let draft = ConversionToolDraft(sourceText: "DOMAIN-SUFFIX,example.com", outputFormat: format, ruleOutputStyle: .domainSet)
            let result = try await service.convert(draft: draft)
            XCTAssertEqual(result.content, ".example.com")
        }
    }

    func testRuleAndScriptOptionsAreForwardedToTheirOwnRoutes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = EngineStore(cacheDirectory: root)
        let script = """
        const params = Object.fromEntries($request.url.split('/_end_/')[1].split('?')[1].split('&').map(item => {
          const separator = item.indexOf('=');
          return [decodeURIComponent(item.slice(0, separator)), decodeURIComponent(item.slice(separator + 1))];
        }));
        $done({body:params.target.endsWith('-script') ? 'globalThis.capturedToolQuery = ' + JSON.stringify(params) + ';' : JSON.stringify(params)});
        """
        try await engine.save(scripts: ["rule-parser.js": Data(script.utf8), "script-converter.js": Data(script.utf8)])
        let service = ConversionToolService(engineStore: engine)
        var draft = ConversionToolDraft(sourceText: "DOMAIN,example.com", includeKeywords: "example+api", excludeKeywords: "ads",
            requestHeaders: "X-Test: configured", noResolve: true, sni: "api", evalScriptOriginal: "body = body;",
            evalScriptModified: "body = body;", evalURLOriginal: "https://example.com/original.js", evalURLModified: "https://example.com/modified.js")
        let rules = try await service.convert(draft: draft)
        let ruleQuery = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rules.content.utf8)) as? [String: String])
        XCTAssertEqual(ruleQuery["type"], "rule-set")
        XCTAssertEqual(ruleQuery["target"], "surge-rule-set")
        XCTAssertEqual(ruleQuery["y"], "example+api")
        XCTAssertEqual(ruleQuery["x"], "ads")
        XCTAssertEqual(ruleQuery["nore"], "true")
        XCTAssertEqual(ruleQuery["sni"], "api")
        XCTAssertEqual(ruleQuery["evalUrlmodi"], "https://example.com/modified.js")
        XCTAssertNil(ruleQuery["prepend"])
        draft.kind = .script
        draft.wrapResponse = true
        draft.prependScript = "const prefix = true;"
        let convertedScript = try await service.convert(draft: draft)
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("var $httpClient = {};")
        context.evaluateScript(convertedScript.content)
        XCTAssertNil(context.exception, context.exception?.toString() ?? "")
        let scriptQuery = try XCTUnwrap(context.objectForKeyedSubscript("capturedToolQuery")?.toDictionary() as? [String: String])
        XCTAssertEqual(scriptQuery["type"], "qx-script")
        XCTAssertEqual(scriptQuery["target"], "surge-script")
        XCTAssertEqual(scriptQuery["wrap_response"], "true")
        XCTAssertEqual(scriptQuery["prepend"], "const prefix = true;")
        XCTAssertEqual(scriptQuery["headers"], "X-Test: configured")
        XCTAssertNil(scriptQuery["x"])
        XCTAssertNil(scriptQuery["y"])
        XCTAssertNil(scriptQuery["nore"])
        XCTAssertNil(scriptQuery["sni"])
    }

    func testLocalRuleFileUsesProvidedBytesInHelper() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "local.list")
        try Data("DOMAIN,local.example\n".utf8).write(to: source)
        let engine = EngineStore(cacheDirectory: root)
        let parser = "const source=$request.url.split('/_start_/')[1].split('/_end_/')[0]; $httpClient.get(source,(error,response,body)=>$done({body:error||body}));"
        try await engine.save(scripts: ["rule-parser.js": Data(parser.utf8)])
        let result = try await ConversionToolService(engineStore: engine).convert(draft: ConversionToolDraft(sourceURL: source.absoluteString))
        XCTAssertEqual(result.content, "DOMAIN,local.example\n")
    }

    func testBareIPv6CIDRIsNormalizedBeforeRuleHelperForTextAndRemoteSources() async throws {
        let raw = "example.com\n10.0.0.0/8\n2001:db8::/32\n::/0\n# 2001:db8::/64\nIP-CIDR6,2001:db8::/48\n"
        let expected = "example.com\n10.0.0.0/8\nIP-CIDR6,2001:db8::/32\nIP-CIDR6,::/0\n# 2001:db8::/64\nIP-CIDR6,2001:db8::/48\n"
        XCTAssertEqual(QuantumultXOutputConverter.normalizingRuleSource(raw), expected)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = EngineStore(cacheDirectory: root)
        let parser = "const source=$request.url.split('/_start_/')[1].split('/_end_/')[0]; $httpClient.get(source,(error,response,body)=>$done({body:error||body}));"
        try await engine.save(scripts: ["rule-parser.js": Data(parser.utf8)])
        let pasted = try await ConversionToolService(engineStore: engine).convert(draft: ConversionToolDraft(sourceText: raw))
        XCTAssertEqual(pasted.content, expected)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        GitHubMockURLProtocol.handler = { _ in (200, Data(raw.utf8)) }
        let remote = try await ConversionToolService(engineStore: engine, session: session).convert(draft: ConversionToolDraft(sourceURL: "https://example.com/cidr.list"))
        XCTAssertEqual(remote.content, expected)
    }

    func testSourceAndConverterHTTPFailuresNeverBecomeScriptOutput() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        GitHubMockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Test"), "configured")
            return (404, Data("Missing source".utf8))
        }
        let native = ConversionToolDraft(kind: .script, sourceURL: "https://example.com/missing.js",
            outputFormat: .quantumultX, requestHeaders: "X-Test: configured")
        do {
            _ = try await ConversionToolService(session: session).convert(draft: native)
            XCTFail("HTTP failure must not become script output")
        } catch let error as RelayError {
            guard case .httpFailure(let status, _) = error else { return XCTFail("Expected HTTP failure") }
            XCTAssertEqual(status, 404)
        }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = EngineStore(cacheDirectory: root)
        try await engine.save(scripts: ["script-converter.js": Data("$done({response:{status:500,body:'Missing converted script'}});".utf8)])
        do {
            _ = try await ConversionToolService(engineStore: engine).convert(draft: ConversionToolDraft(kind: .script, sourceText: "$done({});"))
            XCTFail("Converter failure must not become script output")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("500"))
            XCTAssertTrue(error.localizedDescription.contains("Missing converted script"))
        }
    }

    func testCancelledToolConversionDoesNotReturnCompletedOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = EngineStore(cacheDirectory: root)
        try await engine.save(scripts: ["rule-parser.js": Data("while (true) {}".utf8)])
        let service = ConversionToolService(engineStore: engine)
        let task = Task { try await service.convert(draft: ConversionToolDraft(sourceText: "DOMAIN,example.com")) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled work must not produce a result") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
