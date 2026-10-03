import XCTest
import Network
import Observation
import Darwin
@testable import SurgeRelay

final class WebManagementHTTPTests: XCTestCase {
    @MainActor
    func testProductionWebLoadBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["SURGE_RELAY_WEB_LOAD_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in production Web load benchmark; set SURGE_RELAY_WEB_LOAD_BENCHMARK=1")
        }
        if let expected = ProcessInfo.processInfo.environment["SURGE_RELAY_WEB_LOAD_EXPECTED_HOST"] {
            let actual = Bundle.main.executableURL?.standardizedFileURL.resolvingSymlinksInPath()
            guard actual == URL(filePath: expected).standardizedFileURL.resolvingSymlinksInPath() else {
                throw NSError(domain: "WebLoadBenchmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unexpected test host: \(actual?.path ?? "unknown")"])
            }
        }
        XCTAssertGreaterThan(webLoadRSS(), 0)
        var samples: [WebLoadSample] = []
        for requested in [1, 3, 10] {
            let root = FileManager.default.temporaryDirectory.appending(path: "SurgeRelay-web-load-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: root) }
            let context = WorkspaceContext(id: UUID(), name: "Web load benchmark", configurationDirectory: root.appending(path: "configuration"),
                                           cacheDirectory: root.appending(path: "cache"), allowsLegacyFallback: false)
            let model = AppModel(context: context, persistsOnInit: false)
            model.settings.publishToLocal = false
            model.settings.publishToGitHub = false
            model.settings.refreshIntervalMinutes = 0
            model.settings.combinedModuleEnabled = true
            model.settings.localModuleDirectory = root.appending(path: "outputs").path
            model.settings.github.owner = "benchmark-owner"
            model.settings.github.repository = "benchmark-repository"
            let fixtureDate = Date(timeIntervalSince1970: 1_700_000_000)
            model.modules = (0..<5_000).map { index in
                RelayModule(name: String(format: "Module %05d", index), sourceURL: "https://benchmark.invalid/module-\(index).sgmodule",
                            outputFileName: "Module-\(index)", moduleDescription: "Production state projection fixture",
                            isEnabled: index.isMultiple(of: 2), createdAt: fixtureDate, lastUpdatedAt: fixtureDate, state: .current)
            }
            let probe = WebLoadEncodingProbe()
            let server = model.webServer
            defer { server.stop() }
            let token = UUID().uuidString
            func startServer() throws {
                let source = WebManagementSnapshotSource(model: model)
                let encoder = WebManagementJSONEncoder()
                try server.start(configuration: WebServerConfiguration(port: 0, allowRemoteAccess: false, accessToken: token),
                                 stateHandler: { _ in }, eventProvider: { legacy in try await probe.payload(source: source, encoder: encoder, legacy: legacy) },
                                 requestHandler: { [weak model] request in
                                     guard let model else { return .error(status: 500, message: "Stopped") }
                                     return await WebManagementAPI.response(for: request, model: model)
                                 })
            }
            try startServer()
            try await webLoadWait { server.listeningPort != nil }
            var clients = (0..<requested).map { _ in WebLoadClient(port: server.listeningPort!, token: token) }
            samples.append(try await webLoadMeasure("connect", requested: requested, probe: probe, clients: clients) {
                try await webLoadReady(clients, requested: requested)
                return 0
            })
            XCTAssertGreaterThan(probe.latestPayloadBytes, 500_000)
            let idle = try await webLoadMeasure("idle", requested: requested, probe: probe, clients: clients) {
                try await webLoadWindow(seconds: 3)
            }
            samples.append(idle)
            XCTAssertEqual(idle.eventEncodes, 0)
            XCTAssertEqual(idle.completedStateFrames, 0)
            model.beginWork(.updatingModules)
            model.synchronizationTotalCount = 5_000
            model.synchronizingModuleIDs = Set(model.modules.prefix(4).map(\.id))
            samples.append(try await webLoadMeasure("busy_activity", requested: requested, probe: probe, clients: clients) {
                try await webLoadWindow(seconds: 4) { tick in
                    model.synchronizationCompletedCount = tick * 4
                    model.statusMessage = "web-load-activity-\(tick)"
                }
            })
            samples.append(try await webLoadMeasure("busy_modules", requested: requested, probe: probe, clients: clients) {
                try await webLoadWindow(seconds: 4) { tick in
                    model.modules[tick % model.modules.count].state = .updating
                    model.synchronizationCompletedCount += 1
                    model.statusMessage = "web-load-modules-\(tick)"
                }
            })
            for index in model.modules.indices where model.modules[index].state == .updating { model.modules[index].state = .current }
            model.synchronizingModuleIDs = []
            model.endWork(.updatingModules)
            clients.forEach { $0.close() }
            try await webLoadWait { clients.allSatisfy(\.ended) }
            try await Task.sleep(for: .milliseconds(1_100))
            let hiddenMarker = "web-load-hidden-\(requested)"
            model.statusMessage = hiddenMarker
            let hidden = try await webLoadMeasure("hidden_disconnected", requested: requested, probe: probe, clients: clients) {
                try await webLoadWindow(seconds: 2)
            }
            samples.append(hidden)
            XCTAssertEqual(hidden.eventCallbacks, 0)
            XCTAssertEqual(hidden.eventEncodes, 0)
            XCTAssertEqual(hidden.receivedApplicationBytes, 0)
            let hiddenHTTP = WebLoadClient(port: server.listeningPort!, token: token, path: "/api/activity")
            try await webLoadWait { hiddenHTTP.ended }
            XCTAssertEqual(hiddenHTTP.status, 200)
            clients = (0..<requested).map { _ in WebLoadClient(port: server.listeningPort!, token: token, marker: hiddenMarker) }
            samples.append(try await webLoadMeasure("reconnect", requested: requested, probe: probe, clients: clients) {
                try await webLoadReady(clients, requested: requested)
                XCTAssertTrue(clients.filter { $0.status == 200 }.allSatisfy(\.markerSeen))
                return 0
            })
            let previousPort = server.listeningPort!
            samples.append(try await webLoadMeasure("stop", requested: requested, probe: probe, clients: clients) {
                server.stop()
                try await webLoadWait { clients.allSatisfy(\.ended) }
                return 0
            })
            try await Task.sleep(for: .milliseconds(1_100))
            XCTAssertNil(server.listeningPort)
            let refused = WebLoadClient(port: previousPort, token: token, path: "/api/state")
            try await webLoadWait { refused.ended }
            XCTAssertNotEqual(refused.status, 200)
            model.statusMessage = "web-load-stopped-\(requested)"
            let stopped = try await webLoadMeasure("stopped", requested: requested, probe: probe, clients: clients) {
                try await webLoadWindow(seconds: 2)
            }
            samples.append(stopped)
            XCTAssertEqual(stopped.eventCallbacks, 0)
            XCTAssertEqual(stopped.eventEncodes, 0)
            XCTAssertEqual(stopped.receivedApplicationBytes, 0)
            try startServer()
            try await webLoadWait { server.listeningPort != nil }
            clients = (0..<requested).map { _ in WebLoadClient(port: server.listeningPort!, token: token, marker: "web-load-stopped-\(requested)") }
            samples.append(try await webLoadMeasure("restart", requested: requested, probe: probe, clients: clients) {
                try await webLoadReady(clients, requested: requested)
                XCTAssertTrue(clients.filter { $0.status == 200 }.allSatisfy(\.markerSeen))
                return 0
            })
            server.stop()
            clients.forEach { $0.close() }
        }
        let report = WebLoadReport(createdAt: .now, actualExecutablePath: Bundle.main.executableURL?.path ?? "unknown",
                                   testBundlePath: Bundle(for: WebManagementHTTPTests.self).bundleURL.path,
                                   processID: getpid(), os: ProcessInfo.processInfo.operatingSystemVersionString,
                                   processorCount: ProcessInfo.processInfo.processorCount,
                                   physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, samples: samples)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "production-web-5000-module-load"
        attachment.lifetime = .keepAlways
        add(attachment)
        let path = ProcessInfo.processInfo.environment["SURGE_RELAY_WEB_LOAD_OUTPUT"]
            ?? FileManager.default.temporaryDirectory.appending(path: "SurgeRelay-web-load-\(UUID().uuidString).json").path
        let output = URL(filePath: path)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
        print("WEB_LOAD_BENCHMARK_OUTPUT=\(output.path)")
    }

    @MainActor
    func testSplitSnapshotActivityDoesNotRebuildCoreAndLegacyRemainsCurrent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(context: WorkspaceContext(id: UUID(), name: "SSE test", configurationDirectory: root,
            cacheDirectory: root.appending(path: "cache"), allowsLegacyFallback: false), persistsOnInit: false)
        model.modules = [RelayModule(name: "First", sourceURL: "https://example.invalid/a", outputFileName: "First")]
        let source = WebManagementSnapshotSource(model: model)
        let encoder = WebManagementJSONEncoder()
        let initial = try source.snapshot(includingLegacy: false)
        let first = try await encoder.encode(initial)
        model.statusMessage = "activity-only-change"
        model.synchronizationCompletedCount = 4
        let changed = try source.snapshot(includingLegacy: false)
        XCTAssertEqual(changed.state.revision, initial.state.revision)
        XCTAssertGreaterThan(changed.activity.revision, initial.activity.revision)
        let second = try await encoder.encode(changed)
        XCTAssertEqual(second.state.data, first.state.data)
        XCTAssertNil(second.legacyState)
        XCTAssertTrue(String(decoding: second.activity!.data, as: UTF8.self).contains("activity-only-change"))
        let legacy = try await encoder.encode(source.snapshot(includingLegacy: true))
        XCTAssertEqual(legacy.state.data, first.state.data)
        XCTAssertTrue(String(decoding: legacy.legacyState!.data, as: UTF8.self).contains("activity-only-change"))
        model.modules[0].name = "Changed core"
        let core = try source.snapshot(includingLegacy: true)
        XCTAssertGreaterThan(core.state.revision, initial.state.revision)
        let current = try await encoder.encode(core)
        let older = try await encoder.encode(initial)
        XCTAssertEqual(older.state.data, current.state.data)
        XCTAssertEqual(older.activity?.data, current.activity?.data)
        XCTAssertNil(older.legacyState)
        let request = WebHTTPRequest(method: "GET", path: "/api/state", query: [:], headers: [:], body: Data(), isLoopback: true)
        let response = await WebManagementAPI.response(for: request, model: model)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(json["runtimeID"] as? String, model.runtimeID.uuidString)
        let httpRevision = try XCTUnwrap(json["revision"] as? UInt64)
        XCTAssertGreaterThan(httpRevision, core.state.revision)
        model.statusMessage = "after-http"
        XCTAssertGreaterThan(try source.snapshot(includingLegacy: false).activity.revision, httpRevision)
    }

    @MainActor
    func testRawSnapshotKeepsCapturedModulesAndActivityWithoutMainActorProjection() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(context: WorkspaceContext(id: UUID(), name: "Atomic input", configurationDirectory: root,
            cacheDirectory: root.appending(path: "cache"), allowsLegacyFallback: false), persistsOnInit: false)
        model.modules = [RelayModule(name: "Captured module", sourceURL: "https://example.invalid/a", outputFileName: "Captured")]
        model.statusMessage = "captured-status"
        let snapshot = WebManagementSnapshotSource.capture(model: model)
        XCTAssertNil(model.cachedModuleSummary)
        model.modules[0].name = "New module"
        model.statusMessage = "new-status"
        let encoder = WebManagementJSONEncoder()
        let data = try await encoder.encodeState(snapshot)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let modules = try XCTUnwrap(json["modules"] as? [[String: Any]])
        let activity = try XCTUnwrap(json["activity"] as? [String: Any])
        XCTAssertEqual(modules.first?["name"] as? String, "Captured module")
        XCTAssertEqual(activity["status"] as? String, "captured-status")
        XCTAssertEqual(json["revision"] as? UInt64, snapshot.state.revision)
        XCTAssertNil(model.cachedModuleSummary)
    }

    @MainActor
    func testCancelledSnapshotEncodingDoesNotStartQueuedWork() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(context: WorkspaceContext(id: UUID(), name: "Cancellation", configurationDirectory: root,
            cacheDirectory: root.appending(path: "cache"), allowsLegacyFallback: false), persistsOnInit: false)
        let snapshot = try WebManagementSnapshotSource(model: model).snapshot(includingLegacy: false)
        let encoder = WebManagementJSONEncoder()
        let task = Task { try await encoder.encode(snapshot) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled encoder should throw") }
        catch is CancellationError { }
    }

    @MainActor
    func testSplitStreamStartsWithFullThenActivityAndLegacyReceivesLiveFull() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(context: WorkspaceContext(id: UUID(), name: "Streams", configurationDirectory: root,
            cacheDirectory: root.appending(path: "cache"), allowsLegacyFallback: false), persistsOnInit: false)
        let source = WebManagementSnapshotSource(model: model)
        let encoder = WebManagementJSONEncoder()
        let server = WebManagementServer(eventInterval: .milliseconds(25))
        defer { server.stop() }
        try server.start(configuration: WebServerConfiguration(port: 0, allowRemoteAccess: false, accessToken: "test-only-token"),
            stateHandler: { _ in }, eventProvider: { legacy in
                try await encoder.encode(source.snapshot(includingLegacy: legacy))
            }, requestHandler: { _ in .json(["ready": true]) })
        try await webLoadWait { server.listeningPort != nil }
        let port = try XCTUnwrap(server.listeningPort)
        let split = LoopbackHTTPClient(port: port, request: eventStreamRequest.replacingOccurrences(of: "/api/events", with: "/api/events?activity=1"))
        defer { split.cancel() }
        try await webLoadWait { split.text.contains("event: activity") }
        XCTAssertLessThan(try XCTUnwrap(split.text.range(of: "event: state")?.lowerBound),
                          try XCTUnwrap(split.text.range(of: "event: activity")?.lowerBound))
        let legacy = LoopbackHTTPClient(port: port, request: eventStreamRequest)
        defer { legacy.cancel() }
        try await webLoadWait { legacy.text.contains("event: state") }
        model.statusMessage = "split-live-marker"
        try await webLoadWait { split.text.contains("split-live-marker") && legacy.text.contains("split-live-marker") }
        XCTAssertEqual(split.text.components(separatedBy: "event: state").count - 1, 1)
        XCTAssertFalse(legacy.text.contains("event: activity"))
        XCTAssertGreaterThanOrEqual(legacy.text.components(separatedBy: "event: state").count - 1, 2)
    }

    @MainActor
    func testEventPayloadCacheOnlyEncodesAfterObservedStateChanges() {
        let state = WebObservableTestState()
        var encodes = 0
        let cache = WebEventPayloadCache {
            encodes += 1
            return "\(state.moduleName)|\(state.progress)|\(state.isWorking)"
        }
        XCTAssertEqual(encodes, 0)
        XCTAssertEqual(cache.payload(), "first|0|false")
        for _ in 0..<100 { _ = cache.payload() }
        XCTAssertEqual(encodes, 1)
        state.unrelated = "not projected"
        XCTAssertEqual(cache.payload(), "first|0|false")
        XCTAssertEqual(encodes, 1)
        state.moduleName = "second"
        state.progress = 50
        state.isWorking = true
        XCTAssertEqual(cache.payload(), "second|50|true")
        XCTAssertEqual(encodes, 2)
        state.progress = 100
        XCTAssertEqual(cache.payload(), "second|100|true")
        XCTAssertEqual(encodes, 3)
    }

    func testLoopbackServerStopsActiveConnectionsAndCanRestart() async throws {
        let server = WebManagementServer(eventInterval: .milliseconds(25))
        defer { server.stop() }
        try startLoopbackServer(server)
        try await waitForHTTPCondition { server.listeningPort != nil }
        let port = try XCTUnwrap(server.listeningPort)
        let stream = LoopbackHTTPClient(port: port, request: eventStreamRequest)
        let partial = LoopbackHTTPClient(port: port, request: "GET /api/state HTTP/1.1\r\n")
        defer { stream.cancel(); partial.cancel() }
        try await waitForHTTPCondition { stream.text.contains("event: state") && partial.connected }
        server.stop()
        XCTAssertNil(server.listeningPort)
        try await waitForHTTPCondition { stream.ended && partial.ended }
        let refused = LoopbackHTTPClient(port: port, request: stateRequest)
        defer { refused.cancel() }
        try await waitForHTTPCondition { refused.ended }
        XCTAssertFalse(refused.text.contains("200 OK"))

        try startLoopbackServer(server)
        try await waitForHTTPCondition { server.listeningPort != nil }
        let restarted = LoopbackHTTPClient(port: try XCTUnwrap(server.listeningPort), request: stateRequest)
        defer { restarted.cancel() }
        try await waitForHTTPCondition { restarted.ended }
        XCTAssertTrue(restarted.text.contains("200 OK"))
        XCTAssertTrue(restarted.text.contains("ready"))
    }

    func testMultipleEventClientsShareOnePayloadGenerationAndStopProducer() async throws {
        let counter = WebEventCounter()
        let server = WebManagementServer(eventInterval: .milliseconds(60))
        defer { server.stop() }
        try startLoopbackServer(server, eventHandler: { await counter.nextPayload() })
        try await waitForHTTPCondition { server.listeningPort != nil }
        let port = try XCTUnwrap(server.listeningPort)
        let clients = (0..<3).map { _ in LoopbackHTTPClient(port: port, request: eventStreamRequest) }
        defer { clients.forEach { $0.cancel() } }
        try await waitForHTTPCondition { clients.allSatisfy { $0.text.contains("data: {\"tick\":5}") } }
        server.stop()
        try await waitForHTTPCondition { clients.allSatisfy(\.ended) }
        let stoppedCount = await counter.count
        try await Task.sleep(for: .milliseconds(150))
        let finalCount = await counter.count
        XCTAssertEqual(finalCount, stoppedCount)
    }

    func testClosingLastEventClientStopsProducerWithoutStoppingHTTP() async throws {
        let counter = WebEventCounter()
        let server = WebManagementServer(eventInterval: .milliseconds(25))
        defer { server.stop() }
        try startLoopbackServer(server, eventHandler: { await counter.nextPayload() })
        try await waitForHTTPCondition { server.listeningPort != nil }
        let initialCount = await counter.count
        XCTAssertEqual(initialCount, 0)
        let port = try XCTUnwrap(server.listeningPort)
        let stream = LoopbackHTTPClient(port: port, request: eventStreamRequest)
        defer { stream.cancel() }
        try await waitForHTTPCondition { stream.text.contains("event: state") }
        stream.cancel()
        try await waitForHTTPCondition { stream.ended }
        try await Task.sleep(for: .milliseconds(100))
        let stoppedCount = await counter.count
        try await Task.sleep(for: .milliseconds(100))
        let finalCount = await counter.count
        XCTAssertEqual(finalCount, stoppedCount)
        let ordinary = LoopbackHTTPClient(port: port, request: stateRequest)
        defer { ordinary.cancel() }
        try await waitForHTTPCondition { ordinary.ended }
        XCTAssertTrue(ordinary.text.contains("200 OK"))
    }

    func testStoppingServerCancelsInFlightRequestHandler() async throws {
        let pending = WebPendingRequestState()
        let server = WebManagementServer()
        defer { server.stop() }
        try startLoopbackServer(server, requestHandler: { _ in await pending.response() })
        try await waitForHTTPCondition { server.listeningPort != nil }
        let client = LoopbackHTTPClient(port: try XCTUnwrap(server.listeningPort), request: stateRequest)
        defer { client.cancel() }
        try await waitForHTTPCondition { await pending.started }
        server.stop()
        try await waitForHTTPCondition { await pending.cancelled }
        try await waitForHTTPCondition { client.ended }
        XCTAssertFalse(client.text.contains("200 OK"))
    }

    func testStoppingServerCancelsPendingEventProvider() async throws {
        let pending = WebPendingRequestState()
        let server = WebManagementServer()
        defer { server.stop() }
        try server.start(configuration: WebServerConfiguration(port: 0, allowRemoteAccess: false, accessToken: "test-only-token"),
            stateHandler: { _ in }, eventProvider: { _ in
                let response = await pending.response()
                let message = WebEventMessage(data: response.body, revision: 1)
                return WebEventPayload(state: message, activity: nil, legacyState: message)
            }, requestHandler: { _ in .json(["ready": true]) })
        try await waitForHTTPCondition { server.listeningPort != nil }
        let client = LoopbackHTTPClient(port: try XCTUnwrap(server.listeningPort), request: eventStreamRequest)
        defer { client.cancel() }
        try await waitForHTTPCondition { await pending.started }
        server.stop()
        try await waitForHTTPCondition { await pending.cancelled }
        try await waitForHTTPCondition { client.ended }
        XCTAssertFalse(client.text.contains("event: state"))
    }

    func testIncompleteRequestDeadlineReleasesConnection() async throws {
        let server = WebManagementServer(maximumConnections: 1, requestReadTimeout: 0.1)
        defer { server.stop() }
        try startLoopbackServer(server)
        try await waitForHTTPCondition { server.listeningPort != nil }
        let port = try XCTUnwrap(server.listeningPort)
        let partial = LoopbackHTTPClient(port: port, request: "POST /api/state HTTP/1.1\r\nContent-Length: 100\r\n\r\nx")
        defer { partial.cancel() }
        try await waitForHTTPCondition { partial.ended }
        XCTAssertFalse(partial.text.contains("200 OK"))
        let next = LoopbackHTTPClient(port: port, request: stateRequest)
        defer { next.cancel() }
        try await waitForHTTPCondition { next.ended }
        XCTAssertTrue(next.text.contains("200 OK"))
    }

    func testEventStreamLimitPreservesOrdinaryHTTPAccessAndReleasesSlots() async throws {
        let server = WebManagementServer(maximumEventStreams: 1, eventInterval: .milliseconds(25))
        defer { server.stop() }
        try startLoopbackServer(server)
        try await waitForHTTPCondition { server.listeningPort != nil }
        let port = try XCTUnwrap(server.listeningPort)
        let first = LoopbackHTTPClient(port: port, request: eventStreamRequest)
        defer { first.cancel() }
        try await waitForHTTPCondition { first.text.contains("event: state") }
        let excess = LoopbackHTTPClient(port: port, request: eventStreamRequest)
        defer { excess.cancel() }
        try await waitForHTTPCondition { excess.ended }
        XCTAssertTrue(excess.text.contains("503"))
        let ordinary = LoopbackHTTPClient(port: port, request: stateRequest)
        defer { ordinary.cancel() }
        try await waitForHTTPCondition { ordinary.ended }
        XCTAssertTrue(ordinary.text.contains("200 OK"))
        first.cancel()
        try await waitForHTTPCondition { first.ended }
        let replacement = LoopbackHTTPClient(port: port, request: eventStreamRequest)
        defer { replacement.cancel() }
        try await waitForHTTPCondition { replacement.text.contains("event: state") }
    }

    func testConnectionLimitRejectsAdditionalSockets() async throws {
        let server = WebManagementServer(maximumConnections: 2, eventInterval: .milliseconds(25))
        defer { server.stop() }
        try startLoopbackServer(server)
        try await waitForHTTPCondition { server.listeningPort != nil }
        let port = try XCTUnwrap(server.listeningPort)
        let clients = (0..<2).map { _ in LoopbackHTTPClient(port: port, request: eventStreamRequest) }
        defer { clients.forEach { $0.cancel() } }
        try await waitForHTTPCondition { clients.allSatisfy { $0.text.contains("event: state") } }
        let excess = LoopbackHTTPClient(port: port, request: stateRequest)
        defer { excess.cancel() }
        try await waitForHTTPCondition { excess.ended }
        XCTAssertFalse(excess.text.contains("200 OK"))
    }

    func testErrorPayloadIncludesUserFacingMessage() throws {
        let response = WebHTTPResponse.error(status: 409, message: "该模块已经添加，不能重复添加。")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: String])

        XCTAssertEqual(response.status, 409)
        XCTAssertEqual(payload["message"], "该模块已经添加，不能重复添加。")
    }

    func testRequestParserReadsJSONBodyAndQuery() throws {
        let body = #"{"enabled":true}"#
        let request = """
        POST /api/modules/demo/enabled?source=web HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """
        let parsed = try XCTUnwrap(WebManagementServer.parseRequest(Data(request.utf8), isLoopback: true))
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/api/modules/demo/enabled")
        XCTAssertEqual(parsed.query["source"], "web")
        XCTAssertEqual(String(data: parsed.body, encoding: .utf8), body)
        XCTAssertTrue(parsed.isLoopback)
    }

    func testRequestParserRejectsInvalidContentLength() {
        let negative = "POST /api/update-all HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: -1\r\n\r\n"
        let huge = "POST /api/update-all HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 999999999\r\n\r\n"

        guard case .invalid = WebManagementServer.parseRequestResult(Data(negative.utf8), isLoopback: true) else {
            return XCTFail("negative Content-Length must be invalid")
        }
        guard case .invalid = WebManagementServer.parseRequestResult(Data(huge.utf8), isLoopback: true) else {
            return XCTFail("oversized Content-Length must be invalid")
        }
    }

    func testRequestParserDistinguishesIncompleteBodyFromInvalidLength() {
        let request = """
        POST /api/update-all HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Length: 12\r
        \r
        short
        """

        guard case .incomplete = WebManagementServer.parseRequestResult(Data(request.utf8), isLoopback: true) else {
            return XCTFail("valid Content-Length with partial body should remain incomplete")
        }
    }

    func testResponseSecurityAddsNoStoreAndBrowserHardeningHeadersToAPIResponses() {
        let request = WebHTTPRequest(
            method: "GET",
            path: "/api/state",
            query: [:],
            headers: [:],
            body: Data(),
            isLoopback: true
        )
        let headers = WebResponseSecurity.hardenedHeaders(
            for: request,
            responseHeaders: ["Content-Type": "application/json; charset=utf-8"]
        )

        XCTAssertEqual(headers["Cache-Control"], WebResponseSecurity.apiCacheControl)
        XCTAssertEqual(headers["Pragma"], "no-cache")
        XCTAssertEqual(headers["Expires"], "0")
        XCTAssertEqual(headers["X-Frame-Options"], "DENY")
        XCTAssertEqual(headers["X-Content-Type-Options"], "nosniff")
        XCTAssertEqual(headers["Referrer-Policy"], "no-referrer")
        XCTAssertEqual(headers["Permissions-Policy"], "camera=(), microphone=(), geolocation=()")
        XCTAssertEqual(headers["Cross-Origin-Opener-Policy"], "same-origin")
    }

    func testResponseSecurityPreservesExplicitCacheControl() {
        let request = WebHTTPRequest(
            method: "GET",
            path: "/api/modules/11111111-1111-1111-1111-111111111111/icon",
            query: [:],
            headers: [:],
            body: Data(),
            isLoopback: true
        )
        let headers = WebResponseSecurity.hardenedHeaders(
            for: request,
            responseHeaders: ["cache-control": "private, max-age=3600"]
        )

        XCTAssertEqual(headers["cache-control"], "private, max-age=3600")
        XCTAssertNil(headers["Cache-Control"])
        XCTAssertNil(headers["Pragma"])
        XCTAssertNil(headers["Expires"])
        XCTAssertEqual(headers["X-Frame-Options"], "DENY")
    }

    func testResponseSecurityHardensEventStreamHeaders() {
        let headers = WebResponseSecurity.eventStreamHeaders()

        XCTAssertEqual(headers["Content-Type"], "text/event-stream; charset=utf-8")
        XCTAssertEqual(headers["Cache-Control"], WebResponseSecurity.eventStreamCacheControl)
        XCTAssertEqual(headers["Pragma"], "no-cache")
        XCTAssertEqual(headers["Expires"], "0")
        XCTAssertEqual(headers["Connection"], "keep-alive")
        XCTAssertEqual(headers["X-Frame-Options"], "DENY")
        XCTAssertEqual(headers["X-Content-Type-Options"], "nosniff")
        XCTAssertEqual(headers["Referrer-Policy"], "no-referrer")
    }
}

