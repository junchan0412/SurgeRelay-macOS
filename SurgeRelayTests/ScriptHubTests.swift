import Foundation
import JavaScriptCore
import XCTest
@testable import SurgeRelay

final class ScriptHubTests: XCTestCase {
    func testNativeSurgeModuleBypassesConverterEvenWhenFormatIsMislabeled() async throws {
        let module = RelayModule(
            name: "Block HTTPDNS",
            sourceURL: "https://example.com/HTTPDNS.sgmodule",
            sourceFormat: .quantumultX,
            outputFileName: "HTTPDNS"
        )
        let sourceURL = try XCTUnwrap(URL(string: module.updateSourceURL))
        XCTAssertTrue(module.sourceFormat.isNativeSurgeModule(for: sourceURL))
        XCTAssertEqual(module.sourceFormat.scriptHubType(for: sourceURL), "surge-module")
    }

    func testNativeSurgeModuleConversionWritesSubscribedMarkerForRemoteSource() async throws {
        let module = RelayModule(
            name: "Lingo Duo",
            sourceURL: "https://raw.githubusercontent.com/TAKAGIVEGETA/MyScripts/refs/heads/main/lingoDuo/lingoDuo-xaM.module",
            sourceFormat: .automatic,
            outputFileName: "Lingo Duo"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        GitHubMockURLProtocol.handler = { _ in
            (200, Data("""
            #!name=Duolingo Max 解锁
            [MITM]
            hostname = %APPEND% ios-api-*.duolingo.com
            [Script]
            duolingo_max = type=http-response,pattern=^https://example.com/foo,script-path=https://example.com/foo.js
            """.utf8))
        }

        let result = try await ScriptHubClient(session: session).convert(module: module)

        XCTAssertTrue(result.content.contains("#SUBSCRIBED"))
        XCTAssertTrue(result.content.contains(
            "http://script.hub/file/_start_/https://raw.githubusercontent.com/TAKAGIVEGETA/MyScripts/refs/heads/main/lingoDuo/lingoDuo-xaM.module/_end_/Lingo-Duo.sgmodule"
        ))
        XCTAssertTrue(result.content.contains("[MITM]"))
        XCTAssertTrue(result.content.contains("[Script]"))
    }

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

    func testScriptHubConversionURLUsesCanonicalSubscribedQuery() async throws {
        let subscription = try XCTUnwrap(ModuleMetadataParser.scriptHubSubscription(in: """
        #SUBSCRIBED http://script.hub/file/_start_/https://example.com/original.conf/_end_/Demo.sgmodule?type=qx-rewrite&amp;target=surge-module&amp;del
        """))
        let module = RelayModule(
            name: "叮当猫合集",
            sourceURL: "https://example.com/converted.sgmodule",
            sourceFormat: .quantumultX,
            outputFileName: "叮当猫合集",
            scriptHubSubscription: subscription
        )

        let url = try await ScriptHubClient().conversionURL(module: module, baseURL: "http://script.hub")
        let decodedURL = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        XCTAssertTrue(url.absoluteString.contains("target=surge-module"))
        XCTAssertFalse(url.absoluteString.contains("amp%3Btarget"))
        XCTAssertTrue(decodedURL.contains("original.conf/_end_/叮当猫合集.sgmodule"))
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

    func testWorkerMetricsReturnKnownConversionWithoutInventingNetworkBytes() async throws {
        let metrics = StageMetricsRecorder()
        let output = try await StageMetricsContext.$current.withValue(metrics) {
            try await EmbeddedScriptHubEngine().convert(script: "$done({body:'measured output'});", requestURL: URL(string: "https://example.com/source")!)
        }
        XCTAssertEqual(output, "measured output")
        let conversion = try XCTUnwrap(metrics.snapshot.first { $0.stage == .conversion })
        XCTAssertGreaterThan(conversion.duration, 0)
        XCTAssertEqual(conversion.bytesWritten, Int64(output.utf8.count))
        XCTAssertFalse(conversion.isPartial)
        XCTAssertFalse(conversion.includesDownload)
        XCTAssertNil(metrics.snapshot.first { $0.stage == .download })
    }

    func testScriptWorkerIsEmbeddedAndConvertsWithoutHostJavaScriptExecution() async throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: EmbeddedScriptHubEngine.bundledWorkerURL.path))
        let engine = EmbeddedScriptHubEngine()
        let output = try await engine.convert(script: "$done({body: 'worker result'});", requestURL: URL(string: "https://example.com/source")!)
        XCTAssertEqual(output, "worker result")
        let nested = try await engine.convert(
            script: "$httpClient.get('http://script.hub/convert/_start_/example/_end_/x.js', function(error, response, body) { $done({body: body}); });",
            scriptConverterScript: "$done({body: 'nested result'});",
            requestURL: URL(string: "https://example.com/source")!
        )
        XCTAssertEqual(nested, "nested result")
    }

    func testScriptWorkerTerminatesInfiniteJavaScriptAndRecovers() async throws {
        let engine = EmbeddedScriptHubEngine(executionTimeout: .milliseconds(250))
        let started = ContinuousClock.now
        do {
            _ = try await engine.convert(script: "while (true) {}", requestURL: URL(string: "https://example.com/source")!)
            XCTFail("Infinite JavaScript must time out in the helper")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("总执行时限"))
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        let recovered = try await engine.convert(script: "$done({body: 'recovered'});", requestURL: URL(string: "https://example.com/source")!)
        XCTAssertEqual(recovered, "recovered")
    }

    func testScriptWorkerCancellationAlsoReleasesQueuedSlots() async throws {
        let engine = EmbeddedScriptHubEngine(maximumConcurrentWorkers: 1)
        let first = Task { try await engine.convert(script: "while (true) {}", requestURL: URL(string: "https://example.com/source")!) }
        try await Task.sleep(for: .milliseconds(100))
        let queued = Task { try await engine.convert(script: "$done({body: 'queued'});", requestURL: URL(string: "https://example.com/source")!) }
        try await Task.sleep(for: .milliseconds(50))
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Queued work should be cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        let started = ContinuousClock.now
        first.cancel()
        do { _ = try await first.value; XCTFail("Executing work should be cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        let recovered = try await engine.convert(script: "$done({body: 'recovered'});", requestURL: URL(string: "https://example.com/source")!)
        XCTAssertEqual(recovered, "recovered")
    }

    func testScriptWorkerReportsMissingExecutableAndScriptFailure() async throws {
        let missing = EmbeddedScriptHubEngine(workerExecutableURL: URL(filePath: "/nonexistent/SurgeRelayScriptWorker"))
        do {
            _ = try await missing.convert(script: "$done({body:'unused'});", requestURL: URL(string: "https://example.com/source")!)
            XCTFail("Missing helper must not silently fall back to host execution")
        } catch { XCTAssertTrue(error.localizedDescription.contains("helper 缺失")) }
        do {
            _ = try await EmbeddedScriptHubEngine().convert(script: "throw new Error('intentional worker failure');", requestURL: URL(string: "https://example.com/source")!)
            XCTFail("Script errors must reach the caller")
        } catch { XCTAssertTrue(error.localizedDescription.contains("intentional worker failure")) }
    }

    func testWorkerResponsePreservesRetryAfterMetadataAcrossProcessBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = SourceRetryAfterError(statusCode: 503, sourceURL: "https://example.com/source",
                                             responseURL: "https://cdn.example.com/source", retryAt: Date(timeIntervalSince1970: 2_000_000_000))
        let response = ScriptHubWorkerResponse(succeeded: false, error: "limited", retryAfter: expected)
        let json = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        let executable = root.appending(path: "retry-after-helper")
        try Data("#!/bin/sh\ncat > \"$1/response.json\" <<'RESPONSE'\n\(json)\nRESPONSE\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        do {
            _ = try await EmbeddedScriptHubEngine(workerExecutableURL: executable).convert(script: "", requestURL: URL(string: expected.sourceURL)!)
            XCTFail("The helper's retry deadline must survive transport")
        } catch let error as SourceRetryAfterError { XCTAssertEqual(error, expected) }
    }

    func testScriptWorkerReportsAbnormalProcessExit() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "failed-helper")
        try Data("#!/bin/sh\nexit 7\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        do {
            _ = try await EmbeddedScriptHubEngine(workerExecutableURL: executable).convert(
                script: "", requestURL: URL(string: "https://example.com/source")!
            )
            XCTFail("Abnormal helper exit must be reported")
        } catch { XCTAssertTrue(error.localizedDescription.contains("异常退出（7）")) }
    }

    func testScriptWorkerRejectsOversizedOutput() async throws {
        do {
            _ = try await EmbeddedScriptHubEngine().convert(
                script: "$done({body: 'x'.repeat(20 * 1024 * 1024 + 1)});",
                requestURL: URL(string: "https://example.com/source")!
            )
            XCTFail("Oversized output must be rejected before writing its result file")
        } catch { XCTAssertTrue(error.localizedDescription.contains("输出超过 20 MB")) }
    }

    func testScriptWorkerKillsHelperThatIgnoresTermination() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "unresponsive-helper")
        let ready = root.appending(path: "ready")
        try Data("#!/bin/sh\ntrap '' TERM\nprintf ready > '\(ready.path)'\nwhile :; do :; done\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let engine = EmbeddedScriptHubEngine(workerExecutableURL: executable, executionTimeout: .seconds(15))
        let task = Task { try await engine.convert(script: "", requestURL: URL(string: "https://example.com/source")!) }
        defer { task.cancel() }
        let readinessDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < readinessDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard FileManager.default.fileExists(atPath: ready.path) else {
            task.cancel()
            _ = try? await task.value
            XCTFail("Fixture did not install its SIGTERM handler; cancellation timing was not measured")
            return
        }
        let started = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; XCTFail("Unresponsive helper must be killed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(400))
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
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

    func testEmbeddedScriptHubEngineKeepsLiteralBenchmarkAddressBlocked() async throws {
        let script = """
        $httpClient.get("http://198.18.1.49/private", function(error, response, body) {
          $done({body: String(error || "allowed")});
        });
        """

        let output = try await EmbeddedScriptHubEngine().convert(
            script: script,
            requestURL: try XCTUnwrap(URL(string: "https://example.com/demo.conf"))
        )

        XCTAssertTrue(output.contains("198.18.1.49"))
        XCTAssertFalse(output.contains("allowed"))
    }

    func testEmbeddedScriptHubEngineAllowsSurgeFakeIPForResolvedHostname() {
        XCTAssertFalse(EmbeddedScriptHubEngine.isBlockedResolvedIPv4(ipv4(198, 18, 1, 49)))
        XCTAssertFalse(EmbeddedScriptHubEngine.isBlockedResolvedIPv4(ipv4(198, 19, 255, 254)))
        XCTAssertTrue(EmbeddedScriptHubEngine.isBlockedResolvedIPv4(ipv4(192, 168, 1, 1)))
        XCTAssertTrue(EmbeddedScriptHubEngine.isBlockedResolvedIPv4(ipv4(127, 0, 0, 1)))
    }

    func testEmbeddedScriptHubEngineDoesNotAttachUndefinedBodyToGETRequest() throws {
        let context = try XCTUnwrap(JSContext())
        let value = try XCTUnwrap(context.evaluateScript("({url: 'https://example.com/source.js'})"))

        let request = try EmbeddedScriptHubEngine.makeRequest(method: "GET", value: value)

        XCTAssertNil(request.httpBody)
    }

    func testEmbeddedScriptHubEnginePreservesExplicitRequestBody() throws {
        let context = try XCTUnwrap(JSContext())
        let value = try XCTUnwrap(context.evaluateScript("({url: 'https://example.com/api', body: 'payload'})"))

        let request = try EmbeddedScriptHubEngine.makeRequest(method: "POST", value: value)

        XCTAssertEqual(request.httpBody, Data("payload".utf8))
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

    func testScriptHubClientWritesCustomIconToNativeSurgeOutput() async throws {
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
        XCTAssertTrue(result.content.contains("#!icon=https://example.com/custom-icon.png"))
        XCTAssertFalse(result.content.contains("https://example.com/source-icon.png"))
    }

    func testScriptHubClientPreservesSourceIconWithoutCustomIcon() async throws {
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
            category: "Imported"
        )

        let result = try await ScriptHubClient().convert(module: module)

        XCTAssertTrue(result.content.contains("#!name=Managed"))
        XCTAssertTrue(result.content.contains("#!category=Imported"))
        XCTAssertTrue(result.content.contains("#!icon=https://example.com/source-icon.png"))
    }

    private func ipv4(_ first: UInt32, _ second: UInt32, _ third: UInt32, _ fourth: UInt32) -> UInt32 {
        (first << 24) | (second << 16) | (third << 8) | fourth
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
