import XCTest
@testable import SurgeRelay

@MainActor
final class WebActionTests: XCTestCase {
    private func model() async throws -> (AppModel, RelayModule, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "WebActionTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = WorkspaceContext(id: WorkspaceContext.legacyID, name: "Action tests", configurationDirectory: root.appending(path: "Config"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = false
        model.settings.combinedModuleEnabled = false
        model.settings.localModuleDirectory = root.path
        var module = RelayModule(name: "Reviewed", sourceURL: "https://test.invalid/reviewed.sgmodule", outputFileName: "Reviewed")
        module.storageTargets = [.local]
        model.modules = [module]
        try await model.fileStore.writeComponent("[Rule]\nDOMAIN,reviewed.example,DIRECT\n", id: module.id)
        return (model, module, root)
    }

    func testLocalPreviewWritesOnlyAfterConfirmationAndRejectsReplay() async throws {
        let (model, module, root) = try await model()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try await model.webPublishPreview(WebPublishPreviewRequest(moduleIDs: [module.id]))
        XCTAssertEqual(preview.previews.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: module.publishedRelativePath).path))
        let result = try await model.confirmWebPublish(token: preview.token)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.attempt?.results.first?.status, .succeeded)
        let published = try Data(contentsOf: root.appending(path: module.publishedRelativePath))
        XCTAssertTrue(String(decoding: published, as: UTF8.self).contains("reviewed.example"))
        do { _ = try await model.confirmWebPublish(token: preview.token); XCTFail("Consumed ticket must be rejected") }
        catch { XCTAssertEqual(error as? PreviewContentSaveError, .changed) }
    }

    func testChangedCacheRejectsReviewedPublishWithoutWriting() async throws {
        let (model, module, root) = try await model()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try await model.webPublishPreview(WebPublishPreviewRequest(moduleIDs: [module.id]))
        try await model.fileStore.writeComponent("[Rule]\nDOMAIN,new.example,REJECT\n", id: module.id)
        do { _ = try await model.confirmWebPublish(token: preview.token); XCTFail("Changed cache must require a new preview") }
        catch { XCTAssertEqual(error as? PreviewContentSaveError, .changed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: module.publishedRelativePath).path))
    }

    func testFileCreatedAfterPreviewCannotBeOverwritten() async throws {
        let (model, module, root) = try await model()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try await model.webPublishPreview(WebPublishPreviewRequest(moduleIDs: [module.id]))
        let target = root.appending(path: module.publishedRelativePath)
        let userData = Data("user created this file".utf8)
        try userData.write(to: target)
        do { _ = try await model.confirmWebPublish(token: preview.token); XCTFail("New local file must invalidate preview") }
        catch { XCTAssertEqual(error as? PreviewContentSaveError, .changed) }
        XCTAssertEqual(try Data(contentsOf: target), userData)
    }

    func testSettingsChangeAndBusyStateRejectPreviewConfirmation() async throws {
        let (model, module, root) = try await model()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try await model.webPublishPreview(WebPublishPreviewRequest(moduleIDs: [module.id]))
        model.beginWork(.savingPreview)
        do { _ = try await model.confirmWebPublish(token: preview.token); XCTFail("Busy work must be rejected") }
        catch { XCTAssertEqual(error as? PreviewContentSaveError, .busy) }
        model.endWork()
        model.settings.publishToLocal = false
        do { _ = try await model.confirmWebPublish(token: preview.token); XCTFail("Changed destination must be rejected") }
        catch { XCTAssertEqual(error as? PreviewContentSaveError, .changed) }
    }

    func testExpiredTicketIsRejected() throws {
        let store = WebActionTickets()
        let ticket = WebPublishTicket(createdAt: .distantPast, scope: "selected", moduleIDs: [], generation: 0,
            settings: AppSettings(), files: [:], previews: [], localHashes: [:])
        try store.store(ticket)
        XCTAssertThrowsError(try store.consumePublish(ticket.token))
    }
    func testWebRestoreUsesIfMatchAndDoesNotDeleteNewerOverride() async throws {
        let (model, module, root) = try await model()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try await model.savePreviewContent("[Rule]\nDOMAIN,edited.example,DIRECT", for: module)
        try await model.fileStore.writeComponentOverride("[Rule]\nDOMAIN,newer.example,REJECT", id: module.id)
        let request = WebHTTPRequest(method: "DELETE", path: "/api/modules/\(module.id)/preview", query: [:],
            headers: ["if-match": "\"\(saved.contentHash)\""], body: Data(), isLoopback: true)
        let response = await WebManagementAPI.response(for: request, model: model)
        XCTAssertEqual(response.status, 412)
        let retained = try await model.fileStore.readComponent(id: module.id)
        XCTAssertTrue(retained.contains("newer.example"))
    }

    func testWebVersionRestoreTicketRejectsNewerCacheAndPreservesDraft() async throws {
        let (model, module, root) = try await model()
        defer { try? FileManager.default.removeItem(at: root) }
        let versions = try await model.moduleVersions(moduleID: module.id)
        let version = try XCTUnwrap(versions.first)
        try await model.fileStore.writeComponent("[Rule]\nDOMAIN,current.example,DIRECT", id: module.id)
        let path = "/api/modules/\(module.id)/versions/\(version.id)"
        let preview = await WebManagementAPI.response(for: WebHTTPRequest(method: "GET", path: path, query: [:], headers: [:], body: Data(), isLoopback: true), model: model)
        XCTAssertEqual(preview.status, 200)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: preview.body) as? [String: Any])
        let token = try XCTUnwrap(payload["token"] as? String)
        model.modulePreviewDrafts[module.id] = ModulePreviewDraft(text: "unsaved", savedText: "baseline")
        try await model.fileStore.writeComponent("[Rule]\nDOMAIN,newest.example,DIRECT", id: module.id)
        let restore = await WebManagementAPI.response(for: WebHTTPRequest(method: "POST", path: path + "/restore", query: [:], headers: [:],
            body: try JSONSerialization.data(withJSONObject: ["token": token]), isLoopback: true), model: model)
        XCTAssertEqual(restore.status, 412)
        XCTAssertEqual(model.modulePreviewDrafts[module.id]?.text, "unsaved")
        let current = try await model.fileStore.readComponent(id: module.id)
        XCTAssertTrue(current.contains("newest.example"))
    }

    func testRefreshMutationDistinguishesMissingAndExplicitNull() throws {
        var module = RelayModule(name: "Timing", sourceURL: "https://test.invalid/a.sgmodule", outputFileName: "Timing")
        module.refreshIntervalMinutes = 37
        func decode(_ extra: String) throws -> WebModuleMutation {
            try JSONDecoder().decode(WebModuleMutation.self, from: Data(("{\"name\":\"Timing\",\"sourceURL\":\"https://test.invalid/a.sgmodule\"" + extra + "}").utf8))
        }
        XCTAssertEqual(try decode("").draft(existing: module).refreshIntervalMinutes, 37)
        XCTAssertNil(try decode(",\"refreshIntervalMinutes\":null").draft(existing: module).refreshIntervalMinutes)
        XCTAssertEqual(try decode(",\"refreshIntervalMinutes\":0").draft(existing: module).refreshIntervalMinutes, 0)
        XCTAssertThrowsError(try decode(",\"refreshIntervalMinutes\":10081").draft(existing: module))
    }

    func testReviewedGitHubTargetCannotChangeDuringPrivacyLookup() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockURLProtocol.self]
        let model = AppModel(githubClient: GitHubClient(session: URLSession(configuration: configuration)))
        model.settings.publishToLocal = false
        model.settings.publishToGitHub = true
        model.settings.combinedModuleEnabled = false
        model.settings.github.owner = "owner"
        model.settings.github.repository = "repo"
        model.settings.github.branch = "main"
        model.githubToken = "test-only-token"
        model.githubTokenStorageStatus = .memoryOnly
        var module = RelayModule(name: "Frozen", sourceURL: "https://test.invalid/frozen.sgmodule", outputFileName: "Frozen")
        module.storageTargets = [.gitHub]
        model.modules = [module]
        try await model.fileStore.writeComponent("[Rule]\nDOMAIN,frozen.example,DIRECT", id: module.id)
        let state = ReviewedGitHubState()
        GitHubMockURLProtocol.reset()
        defer { GitHubMockURLProtocol.reset() }
        GitHubMockURLProtocol.handler = { @Sendable request in
            let path = request.url!.path
            state.record(request.httpMethod ?? "GET")
            if path == "/repos/owner/repo" {
                if state.nextRepositoryRead() == 2 {
                    let changed = DispatchSemaphore(value: 0)
                    Task { @MainActor in
                        model.settings.github.repository = "unreviewed-repo"
                        changed.signal()
                    }
                    _ = changed.wait(timeout: .now() + 5)
                }
                return (200, Data(#"{"private":false}"#.utf8))
            }
            if path.contains("/git/ref/heads/") { return (200, Data(#"{"object":{"sha":"shared-head"}}"#.utf8)) }
            if path.contains("/git/commits/") { return (200, Data(#"{"sha":"shared-head","tree":{"sha":"tree"}}"#.utf8)) }
            if path.contains("/git/trees/") { return (200, Data(#"{"tree":[],"truncated":false}"#.utf8)) }
            return (500, Data(#"{"message":"unexpected write"}"#.utf8))
        }
        let preview = try await model.webPublishPreview(WebPublishPreviewRequest(moduleIDs: [module.id]))
        let result = try await model.confirmWebPublish(token: preview.token)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.attempt?.results.first?.status, .failed)
        XCTAssertFalse(state.methods.contains { $0 != "GET" }, "Changing a target during await must never write to either repository")
    }

    func testOldWorkspaceRequestCannotMutateNewWorkspaceAtSameOrigin() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "WorkspaceAPI-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "B", configurationDirectory: root.appending(path: "Config"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        let body = try JSONSerialization.data(withJSONObject: ["name": "Scoped", "sourceURL": "https://test.invalid/scoped.sgmodule"])
        func request(_ workspace: String?) -> WebHTTPRequest {
            WebHTTPRequest(method: "POST", path: "/api/modules", query: [:], headers: workspace.map { ["x-relay-workspace": $0] } ?? [:],
                body: body, isLoopback: true)
        }
        let stale = await WebManagementAPI.response(for: request(UUID().uuidString), model: model)
        let missing = await WebManagementAPI.response(for: request(nil), model: model)
        XCTAssertEqual(stale.status, 412)
        XCTAssertEqual(missing.status, 412)
        XCTAssertTrue(model.modules.isEmpty)
        let accepted = await WebManagementAPI.response(for: request(context.id.uuidString), model: model)
        XCTAssertEqual(accepted.status, 201)
        XCTAssertEqual(model.modules.count, 1)
        try await model.flushPersistence()
    }

    func testAutomaticLocalExportRejectsInvalidContentAndPreservesOutput() async throws {
        let (model, module, root) = try await model()
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.publishCurrentFiles(combinedData: nil, includeAssets: false)
        let output = root.appending(path: module.publishedRelativePath)
        let valid = try Data(contentsOf: output)
        try await model.fileStore.writeComponent("[Rule\nDOMAIN,broken.example,DIRECT", id: module.id)
        do { try await model.publishCurrentFiles(combinedData: nil, includeAssets: false); XCTFail("Automatic exports must lint before changing files") }
        catch { XCTAssertTrue(error.localizedDescription.contains("发布前检查")) }
        XCTAssertEqual(try Data(contentsOf: output), valid)
    }

    func testNativeWarningConfirmationIsBoundToReviewedContent() async throws {
        let (model, module, root) = try await model()
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.fileStore.writeComponent("[Rule]\nDOMAIN,duplicate.example,DIRECT\nDOMAIN,duplicate.example,DIRECT", id: module.id)
        let started = await model.publishModules(moduleIDs: [module.id])
        XCTAssertFalse(started)
        let review = try XCTUnwrap(model.pendingSelectedPublishLintReview)
        XCTAssertTrue(review.issues.contains { $0.code == "duplicate-entry" })
        try await model.fileStore.writeComponent("[Rule]\nDOMAIN,changed.example,REJECT", id: module.id)
        await model.confirmSelectedPublishReview(review)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: module.publishedRelativePath).path))
        XCTAssertTrue(model.presentedError?.contains("重新预览") == true)
    }

    func testNativeReviewSurvivesTurningOffWebService() async throws {
        let (model, module, root) = try await model()
        defer { try? FileManager.default.removeItem(at: root) }
        model.settings.webServerEnabled = true
        let preview = try await model.webPublishPreview(WebPublishPreviewRequest(moduleIDs: [module.id]), retainsForNativeUI: true)
        model.settings.webServerEnabled = false
        model.webActionTickets.removeWebActions()
        let result = try await model.confirmWebPublish(token: preview.token)
        XCTAssertTrue(result.ok, "Web preferences must not invalidate an independent native publication review")
    }

    func testNativeRetryRequiresWarningReviewAndKeepsSuccessfulTarget() async throws {
        let (model, module, root) = try await model()
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.fileStore.writeComponent("[Rule]\nDOMAIN,duplicate.example,DIRECT\nDOMAIN,duplicate.example,DIRECT", id: module.id)
        model.selectedPublishAttempt = SelectedPublishAttempt(moduleIDs: [module.id], results: [
            PublishTargetResult(destination: .local, target: root.path, status: .failed),
            PublishTargetResult(destination: .gitHub, target: "already-completed", status: .succeeded)
        ])
        await model.retrySelectedPublish()
        let review = try XCTUnwrap(model.pendingSelectedPublishLintReview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: module.publishedRelativePath).path))
        await model.confirmSelectedPublishReview(review)
        XCTAssertEqual(model.selectedPublishAttempt?.results.map(\.status), [.succeeded, .succeeded])
        XCTAssertEqual(model.selectedPublishAttempt?.results.last?.target, "already-completed")
    }

    func testLocalCleanupConfirmationRejectsFileEditedAfterPreview() async throws {
        let (model, _, root) = try await model()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPath = "Old.sgmodule"
        _ = try await model.fileStore.exportPublishedFiles([PublishFile(name: oldPath, data: Data("[Rule]\nFINAL,DIRECT".utf8))], toRootDirectory: root.path)
        model.settings.localPublishedRootDirectory = root.path
        model.settings.localPublishedFilePaths = [oldPath]
        try await model.publishCurrentFiles(combinedData: nil, includeAssets: false)
        XCTAssertEqual(model.pendingPublishPreview?.deletedFiles, [oldPath])
        _ = try await model.fileStore.exportPublishedFiles([PublishFile(name: oldPath, data: Data("[Rule]\nFINAL,REJECT".utf8))],
            toRootDirectory: root.path, knownManagedRelativePaths: [oldPath])
        await model.confirmPendingPublish()
        let retained = try Data(contentsOf: root.appending(path: oldPath))
        XCTAssertTrue(String(decoding: retained, as: UTF8.self).contains("FINAL,REJECT"))
        XCTAssertTrue(model.presentedError?.contains("重新预览") == true)
    }

    func testTurningWebOffStopsExistingListenerEvenWithInvalidPort() async throws {
        let (model, _, root) = try await model()
        defer { model.webServer.stop(); try? FileManager.default.removeItem(at: root) }
        try model.webServer.start(configuration: WebServerConfiguration(port: 0, allowRemoteAccess: false, accessToken: "test"),
            stateHandler: { _ in }, eventHandler: { "{}" }, requestHandler: { _ in .text("qa") })
        for _ in 0..<100 where model.webServer.listeningPort == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.webServer.listeningPort)
        model.settings.webServerPort = -1
        model.settings.webServerEnabled = false
        model.applyWebServerSettings(persist: false)
        XCTAssertNil(model.webServer.listeningPort)
        if case .stopped = model.webServerState {} else { XCTFail("Disabled service must be stopped even if its stored port is invalid") }
    }

    func testStartupCompletesCommittedRestoreMetadataBeforeCombinedAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "RestoreStartup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "Recovery", configurationDirectory: root.appending(path: "Config"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        var module = RelayModule(name: "Restore", sourceURL: "https://test.invalid/restore.sgmodule", outputFileName: "Restore", isEnabled: true)
        module.sourceContentHash = "new-upstream-hash"
        model.modules = [module]
        model.settings.combinedModuleEnabled = true
        model.settings.publishToLocal = false
        model.settings.publishToGitHub = false
        try model.persistModules()
        model.saveSettings()
        try await model.flushPersistence()
        let url = URL(string: module.sourceURL)!
        try await model.fileStore.commitConversion(ConversionResult(content: "[Rule]\nDOMAIN,old.example,DIRECT", requestURL: url), id: module.id)
        let record = try await model.fileStore.recordCurrentVersion(id: module.id, reason: .current)
        let version = try XCTUnwrap(record)
        try await model.fileStore.commitConversion(ConversionResult(content: "[Rule]\nDOMAIN,new.example,REJECT", requestURL: url), id: module.id)
        let current = try await model.fileStore.currentVersionState(id: module.id)
        let interrupted = ModuleFileStore(cacheDirectory: context.cacheDirectory, configurationDirectory: context.configurationDirectory,
            restoreInterruption: { phase in if phase == .committed { throw NSError(domain: "simulated-stop", code: 1) } })
        do { _ = try await interrupted.restoreModuleVersion(id: module.id, versionID: version.id, expectedFingerprint: current.fingerprint) }
        catch { }
        let relaunched = AppModel(context: context, persistsOnInit: false)
        try await relaunched.recoverPersistedVersionState()
        XCTAssertEqual(relaunched.modules.first?.refreshIntervalMinutes, 0)
        XCTAssertNil(relaunched.modules.first?.sourceContentHash)
        let pending = try await relaunched.fileStore.pendingVersionRestoreModuleIDs()
        XCTAssertTrue(pending.isEmpty)
        let combined = try await relaunched.fileStore.readCombined()
        XCTAssertTrue(String(decoding: combined, as: UTF8.self).contains("old.example"))
        XCTAssertNil(relaunched.automaticPublishScheduledAt)
        let reopened = AppModel(context: context, persistsOnInit: false)
        XCTAssertEqual(reopened.modules.first?.refreshIntervalMinutes, 0)
        XCTAssertNil(reopened.modules.first?.sourceContentHash)
    }

    func testManualOnlyModuleIsNotChangedByLaunchOrFileWatching() {
        var module = RelayModule(name: "Pinned", sourceURL: "file:///tmp/Pinned.sgmodule", outputFileName: "Pinned")
        module.refreshIntervalMinutes = 0
        XCTAssertFalse(ModuleRefreshPlanner.shouldRefresh(module, among: [module], trigger: .launch, globalIntervalMinutes: 60, hasCache: false))
        XCTAssertTrue(ModuleRefreshPlanner.shouldRefresh(module, among: [module], trigger: .manual, globalIntervalMinutes: 60, hasCache: false))
        XCTAssertTrue(LocalSourceSyncPlanner.sourceFiles(in: [module]).isEmpty)
        XCTAssertEqual(LocalSourceSyncPlanner.sourceFiles(in: [module], includesManualOnly: true).count, 1)
    }

    func testInvalidCombinedOnlyContributorCannotReplaceValidCombinedCache() async throws {
        let (model, original, root) = try await model()
        defer { try? FileManager.default.removeItem(at: root) }
        var module = original
        module.isEnabled = true
        module.publishesStandalone = false
        model.modules = [module]
        model.settings.combinedModuleEnabled = true
        model.settings.publishToLocal = false
        let initial = await model.rebuildCombinedFromCache(schedulesAutomaticPublish: false)
        XCTAssertTrue(initial)
        let valid = try await model.fileStore.readCombined()
        try await model.fileStore.writeComponent("[Rule\nDOMAIN,broken.example,DIRECT", id: module.id)
        let rebuilt = await model.rebuildCombinedFromCache(schedulesAutomaticPublish: false)
        XCTAssertFalse(rebuilt)
        let retained = try await model.fileStore.readCombined()
        XCTAssertEqual(retained, valid)
    }

    func testLegacyWebMetadataEditPreservesUnchangedDualTargetProjection() throws {
        var module = RelayModule(name: "Both", sourceURL: "https://test.invalid/both.sgmodule", outputFileName: "Both")
        module.storageTargets = [.local, .gitHub]
        let data = try JSONSerialization.data(withJSONObject: ["name": "Renamed", "sourceURL": module.sourceURL,
            "storageLocation": module.storageLocation.rawValue])
        let legacy = try JSONDecoder().decode(WebModuleMutation.self, from: data)
        XCTAssertEqual(try legacy.draft(existing: module).storageTargets, [.local, .gitHub])
        let explicit = try JSONSerialization.data(withJSONObject: ["name": "Local only", "sourceURL": module.sourceURL,
            "storageLocation": "local", "storageTargets": ["local"]])
        XCTAssertEqual(try JSONDecoder().decode(WebModuleMutation.self, from: explicit).draft(existing: module).storageTargets, [.local])
    }

}

private final class ReviewedGitHubState: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var recordedMethods: [String] = []
    var methods: [String] { lock.withLock { recordedMethods } }
    func record(_ method: String) { lock.withLock { recordedMethods.append(method) } }
    func nextRepositoryRead() -> Int { lock.withLock { reads += 1; return reads } }
}