private let eventStreamRequest = "GET /api/events HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer test-only-token\r\n\r\n"
private let stateRequest = "GET /api/state HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer test-only-token\r\n\r\n"

private func startLoopbackServer(
    _ server: WebManagementServer,
    eventHandler: @escaping WebManagementServer.EventHandler = { "{\"ready\":true}" },
    requestHandler: @escaping WebManagementServer.RequestHandler = { _ in .json(["ready": true]) }
) throws {
    try server.start(
        configuration: WebServerConfiguration(port: 0, allowRemoteAccess: false, accessToken: "test-only-token"),
        stateHandler: { _ in }, eventHandler: eventHandler,
        requestHandler: requestHandler
    )
}

private func waitForHTTPCondition(line: UInt = #line, _ predicate: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else {
            throw NSError(domain: "WebManagementHTTPTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "等待本机 HTTP 状态超时（调用行 \(line)）"])
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private actor WebEventCounter {
    var count = 0
    func nextPayload() -> String {
        count += 1
        return "{\"tick\":\(count)}"
    }
}

private final class LoopbackHTTPClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "SurgeRelayTests.loopback-client")
    private let lock = NSLock()
    private var received = Data()
    private var didConnect = false
    private var didEnd = false
    var text: String { lock.withLock { String(decoding: received, as: UTF8.self) } }
    var responseData: Data { lock.withLock { received } }
    var connected: Bool { lock.withLock { didConnect } }
    var ended: Bool { lock.withLock { didEnd } }

    init(port: UInt16, request: String) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                lock.withLock { didConnect = true }
                connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.cancel() }
                })
                receive()
            case .waiting, .failed, .cancelled:
                lock.withLock { didEnd = true }
                connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            lock.withLock {
                if let data { received.append(data) }
                if complete || error != nil { didEnd = true }
            }
            if complete || error != nil { connection.cancel() }
            else { receive() }
        }
    }
}

