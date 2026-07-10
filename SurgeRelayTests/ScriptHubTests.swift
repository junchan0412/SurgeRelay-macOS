import Foundation
import XCTest
@testable import SurgeRelay

final class ScriptHubTests: XCTestCase {
    func testScriptHubConversionURLPreservesOriginalAddress() async throws {
        let module = RelayModule(
            name: "Test",
            sourceURL: "https://example.com/path/plugin.conf?token=abc",
            sourceFormat: .loon,
            outputFileName: "my module"
        )
        let url = try await ScriptHubClient().conversionURL(module: module, baseURL: "http://script.hub/")
        XCTAssertTrue(url.absoluteString.contains("https://example.com/path/plugin.conf?token=abc/_end_/my-module.sgmodule"))
        XCTAssertTrue(url.absoluteString.contains("type=loon-plugin"))
        XCTAssertTrue(url.absoluteString.contains("target=surge-module"))
    }

    func testScriptHubConversionURLUsesSubscribedOriginalAddress() async throws {
        let subscription = try XCTUnwrap(ModuleMetadataParser.scriptHubSubscription(in: """
        #SUBSCRIBED http://script.hub/file/_start_/https://example.com/original.conf/_end_/Demo.sgmodule?type=qx-rewrite&target=surge-module
        """))
        let module = RelayModule(
            name: "Subscribed",
            sourceURL: "https://example.com/converted.sgmodule",
            sourceFormat: .quantumultX,
            outputFileName: "Subscribed",
            scriptHubSubscription: subscription
        )

        let url = try await ScriptHubClient().conversionURL(module: module, baseURL: "http://script.hub")

        XCTAssertTrue(url.absoluteString.contains("https://example.com/original.conf/_end_/Subscribed.sgmodule"))
        XCTAssertFalse(url.absoluteString.contains("converted.sgmodule"))
    }

    func testScriptHubAdvancedOptionsAreAddedToConversionURL() async throws {
        var options = ScriptHubOptions()
        options.policy = "Proxy Group"
        options.mitmAdd = "one.example.com,two.example.com"
        options.convertAllScripts = true
        options.compatibilityOnly = true
        let module = RelayModule(
            name: "Advanced",
            sourceURL: "https://example.com/plugin.conf",
            sourceFormat: .loon,
            outputFileName: "fallback",
            scriptHubOptions: options
        )

        let url = try await ScriptHubClient().conversionURL(module: module, baseURL: "http://script.hub")
        let value = url.absoluteString
        XCTAssertTrue(value.contains("/_end_/fallback.sgmodule"))
        XCTAssertTrue(value.contains("jsc=."))
        XCTAssertTrue(value.contains("compatibilityOnly=true"))
        XCTAssertTrue(value.contains("policy=Proxy%20Group"))
        XCTAssertTrue(value.contains("hnadd=one.example.com,two.example.com"))
        XCTAssertFalse(value.contains("&n="))
        XCTAssertFalse(value.contains("category="))
        XCTAssertFalse(value.contains("icon="))
    }