@MainActor
@Observable
private final class WebObservableTestState {
    var moduleName = "first"
    var progress = 0
    var isWorking = false
    var unrelated = ""
}

private actor WebPendingRequestState {
    var started = false
    var cancelled = false
    func response() async -> WebHTTPResponse {
        started = true
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled = Task.isCancelled }
        return .json(["ready": true])
    }
}

private struct WebLoadReport: Encodable {
    let createdAt: Date
    let actualExecutablePath: String
    let testBundlePath: String
    let processID: Int32
    let os: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let moduleCount = 5_000
    let productionSSELimit = 8
    let method = "Production WebManagementServer, WebManagementSnapshotSource/JSONEncoder, WebManagementAPI/StateBuilder and real AppModel in isolated WorkspaceContext. Default 1-second event interval and 8-SSE limit unchanged. CPU is test-host process CPU, including server, XCTest, streaming TCP clients and measurement driver; 100% means one logical core. RSS is same-process resident size sampled through task_info every 100ms; no browser DOM/JS parsing is included. Clients count streaming frames without retaining whole JSON; rejected clients do not run browser retry loops. The fixture model is not bound to the native 5000-row UI. Busy phases mutate actual activity or module state at a nominal 4Hz, not real conversion/download work; actual mutation counts and elapsed windows are reported. Hidden means closing all streams; reconnect validates latest state. Counters for stopped/hidden steady windows begin after 1.1s settlement. Scenarios run sequentially in one host, so RSS includes allocator reuse. Received application bytes include HTTP/SSE framing; completed state-body bytes exclude it and exclude incomplete frames. Event encodes count actual full JSON construction, not cached callback reads. Clients negotiate activity=1. Snapshot durations measure MainActor immutable-input capture (no module projection/summary traversal); encode durations measure waiting for the background actor, including DTO preparation, filesystem icon checks, JSON encoding and executor queue/hop time. Activity encode count/bytes are reported separately. The benchmark calls the production actor preparation and encoding stages separately to time each (both include queue/hop time); production invokes them synchronously in one actor call. Core encode duration is total background prepare+JSON latency and may include the small associated activity encode. No real workspace, external source or publication target is accessed."
    let samples: [WebLoadSample]
}

private struct WebLoadSample: Encodable {
    let phase: String
    let requestedClients: Int
    let acceptedClients: Int
    let rejectedClients: Int
    let activeClientsAtEnd: Int
    let elapsedSeconds: Double
    let mutationCount: Int
    let cpuSeconds: Double
    let cpuOneCorePercent: Double
    let rssStartBytes: UInt64
    let rssSampledPeakBytes: UInt64
    let rssEndBytes: UInt64
    let eventCallbacks: Int
    let eventEncodes: Int
    let encodeTotalSeconds: Double
    let encodeMaxSeconds: Double
    let generatedJSONBytes: Int64
    let latestPayloadBytes: Int
    let receivedApplicationBytes: Int64
    let completedStateBodyBytes: Int64
    let completedStateFrames: Int
    let activityEncodes: Int
    let generatedActivityJSONBytes: Int64
    let completedActivityBodyBytes: Int64
    let completedActivityFrames: Int
    let snapshotTotalSeconds: Double
    let snapshotMaxSeconds: Double
    let backgroundTotalSeconds: Double
    let backgroundMaxSeconds: Double
    let preparationTotalSeconds: Double
    let preparationMaxSeconds: Double
    let jsonEncodingTotalSeconds: Double
    let jsonEncodingMaxSeconds: Double
}