    func testScriptHubUpstreamRejectsFloatingRevision() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }

        do {
            _ = try await ScriptHubUpstreamService(session: session).fetchManagedModule(
                from: "https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/main/modules/script-hub.surge.sgmodule",
                previousRevision: nil
            )
            XCTFail("floating Script-Hub revisions must be rejected")
        } catch let error as RelayError {
            XCTAssertTrue(error.localizedDescription.contains("固定 tag 或 commit"))
        }
    }

    func testScriptHubUpstreamPinsReferencedScriptsAndRecordsHashes() async throws {
        let revision = "6b4fb62240629d2fc66b08bc271f8c1f83a5dcd1"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        GitHubMockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/Script-Hub-Org/Script-Hub/\(revision)/modules/script-hub.surge.sgmodule":
                return (200, Data("""
                #!name=Script Hub
                # script.hub
                [Script]
                Script Hub: 重写转换 = type=http-request, pattern=^https?:\\/\\/script\\.hub\\/file\\/_start_\\/, script-path=https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/main/Rewrite-Parser.js, timeout=300
                """.utf8))
            case "/Script-Hub-Org/Script-Hub/\(revision)/Rewrite-Parser.js":
                return (200, Data("function rewriteParser() { return true; }".utf8))
            default:
                return (404, Data())
            }
        }

        let result = try await ScriptHubUpstreamService(session: session).fetchManagedModule(
            from: "https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/\(revision)/modules/script-hub.surge.sgmodule",
            previousRevision: nil
        )

        XCTAssertEqual(result.sourceDescription, "Script-Hub-Org/Script-Hub@\(revision)")
        XCTAssertEqual(result.upstreamRevision, revision)
        XCTAssertEqual(result.scriptHashes.keys.sorted(), ["Rewrite-Parser.js"])
        XCTAssertTrue(GitHubMockURLProtocol.requestedPaths.contains(
            "GET /Script-Hub-Org/Script-Hub/\(revision)/Rewrite-Parser.js"
        ))
    }

    func testScriptHubUpstreamRejectsChangedHashForSamePinnedRevision() async throws {
        let revision = "6b4fb62240629d2fc66b08bc271f8c1f83a5dcd1"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        var scriptBody = "first"
        GitHubMockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/Script-Hub-Org/Script-Hub/\(revision)/modules/script-hub.surge.sgmodule":
                return (200, Data("""
                #!name=Script Hub
                # script.hub
                [Script]
                Script Hub: 重写转换 = type=http-request, pattern=^https?:\\/\\/script\\.hub\\/file\\/_start_\\/, script-path=https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/main/Rewrite-Parser.js, timeout=300
                """.utf8))
            case "/Script-Hub-Org/Script-Hub/\(revision)/Rewrite-Parser.js":
                return (200, Data(scriptBody.utf8))
            default:
                return (404, Data())
            }
        }
        let service = ScriptHubUpstreamService(session: session)
        let first = try await service.fetchManagedModule(
            from: "https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/\(revision)/modules/script-hub.surge.sgmodule",
            previousRevision: nil
        )
        scriptBody = "second"

        do {
            _ = try await service.fetchManagedModule(
                from: "https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/\(revision)/modules/script-hub.surge.sgmodule",
                previousRevision: first.revision,
                previousUpstreamRevision: first.upstreamRevision,
                previousScriptHashes: first.scriptHashes
            )
            XCTFail("changed script hashes for the same pinned revision must be rejected")
        } catch let error as RelayError {
            XCTAssertTrue(error.localizedDescription.contains("脚本 hash 已变化"))
        }
    }

    func testEmbeddedScriptHubEngineBlocksPrivateHTTPBridgeHosts() async throws {
        let script = """
        $httpClient.get("http://127.0.0.1/private", function(error, response, body) {
          $done({body: String(error || "allowed")});
        });
        """

        let output = try await EmbeddedScriptHubEngine().convert(
            script: script,
            requestURL: try XCTUnwrap(URL(string: "https://example.com/demo.conf"))
        )

        XCTAssertTrue(output.contains("127.0.0.1"))
        XCTAssertFalse(output.contains("allowed"))
    }

    func testScriptHubClientConvertsLocalSurgeModule() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "Local.sgmodule")
        try Data("""
        #!name=Original
        [General]
        loglevel = notify
        """.utf8).write(to: file)
        let module = RelayModule(
            name: "Managed",
            sourceURL: file.absoluteString,
            sourceFormat: .surge,
            outputFileName: "Local",
            category: "Imported"
        )

        let result = try await ScriptHubClient().convert(module: module)

        XCTAssertEqual(result.requestURL, file)
        XCTAssertTrue(result.content.contains("#!name=Managed"))
        XCTAssertTrue(result.content.contains("#!category=Imported"))
        XCTAssertTrue(result.content.contains("loglevel = notify"))
    }

    func testScriptHubClientDoesNotWriteIconMetadataToNativeSurgeOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "Icon.sgmodule")
        try Data("""
        #!name=Original
        #!icon=https://example.com/source-icon.png
        [General]
        loglevel = notify
        """.utf8).write(to: file)
        let module = RelayModule(
            name: "Managed",
            sourceURL: file.absoluteString,
            sourceFormat: .surge,
            outputFileName: "Icon",
            category: "Imported",
            customIconURL: "https://example.com/custom-icon.png"
        )

        let result = try await ScriptHubClient().convert(module: module)

        XCTAssertTrue(result.content.contains("#!name=Managed"))
        XCTAssertTrue(result.content.contains("#!category=Imported"))
        XCTAssertFalse(result.content.localizedCaseInsensitiveContains("#!icon"))
        XCTAssertFalse(result.content.contains("https://example.com/source-icon.png"))
        XCTAssertFalse(result.content.contains("https://example.com/custom-icon.png"))
    }

    func testModuleArgumentsAreMaterializedAndArgumentMetadataIsRemoved() {
        let content = """
        #!name=Demo
        #!arguments=feature:true,mode:auto
        #!arguments-desc=feature toggle\\nmode selector
        [Script]
        %feature%disabled = type=cron, cronexp="0 0 * * *", script-path=https://example.com/a.js
        mode = %mode%
        // source note
        """
        let info = ModuleArgumentProcessor.info(in: content)
        XCTAssertEqual(info.definitions.map(\.key), ["feature", "mode"])
        XCTAssertEqual(info.helpText, "feature toggle\nmode selector")

        let result = ModuleArgumentProcessor.materialize(content, overrides: ["feature": "#", "mode": "show"])
        XCTAssertFalse(result.contains("#!arguments="))
        XCTAssertTrue(result.contains("#disabled ="))
        XCTAssertTrue(result.contains("source note"))
        XCTAssertTrue(result.contains("mode = show"))
    }

    func testLegacyArgumentsWithSpacingAndQuotedDefaultsAreMaterialized() {
        let content = """
        #!name=Maps
        #!arguments = CountryCode:"CN",Dispatcher:"AutoNavi"
        #!arguments-desc = CountryCode help
        [Script]
        maps = type=http-request,argument=CountryCode="{{{CountryCode}}}"&Dispatcher="{{{Dispatcher}}}",script-path=https://example.com/maps.js
        """

        let info = ModuleArgumentProcessor.info(in: content)
        XCTAssertEqual(info.definitions.map(\.key), ["CountryCode", "Dispatcher"])
        XCTAssertEqual(info.definitions.map(\.defaultValue), ["CN", "AutoNavi"])
        let result = ModuleArgumentProcessor.materialize(content, overrides: [:])
        XCTAssertFalse(result.contains("#!arguments"))
        XCTAssertFalse(result.contains("{{{"))
        XCTAssertTrue(result.contains("CountryCode=\"CN\"&Dispatcher=\"AutoNavi\""))
    }

    func testAdvancedOptionsSummaryOnlyAppearsWhenConfigured() {
        XCTAssertNil(ScriptHubOptions().configuredSummary)
        var options = ScriptHubOptions()
        options.policy = "Proxy"
        options.convertAllScripts = true
        XCTAssertEqual(options.configuredSummary, "脚本转换：全部 · 策略：Proxy")
    }

    func testSurgeModuleSanitizerRemovesEmptyJQAndConvertsMisplacedLoonScript() {
        let content = """
        #!name=Demo
        [Body Rewrite]
        http-response-jq ^https:\\/\\/example\\.com\\/empty\\? ''
        http-response-jq ^https:\\/\\/example\\.com\\/valid\\? '.data=[]'
        [Map Local]
        ^https:\\/\\/example\\.com\\/api url script-response-header https://example.com/scripts/clean.js
        ^https:\\/\\/example\\.com\\/blank data-type=text data="{}" status-code=200
        """

        let sanitized = SurgeModuleSanitizer.sanitize(content)

        XCTAssertFalse(sanitized.contains("example\\.com\\/empty"))
        XCTAssertTrue(sanitized.contains("http-response-jq ^https:\\/\\/example\\.com\\/valid\\? '.data=[]'"))
        XCTAssertTrue(sanitized.contains("^https:\\/\\/example\\.com\\/blank data-type=text"))
        XCTAssertTrue(sanitized.contains("[Script]"))
        XCTAssertTrue(sanitized.contains(
            "clean = type=http-response, pattern=^https:\\/\\/example\\.com\\/api, requires-body=0, script-path=https://example.com/scripts/clean.js"
        ))
        XCTAssertFalse(sanitized.contains("url script-response-header"))
        XCTAssertEqual(SurgeModuleSanitizer.sanitize(sanitized), sanitized)
    }
}