@MainActor
private final class WebLoadEncodingProbe {
    var callbacks = 0
    var encodeDurations: [Double] = []
    var generatedBytes: Int64 = 0
    var latestPayloadBytes = 0

    var snapshotDurations: [Double] = []
    var backgroundDurations: [Double] = []
    var preparationDurations: [Double] = []
    var jsonEncodingDurations: [Double] = []
    var activityEncodes = 0
    var activityBytes: Int64 = 0
    private var stateRevision: UInt64?
    private var activityRevision: UInt64?

    func payload(source: WebManagementSnapshotSource, encoder: WebManagementJSONEncoder, legacy: Bool) async throws -> WebEventPayload {
        callbacks += 1
        let captureStarted = ContinuousClock.now
        let snapshot = try source.snapshot(includingLegacy: legacy)
        snapshotDurations.append(StageMetricsRecorder.elapsed(since: captureStarted))
        let started = ContinuousClock.now
        let prepared = try await encoder.prepare(snapshot)
        preparationDurations.append(StageMetricsRecorder.elapsed(since: started))
        let encodingStarted = ContinuousClock.now
        let payload = try await encoder.encode(prepared)
        jsonEncodingDurations.append(StageMetricsRecorder.elapsed(since: encodingStarted))
        let elapsed = StageMetricsRecorder.elapsed(since: started)
        backgroundDurations.append(elapsed)
        if stateRevision != payload.state.revision {
            stateRevision = payload.state.revision
            encodeDurations.append(elapsed)
            latestPayloadBytes = payload.state.data.count
            generatedBytes += Int64(latestPayloadBytes)
        }
        if let activity = payload.activity, activityRevision != activity.revision {
            activityRevision = activity.revision
            activityEncodes += 1
            activityBytes += Int64(activity.data.count)
        }
        return payload
    }
}

@MainActor
private func webLoadWait(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(25))
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw NSError(domain: "WebLoadBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for production Web state"]) }
        try await Task.sleep(for: .milliseconds(25))
    }
}

@MainActor
private func webLoadReady(_ clients: [WebLoadClient], requested: Int) async throws {
    try await webLoadWait { clients.allSatisfy { $0.status == 503 || ($0.status == 200 && $0.frames > 0 && $0.activityFrames > 0) } }
    XCTAssertEqual(clients.filter { $0.status == 200 }.count, min(requested, 8))
    XCTAssertEqual(clients.filter { $0.status == 503 }.count, max(0, requested - 8))
}

@MainActor
private func webLoadWindow(seconds: Double, mutation: ((Int) -> Void)? = nil) async throws -> Int {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    var count = 0
    while ContinuousClock.now < deadline {
        if let mutation { mutation(count); count += 1 }
        try await Task.sleep(for: .milliseconds(250))
    }
    return count
}

@MainActor
private func webLoadMeasure(_ phase: String, requested: Int, probe: WebLoadEncodingProbe, clients: [WebLoadClient], operation: () async throws -> Int) async rethrows -> WebLoadSample {
    let started = ContinuousClock.now
    let cpuBefore = webLoadCPU()
    let rssBefore = webLoadRSS()
    let beforeCallbacks = probe.callbacks
    let beforeEncodes = probe.encodeDurations.count
    let beforeSnapshots = probe.snapshotDurations.count
    let beforeBackground = probe.backgroundDurations.count
    let beforePreparation = probe.preparationDurations.count
    let beforeJSONEncoding = probe.jsonEncodingDurations.count
    let beforeActivityEncodes = probe.activityEncodes
    let beforeActivityGenerated = probe.activityBytes
    let beforeActivityBody = clients.reduce(Int64(0)) { $0 + $1.activityBodyBytes }
    let beforeActivityFrames = clients.reduce(0) { $0 + $1.activityFrames }
    let beforeGenerated = probe.generatedBytes
    let beforeBytes = clients.reduce(Int64(0)) { $0 + $1.receivedBytes }
    let beforeBody = clients.reduce(Int64(0)) { $0 + $1.stateBodyBytes }
    let beforeFrames = clients.reduce(0) { $0 + $1.frames }
    let sampler = WebLoadRSSSampler()
    sampler.start()
    let changes: Int
    do { changes = try await operation() }
    catch { await sampler.stop(); throw error }
    await sampler.stop()
    let elapsed = StageMetricsRecorder.elapsed(since: started)
    let cpu = max(0, webLoadCPU() - cpuBefore)
    let durations = probe.encodeDurations.dropFirst(beforeEncodes)
    let snapshots = probe.snapshotDurations.dropFirst(beforeSnapshots)
    let background = probe.backgroundDurations.dropFirst(beforeBackground)
    let preparation = probe.preparationDurations.dropFirst(beforePreparation)
    let jsonEncoding = probe.jsonEncodingDurations.dropFirst(beforeJSONEncoding)
    let rssAfter = webLoadRSS()
    let result = WebLoadSample(phase: phase, requestedClients: requested, acceptedClients: clients.filter { $0.status == 200 }.count,
                              rejectedClients: clients.filter { $0.status == 503 }.count,
                              activeClientsAtEnd: clients.filter { $0.status == 200 && !$0.ended }.count,
                              elapsedSeconds: elapsed, mutationCount: changes, cpuSeconds: cpu, cpuOneCorePercent: cpu / elapsed * 100,
                              rssStartBytes: rssBefore, rssSampledPeakBytes: max(rssBefore, rssAfter, sampler.peak), rssEndBytes: rssAfter,
                              eventCallbacks: probe.callbacks - beforeCallbacks, eventEncodes: durations.count,
                              encodeTotalSeconds: durations.reduce(0, +), encodeMaxSeconds: durations.max() ?? 0,
                              generatedJSONBytes: probe.generatedBytes - beforeGenerated, latestPayloadBytes: probe.latestPayloadBytes,
                              receivedApplicationBytes: clients.reduce(Int64(0)) { $0 + $1.receivedBytes } - beforeBytes,
                              completedStateBodyBytes: clients.reduce(Int64(0)) { $0 + $1.stateBodyBytes } - beforeBody,
                              completedStateFrames: clients.reduce(0) { $0 + $1.frames } - beforeFrames,
                              activityEncodes: probe.activityEncodes - beforeActivityEncodes,
                              generatedActivityJSONBytes: probe.activityBytes - beforeActivityGenerated,
                              completedActivityBodyBytes: clients.reduce(Int64(0)) { $0 + $1.activityBodyBytes } - beforeActivityBody,
                              completedActivityFrames: clients.reduce(0) { $0 + $1.activityFrames } - beforeActivityFrames,
                              snapshotTotalSeconds: snapshots.reduce(0, +), snapshotMaxSeconds: snapshots.max() ?? 0,
                              backgroundTotalSeconds: background.reduce(0, +), backgroundMaxSeconds: background.max() ?? 0,
                              preparationTotalSeconds: preparation.reduce(0, +), preparationMaxSeconds: preparation.max() ?? 0,
                              jsonEncodingTotalSeconds: jsonEncoding.reduce(0, +), jsonEncodingMaxSeconds: jsonEncoding.max() ?? 0)
    print("WEB_LOAD_PHASE=\(requested)/\(phase) wall=\(elapsed) encodes=\(result.eventEncodes) body=\(result.completedStateBodyBytes)")
    return result
}

private func webLoadCPU() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

private func webLoadRSS() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

private final class WebLoadRSSSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var maximum: UInt64 = 0
    private var task: Task<Void, Never>?
    var peak: UInt64 { lock.withLock { maximum } }
    func start() {
        task = Task.detached(priority: .utility) { [self] in
            while !Task.isCancelled {
                let value = webLoadRSS()
                lock.withLock { maximum = max(maximum, value) }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }
    func stop() async { task?.cancel(); await task?.value }
}

private final class WebLoadClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "SurgeRelayTests.web-load-client")
    private let lock = NSLock()
    private var header = Data()
    private var parsedHeaders = false
    private var isEventStream = false
    private var responseStatus: Int?
    private var didEnd = false
    private var received: Int64 = 0
    private var bodyBytes: Int64 = 0
    private var frameCount = 0
    private var activityFrameCount = 0
    private var activityBytes: Int64 = 0
    private var frameBytes: Int64 = 0
    private var prefix = Data()
    private var lastByte: UInt8?
    private let expectedMarker: Data?
    private var markerTail = Data()
    private var sawMarker = false
    private static let statePrefix = Data("event: state\ndata: ".utf8)
    private static let activityPrefix = Data("event: activity\ndata: ".utf8)
    private static let separator = Data("\n\n".utf8)

    var status: Int? { lock.withLock { responseStatus } }
    var ended: Bool { lock.withLock { didEnd } }
    var receivedBytes: Int64 { lock.withLock { received } }
    var stateBodyBytes: Int64 { lock.withLock { bodyBytes } }
    var frames: Int { lock.withLock { frameCount } }
    var activityFrames: Int { lock.withLock { activityFrameCount } }
    var activityBodyBytes: Int64 { lock.withLock { activityBytes } }
    var markerSeen: Bool { lock.withLock { sawMarker } }

    init(port: UInt16, token: String, path: String = "/api/events?activity=1", marker: String? = nil) {
        expectedMarker = marker.map { Data($0.utf8) }
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.close() }
                })
                receive()
            case .waiting, .failed, .cancelled:
                lock.withLock { didEnd = true }
                connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    deinit { connection.cancel() }

    func close() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            lock.withLock {
                if let data { received += Int64(data.count); consume(data) }
                if complete || error != nil { didEnd = true }
            }
            if complete || error != nil { connection.cancel() }
            else { receive() }
        }
    }

    private func consume(_ data: Data) {
        if !parsedHeaders {
            header.append(data)
            guard let boundary = header.range(of: Data("\r\n\r\n".utf8)) else { return }
            let text = String(decoding: header[..<boundary.lowerBound], as: UTF8.self)
            responseStatus = text.split(separator: " ").dropFirst().first.flatMap { Int($0) }
            isEventStream = text.lowercased().contains("text/event-stream")
            parsedHeaders = true
            let body = Data(header[boundary.upperBound...])
            header.removeAll(keepingCapacity: false)
            if isEventStream { consumeFrames(body) }
        } else if isEventStream { consumeFrames(data) }
    }

    private func consumeFrames(_ data: Data) {
        guard !data.isEmpty else { return }
        if let marker = expectedMarker, !sawMarker {
            var edge = markerTail
            edge.append(data.prefix(marker.count))
            sawMarker = data.range(of: marker) != nil || edge.range(of: marker) != nil
            markerTail = Data(data.suffix(max(0, marker.count - 1)))
        }
        var cursor = data.startIndex
        if lastByte == 10, data.first == 10 {
            appendFrame(data[cursor..<(cursor + 1)])
            finishFrame()
            cursor += 1
        }
        while cursor < data.endIndex {
            if let boundary = data.range(of: Self.separator, in: cursor..<data.endIndex) {
                appendFrame(data[cursor..<boundary.upperBound])
                finishFrame()
                cursor = boundary.upperBound
            } else {
                appendFrame(data[cursor..<data.endIndex])
                break
            }
        }
    }

    private func appendFrame(_ data: Data.SubSequence) {
        frameBytes += Int64(data.count)
        if prefix.count < Self.activityPrefix.count { prefix.append(data.prefix(Self.activityPrefix.count - prefix.count)) }
        lastByte = data.last
    }

    private func finishFrame() {
        if prefix.starts(with: Self.statePrefix) {
            frameCount += 1
            bodyBytes += max(0, frameBytes - Int64(Self.statePrefix.count) - 2)
        } else if prefix == Self.activityPrefix {
            activityFrameCount += 1
            activityBytes += max(0, frameBytes - Int64(Self.activityPrefix.count) - 2)
        }
        prefix.removeAll(keepingCapacity: true)
        frameBytes = 0
        lastByte = nil
    }
}

extension WebManagementHTTPTests {
    @MainActor
    func testActivityPollingKeepsFlatFieldsAndSharesSnapshotRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(context: WorkspaceContext(id: UUID(), name: "Activity ordering", configurationDirectory: root,
            cacheDirectory: root.appending(path: "cache"), allowsLegacyFallback: false), persistsOnInit: false)
        model.statusMessage = "before-state"
        let activityRequest = WebHTTPRequest(method: "GET", path: "/api/activity", query: [:], headers: [:], body: Data(), isLoopback: true)
        let firstResponse = await WebManagementAPI.response(for: activityRequest, model: model)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: firstResponse.body) as? [String: Any])
        XCTAssertEqual(firstResponse.status, 200)
        XCTAssertEqual(first["status"] as? String, "before-state")
        XCTAssertEqual(first["isWorking"] as? Bool, false)
        XCTAssertNil(first["activity"])
        XCTAssertEqual(first["runtimeID"] as? String, model.runtimeID.uuidString)
        XCTAssertEqual(first["workspaceID"] as? String, model.workspaceID.uuidString)
        let firstRevision = try XCTUnwrap(first["revision"] as? UInt64)
        let stateRequest = WebHTTPRequest(method: "GET", path: "/api/state", query: [:], headers: [:], body: Data(), isLoopback: true)
        let stateResponse = await WebManagementAPI.response(for: stateRequest, model: model)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: stateResponse.body) as? [String: Any])
        let stateRevision = try XCTUnwrap(state["revision"] as? UInt64)
        XCTAssertGreaterThan(stateRevision, firstRevision)
        model.statusMessage = "after-state"
        let lastResponse = await WebManagementAPI.response(for: activityRequest, model: model)
        let last = try XCTUnwrap(JSONSerialization.jsonObject(with: lastResponse.body) as? [String: Any])
        XCTAssertEqual(last["status"] as? String, "after-state")
        XCTAssertGreaterThan(try XCTUnwrap(last["revision"] as? UInt64), stateRevision)
    }
}


extension WebManagementHTTPTests {
    @MainActor
    func testLoopbackFiveMiBPreviewSaveReadbackKeepsConditionalAndBusySemantics() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(context: WorkspaceContext(id: UUID(), name: "Large preview", configurationDirectory: root.appending(path: "configuration"),
            cacheDirectory: root.appending(path: "cache"), allowsLegacyFallback: false), persistsOnInit: false)
        model.settings.publishToLocal = false
        model.settings.publishToGitHub = false
        model.settings.automaticallyPublish = false
        model.settings.combinedModuleEnabled = false
        let module = RelayModule(name: "Large Preview", sourceURL: root.appending(path: "source.sgmodule").absoluteString,
            sourceFormat: .surge, outputFileName: "Large Preview")
        model.modules = [module]
        let initial = "#!name=Large Preview\n\n[Rule]\nDOMAIN,original.example,DIRECT\n"
        try await model.fileStore.writeComponent(initial, id: module.id)
        let server = WebManagementServer()
        defer { server.stop() }
        try startLoopbackServer(server, requestHandler: { request in await WebManagementAPI.response(for: request, model: model) })
        try await webLoadWait { server.listeningPort != nil }
        let port = try XCTUnwrap(server.listeningPort)
        let path = "/api/modules/\(module.id.uuidString)/preview"
        func request(_ method: String, body: String = "", etag: String? = nil) async throws -> (Int, [String: String], Data) {
            let conditional = etag.map { "If-Match: \($0)\r\n" } ?? ""
            let head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer test-only-token\r\nX-Relay-Workspace: \(model.workspaceID.uuidString)\r\nContent-Length: \(body.utf8.count)\r\n\(conditional)\r\n"
            let client = LoopbackHTTPClient(port: port, request: head + body)
            defer { client.cancel() }
            try await webLoadWait { client.ended }
            return try parsedLoopbackResponse(client.responseData)
        }
        let before = try await request("GET")
        XCTAssertEqual(before.0, 200)
        let etag = try XCTUnwrap(before.1["etag"])
        let prefix = "#!name=Large Preview\n\n[Rule]\nDOMAIN,large.example,DIRECT\n"
        let comment = "#" + String(repeating: "x", count: 126) + "\n"
        let target = 5 * 1024 * 1024
        var content = prefix + String(repeating: comment, count: (target - prefix.utf8.count - 2) / comment.utf8.count)
        content += "#" + String(repeating: "x", count: target - content.utf8.count - 2) + "\n"
        XCTAssertEqual(content.utf8.count, target)
        let saved = try await request("PUT", body: content, etag: etag)
        XCTAssertEqual(saved.0, 200, String(decoding: saved.2.prefix(500), as: UTF8.self))
        let savedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: saved.2) as? [String: Any])
        XCTAssertEqual(savedJSON["content"] as? String, content)
        let readback = try await request("GET")
        XCTAssertEqual(readback.0, 200)
        XCTAssertEqual(readback.2, Data(content.utf8))
        XCTAssertEqual(readback.1["etag"], saved.1["etag"])
        let stale = try await request("PUT", body: initial, etag: etag)
        XCTAssertEqual(stale.0, 412)
        model.beginWork(.updatingModules)
        let busy = try await request("PUT", body: initial, etag: readback.1["etag"])
        model.endWork(.updatingModules)
        XCTAssertEqual(busy.0, 409)
        let retained = try await request("GET")
        XCTAssertEqual(retained.2, readback.2)
    }

    func testLargeBodyHeadersRejectBeforeReadingUnauthorizedOrOversizedBodies() async throws {
        let counter = WebEventCounter()
        let server = WebManagementServer(requestReadTimeout: 10)
        defer { server.stop() }
        try startLoopbackServer(server, requestHandler: { _ in
            _ = await counter.nextPayload()
            return .json(["unexpected": true])
        })
        try await waitForHTTPCondition { server.listeningPort != nil }
        let port = try XCTUnwrap(server.listeningPort)
        let preview = "/api/modules/\(UUID().uuidString)/preview"
        let cases: [(String, String, Int, String, Int)] = [
            ("PUT", preview, 5 * 1024 * 1024, "wrong-token", 401),
            ("PUT", preview, 20 * 1024 * 1024 + 1, "test-only-token", 400),
            ("POST", "/api/modules", 4 * 1024 * 1024 + 1, "test-only-token", 400),
            ("POST", preview, 5 * 1024 * 1024, "test-only-token", 400),
            ("PUT", "/api/modules/not-a-uuid/preview", 5 * 1024 * 1024, "test-only-token", 400)
        ]
        for (method, path, length, token, expected) in cases {
            let client = LoopbackHTTPClient(port: port, request: "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(length)\r\n\r\n")
            defer { client.cancel() }
            try await waitForHTTPCondition { client.ended }
            XCTAssertEqual(try parsedLoopbackResponse(client.responseData).0, expected)
        }
        let calls = await counter.count
        XCTAssertEqual(calls, 0)
        let headerPrefix = "GET /api/state HTTP/1.1\r\nX-Fill: "
        let oversizedHeader = LoopbackHTTPClient(port: port,
            request: headerPrefix + String(repeating: "x", count: 32 * 1024 - headerPrefix.utf8.count))
        defer { oversizedHeader.cancel() }
        try await waitForHTTPCondition { oversizedHeader.ended }
        XCTAssertEqual(try parsedLoopbackResponse(oversizedHeader.responseData).0, 400)
    }

    func testPreviewBodyLimitRequiresExactPutUUIDRouteAndRejectsAmbiguousFraming() {
        let path = "/api/modules/\(UUID().uuidString)/preview"
        let head = "PUT \(path) HTTP/1.1\r\nContent-Length: 20971520\r\n\r\n"
        guard case .incomplete = WebManagementServer.parseRequestResult(Data(head.utf8), isLoopback: true) else {
            return XCTFail("The exact 20 MiB preview body limit should await body")
        }
        for framing in ["Content-Length: 1\r\nContent-Length: 2", "Content-Length: 1\r\nTransfer-Encoding: chunked"] {
            let request = "PUT \(path) HTTP/1.1\r\n\(framing)\r\n\r\n"
            guard case .invalid = WebManagementServer.parseRequestResult(Data(request.utf8), isLoopback: true) else {
                return XCTFail("Ambiguous body framing must be rejected before buffering")
            }
        }
    }
}

private func parsedLoopbackResponse(_ data: Data) throws -> (Int, [String: String], Data) {
    let boundary = try XCTUnwrap(data.range(of: Data("\r\n\r\n".utf8)))
    let lines = String(decoding: data[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
    let status = try XCTUnwrap(lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) })
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return (status, headers, Data(data[boundary.upperBound...]))
}
