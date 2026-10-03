import Foundation
import XCTest
@testable import SurgeRelay

@MainActor
final class RelayRuntimeTests: XCTestCase {
    func testNativeUpdateCommitsSnapshotAndFinishesActivity() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Runtime.sgmodule")
        try Data("#!name=Runtime\n[Rule]\nDOMAIN,example.org,DIRECT\n".utf8).write(to: source)
        let model = isolatedModel()
        let module = RelayModule(name: "Runtime", sourceURL: source.absoluteString, outputFileName: "Runtime", publishesStandalone: true)
        model.modules = [module]
        await model.updateAll(refreshesScriptHubEngine: false)
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.workActivity.isActive)
        XCTAssertTrue(model.synchronizingModuleIDs.isEmpty)
        XCTAssertEqual(model.synchronizationCompletedCount, 1)
        XCTAssertEqual(model.modules.first?.state, .current)
        XCTAssertNotNil(model.modules.first?.sourceContentHash)
        let content = try await model.fileStore.readConvertedComponent(id: module.id)
        XCTAssertTrue(content.contains("DOMAIN,example.org,DIRECT"))
        XCTAssertEqual(model.updateHistory.first?.outcome, .updated)
        try await model.fileStore.removeComponent(id: module.id)
    }

    func testCancelledQueuedUpdateDoesNotChangeWorkState() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        model.modules = [RelayModule(name: "Queued", sourceURL: "https://test.invalid/queued.sgmodule", outputFileName: "Queued")]
        await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await model.updateAll()
        }.value
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.modules.first?.state, .never)
        XCTAssertTrue(model.updateHistory.isEmpty)
    }

    func testSummaryCacheInvalidatesAndDoesNotDoubleCountAttention() throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        model.modules = [RelayModule(name: "DNS", sourceURL: "https://test.invalid/dns.sgmodule", outputFileName: "DNS")]
        XCTAssertEqual(model.moduleSummary.attentionCount, 0)
        model.modules[0].state = .failed
        model.modules[0].hasOverrideConflict = true
        XCTAssertEqual(model.moduleSummary.attentionCount, 1)
        XCTAssertEqual(model.moduleSummary.overrideConflictCount, 1)
        model.modules = []
        XCTAssertEqual(model.moduleSummary.totalCount, 0)
    }

    func testStreamingFingerprintPreservesExistingHashes() async {
        let content = "#!name=Streaming\n"
        let assets = [GeneratedAsset(relativePath: "assets/b.js", data: Data("second".utf8)), GeneratedAsset(relativePath: "assets/a.js", data: Data("first".utf8))]
        var legacy = Data(content.utf8)
        for asset in assets.sorted(by: { $0.relativePath < $1.relativePath }) {
            legacy.append(0); legacy.append(contentsOf: asset.relativePath.utf8); legacy.append(0); legacy.append(asset.data)
        }
        let fingerprint = await ModuleProcessingWorker().contentFingerprint(of: content, assets: assets)
        XCTAssertEqual(fingerprint, legacy.sha256String)
    }

    func testArgumentChangesInvalidateContentSearchCache() {
        var module = RelayModule(name: "Args", sourceURL: "https://test.invalid/args.sgmodule", outputFileName: "Args")
        module.contentHash = "same-conversion"
        let before = ModuleSearchIndex.contentCacheKey(for: module)
        module.argumentOverrides["policy"] = "Proxy"
        XCTAssertNotEqual(before, ModuleSearchIndex.contentCacheKey(for: module))
    }

    func testPartialUpdateDoesNotReportSuccessWhenCombinedCacheIsMissing() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        model.settings.combinedModuleEnabled = true
        model.modules = [RelayModule(name: "Missing", sourceURL: "https://test.invalid/missing.sgmodule", outputFileName: "Missing", isEnabled: true)]
        try await model.fileStore.writeCombined("previous combined output")
        await model.finishModuleUpdateRun(
            ModuleUpdateRunResult(components: [], failures: 0, missingCacheModuleNames: [], missingCacheDetails: [], contentChanged: true),
            generation: model.localChangeGeneration,
            rebuildFromCache: true
        )
        XCTAssertTrue(model.statusMessage.contains("缺少模块缓存"))
        XCTAssertTrue(model.presentedError?.contains("Missing") == true)
        XCTAssertNil(model.automaticPublishRunsAt)
        let combined = try await model.fileStore.readCombined()
        XCTAssertEqual(String(data: combined, encoding: .utf8), "previous combined output")
        try await model.fileStore.removeCombined()
    }

    func testRebuildReportsLocalExportFailureWithoutCombinedContributors() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = isolatedModel()
        model.modules = []
        model.settings.publishToLocal = true
        model.settings.localModuleDirectory = root.path
        let succeeded = await model.rebuildCombinedFromCache()
        XCTAssertFalse(succeeded)
        XCTAssertTrue(model.statusMessage.contains("输出刷新失败"))
        XCTAssertNotNil(model.presentedError)
        XCTAssertNil(model.automaticPublishRunsAt)
    }

    func testSelectedPublishCannotReuseOverwritePermissionFromAnotherRoot() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "Demo.sgmodule"
        let original = Data("#!name=User-owned\n[Rule]\nDOMAIN,user.example,DIRECT".utf8)
        try original.write(to: root.appending(path: path))
        let model = isolatedModel()
        model.settings.localModuleDirectory = root.path
        model.settings.localPublishedRootDirectory = root.appending(path: "old-root").path
        model.settings.localPublishedFilePaths = [path]
        do {
            try await model.publishSelectedLocalFiles([PublishFile(name: path, data: Data("replacement".utf8))])
            XCTFail("A previous root must not authorize overwriting an unrelated file")
        } catch {
            XCTAssertEqual(try Data(contentsOf: root.appending(path: path)), original)
        }
        XCTAssertNotEqual(model.settings.localPublishedRootDirectory, root.path)
    }

    func testFullUpdateReportsExportFailureWithoutClaimingCacheWasUnchanged() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = isolatedModel()
        model.settings.combinedModuleEnabled = true
        model.settings.publishToLocal = true
        model.settings.localModuleDirectory = root.path
        let module = RelayModule(name: "Updated", sourceURL: "https://test.invalid/updated.sgmodule", outputFileName: "Updated", isEnabled: true)
        model.modules = [module]
        await model.finishModuleUpdateRun(
            ModuleUpdateRunResult(components: [(module, "[Rule]\nDOMAIN,updated.example,DIRECT")], failures: 0, missingCacheModuleNames: [], missingCacheDetails: [], contentChanged: true),
            generation: model.localChangeGeneration
        )
        XCTAssertTrue(model.presentedError?.contains("刷新模块输出失败") == true)
        XCTAssertFalse(model.presentedError?.contains("未被覆盖") == true)
        XCTAssertTrue(model.statusMessage.contains("输出刷新失败"))
        XCTAssertNil(model.automaticPublishRunsAt)
        let cached = try await model.fileStore.readCombined()
        XCTAssertTrue(String(data: cached, encoding: .utf8)?.contains("updated.example") == true)
        try await model.fileStore.removeCombined()
    }

    func testSelectedPublishDropsUnrelatedManifestAfterRootChange() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = isolatedModel()
        model.settings.localModuleDirectory = root.path
        model.settings.localPublishedRootDirectory = root.appending(path: "old-root").path
        model.settings.localPublishedFilePaths = ["Old.sgmodule"]
        try await model.publishSelectedLocalFiles([PublishFile(name: "New.sgmodule", data: Data("#!name=New".utf8))])
        XCTAssertEqual(model.settings.localPublishedFilePaths, ["New.sgmodule"])
        XCTAssertEqual(model.settings.localPublishedRootDirectory, root.path)
    }

    func testFailedRestorePreservesManualOverride() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        let module = RelayModule(name: "Draft", sourceURL: "https://test.invalid/draft.sgmodule", outputFileName: "Draft")
        model.modules = [module]
        try await model.fileStore.writeComponentOverride("precious manual edit", id: module.id)
        let original = try await model.fileStore.readComponent(id: module.id)
        do {
            _ = try await model.restorePreviewContent(for: module)
            XCTFail("Restoring without converted content must fail")
        } catch {
            let retained = try await model.fileStore.readComponent(id: module.id)
            XCTAssertEqual(retained, original)
        }
        XCTAssertFalse(model.isWorking)
        try await model.fileStore.removeComponent(id: module.id)
    }

    func testWebPreviewETagRejectsStaleWriteAndTracksRestoredContent() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        let module = RelayModule(name: "Conditional Draft", sourceURL: "https://test.invalid/conditional.sgmodule", outputFileName: "Conditional")
        model.modules = [module]
        try await model.fileStore.writeComponent("#!name=Conditional Draft\n[Rule]\nDOMAIN,original.example,DIRECT", id: module.id)
        let path = "/api/modules/\(module.id)/preview"
        let original = await WebManagementAPI.response(for: previewRequest("GET", path: path), model: model)
        XCTAssertEqual(original.status, 200)
        let originalETag = try XCTUnwrap(original.headers["ETag"])
        XCTAssertEqual(originalETag, WebManagementAPI.previewETag(for: String(decoding: original.body, as: UTF8.self)))
        let saved = await WebManagementAPI.response(
            for: previewRequest("PUT", path: path, content: "[Rule]\nDOMAIN,first.example,DIRECT", etag: originalETag), model: model
        )
        XCTAssertEqual(saved.status, 200)
        let latest = await WebManagementAPI.response(for: previewRequest("GET", path: path), model: model)
        XCTAssertEqual(saved.headers["ETag"], latest.headers["ETag"])
        XCTAssertNotEqual(saved.headers["ETag"], originalETag)
        let stale = await WebManagementAPI.response(
            for: previewRequest("PUT", path: path, content: "[Rule]\nDOMAIN,stale.example,DIRECT", etag: originalETag), model: model
        )
        XCTAssertEqual(stale.status, 412)
        XCTAssertEqual(stale.reason, "Precondition Failed")
        let retained = await WebManagementAPI.response(for: previewRequest("GET", path: path), model: model)
        XCTAssertEqual(retained.body, latest.body)
        XCTAssertFalse(model.isWorking)
        let confirmed = await WebManagementAPI.response(
            for: previewRequest("PUT", path: path, content: "[Rule]\nDOMAIN,confirmed.example,DIRECT", etag: saved.headers["ETag"]), model: model
        )
        XCTAssertEqual(confirmed.status, 200)
        let restored = await WebManagementAPI.response(for: previewRequest("DELETE", path: path), model: model)
        XCTAssertEqual(restored.status, 200)
        let afterRestore = await WebManagementAPI.response(for: previewRequest("GET", path: path), model: model)
        XCTAssertEqual(restored.headers["ETag"], afterRestore.headers["ETag"])
        XCTAssertEqual(restored.body, afterRestore.body)
        XCTAssertTrue(String(decoding: restored.body, as: UTF8.self).contains("original.example"))
        try await model.fileStore.removeComponent(id: module.id)
    }

    func testConcurrentWebPreviewWritesCannotBothUseSameBaseVersion() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        let module = RelayModule(name: "Concurrent Draft", sourceURL: "https://test.invalid/concurrent.sgmodule", outputFileName: "Concurrent")
        model.modules = [module]
        try await model.fileStore.writeComponent("#!name=Concurrent Draft\n[Rule]\nDOMAIN,original.example,DIRECT", id: module.id)
        let path = "/api/modules/\(module.id)/preview"
        let original = await WebManagementAPI.response(for: previewRequest("GET", path: path), model: model)
        let etag = try XCTUnwrap(original.headers["ETag"])
        let firstRequest = previewRequest("PUT", path: path, content: "[Rule]\nDOMAIN,first.example,DIRECT", etag: etag)
        let secondRequest = previewRequest("PUT", path: path, content: "[Rule]\nDOMAIN,second.example,DIRECT", etag: etag)
        let first = Task { @MainActor in await WebManagementAPI.response(for: firstRequest, model: model) }
        let second = Task { @MainActor in await WebManagementAPI.response(for: secondRequest, model: model) }
        let responses = await [first.value, second.value]
        XCTAssertEqual(responses.filter { $0.status == 200 }.count, 1)
        XCTAssertEqual(responses.filter { $0.status == 409 || $0.status == 412 }.count, 1)
        let latest = await WebManagementAPI.response(for: previewRequest("GET", path: path), model: model)
        let winner = try XCTUnwrap(responses.firstIndex { $0.status == 200 })
        XCTAssertEqual(latest.headers["ETag"], responses[winner].headers["ETag"])
        XCTAssertTrue(String(decoding: latest.body, as: UTF8.self).contains(winner == 0 ? "first.example" : "second.example"))
        XCTAssertFalse(model.isWorking)
        try await model.fileStore.removeComponent(id: module.id)
    }

    func testSavingPreviewRejectsMetadataDeletionAndArgumentMutations() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        let module = RelayModule(name: "Protected", sourceURL: "https://test.invalid/protected.sgmodule", outputFileName: "Protected", argumentOverrides: ["policy": "Original"])
        model.modules = [module]
        try await model.fileStore.writeComponent("#!name=Protected\n[Rule]\nDOMAIN,original.example,DIRECT", id: module.id)
        let cached = try await model.fileStore.readComponent(id: module.id)
        let generation = model.localChangeGeneration
        model.beginWork(.savingPreview)
        var draft = ModuleDraft(module: module)
        draft.name = "Changed while saving"
        XCTAssertThrowsError(try model.updateModule(id: module.id, from: draft)) { XCTAssertEqual($0 as? PreviewContentSaveError, .busy) }
        XCTAssertThrowsError(try model.duplicateModule(id: module.id)) { XCTAssertEqual($0 as? PreviewContentSaveError, .busy) }
        model.setModuleArgument(moduleID: module.id, key: "policy", value: "New", defaultValue: "Default")
        model.resetModuleArguments(moduleID: module.id)
        model.setModuleIncludedInCombined(id: module.id, included: true)
        await model.deleteModule(id: module.id)
        await model.acceptOverrideConflict(moduleID: module.id)
        XCTAssertEqual(model.modules, [module])
        XCTAssertEqual(model.localChangeGeneration, generation)
        let retained = try await model.fileStore.readComponent(id: module.id)
        XCTAssertEqual(retained, cached)
        XCTAssertEqual(model.workActivity.kind, .savingPreview)
        model.endWork(.savingPreview)
        try await model.fileStore.removeComponent(id: module.id)
    }

    func testWebMutationsReturnBusyDuringPreviewSaveBeforeChangingState() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        let module = RelayModule(name: "Busy", sourceURL: "https://test.invalid/busy.sgmodule", outputFileName: "Busy")
        model.modules = [module]
        model.beginWork(.savingPreview)
        defer { model.endWork(.savingPreview) }
        let base = "/api/modules/\(module.id)"
        for (method, path) in [("PUT", base), ("DELETE", base), ("PUT", base + "/arguments"), ("DELETE", base + "/arguments"), ("POST", base + "/enabled"), ("POST", base + "/override-conflict"), ("POST", "/api/modules")] {
            let response = await WebManagementAPI.response(for: previewRequest(method, path: path, content: "{}"), model: model)
            XCTAssertEqual(response.status, 409, "\(method) \(path) must reject a busy mutation")
        }
        XCTAssertEqual(model.modules, [module])
    }

    func testDeletedModuleCannotBeSavedOrRestoredFromStaleEditorReference() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        let removed = RelayModule(name: "Removed", sourceURL: "https://test.invalid/removed.sgmodule", outputFileName: "Removed")
        model.modules = []
        do {
            _ = try await model.savePreviewContent("orphaned edit", for: removed)
            XCTFail("A removed module must not recreate its override")
        } catch { XCTAssertTrue(error.localizedDescription.contains("已移除")) }
        do {
            _ = try await model.restorePreviewContent(for: removed)
            XCTFail("A removed module must not be restored")
        } catch { XCTAssertTrue(error.localizedDescription.contains("已移除")) }
        let hasOverride = await model.fileStore.hasOverride(id: removed.id)
        XCTAssertFalse(hasOverride)
        XCTAssertFalse(model.isWorking)
    }

    func testPreviewSaveResultSeparatesCanonicalContentFromHash() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        let module = RelayModule(name: "Canonical", sourceURL: "https://test.invalid/canonical.sgmodule", outputFileName: "Canonical")
        model.modules = [module]
        try await model.fileStore.writeComponent("#!name=Canonical\n[Rule]\nFINAL,DIRECT", id: module.id)
        let result = try await model.savePreviewContent("[Rule]\nDOMAIN,edited.example,DIRECT", for: module)
        XCTAssertTrue(result.content.contains("#!name=Canonical"))
        XCTAssertTrue(result.content.contains("edited.example"))
        XCTAssertEqual(result.contentHash, Data(result.content.utf8).sha256String)
        XCTAssertNotEqual(result.content, result.contentHash)
        let actual = try await model.previewContent(for: model.modules[0])
        XCTAssertEqual(result.content, actual)
        try await model.fileStore.removeComponent(id: module.id)
    }

    private func previewRequest(_ method: String, path: String, content: String = "", etag: String? = nil) -> WebHTTPRequest {
        WebHTTPRequest(method: method, path: path, query: [:], headers: etag.map { ["if-match": $0] } ?? [:],
                       body: Data(content.utf8), isLoopback: true)
    }

    func testModuleMutationFlushPersistsLatestSnapshotBeforeReturning() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let model = isolatedModel()
        model.modules = [RelayModule(name: "Queued persistence", sourceURL: "https://test.invalid/persist.sgmodule", outputFileName: "Persist")]
        try model.persistModules()
        model.modules[0].name = "Latest queued persistence"
        try model.persistModules()
        try await model.flushPersistence()
        let data = try Data(contentsOf: PersistenceStore.registryURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = try decoder.decode([RelayModule].self, from: data)
        XCTAssertEqual(stored.first?.name, "Latest queued persistence")
        XCTAssertNil(model.persistenceError)
    }

    func testScheduledRefreshUpdatesOnlyDueModulesAndPreservesCombinedCache() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fastURL = root.appending(path: "Fast.sgmodule")
        try Data("#!name=Fast\n[Rule]\nDOMAIN,fast-new.example,DIRECT".utf8).write(to: fastURL)
        let now = Date.now
        let fast = RelayModule(name: "Fast", sourceURL: fastURL.absoluteString, outputFileName: "Fast", isEnabled: true,
                               lastUpdatedAt: now.addingTimeInterval(-7_200), refreshIntervalMinutes: 5,
                               lastRefreshAttemptAt: now.addingTimeInterval(-7_200))
        let slow = RelayModule(name: "Slow", sourceURL: root.appending(path: "Missing-but-not-due.sgmodule").absoluteString,
                               outputFileName: "Slow", isEnabled: true, lastUpdatedAt: now,
                               refreshIntervalMinutes: 60, lastRefreshAttemptAt: now)
        let model = isolatedModel()
        model.settings.combinedModuleEnabled = true
        model.modules = [fast, slow]
        try await model.fileStore.writeComponent("#!name=Fast\n[Rule]\nDOMAIN,fast-old.example,DIRECT", id: fast.id)
        try await model.fileStore.writeComponent("#!name=Slow\n[Rule]\nDOMAIN,slow-cached.example,DIRECT", id: slow.id)
        await model.updateAll(refreshesScriptHubEngine: false, trigger: .scheduled)
        XCTAssertEqual(model.synchronizationTotalCount, 1)
        XCTAssertEqual(model.modules.first(where: { $0.id == slow.id })?.lastRefreshAttemptAt, now)
        let combined = String(decoding: try await model.fileStore.readCombined(), as: UTF8.self)
        XCTAssertTrue(combined.contains("fast-new.example"))
        XCTAssertTrue(combined.contains("slow-cached.example"))
        try await model.fileStore.removeComponent(id: fast.id)
        try await model.fileStore.removeComponent(id: slow.id)
        try await model.fileStore.removeCombined()
    }

    func testManualRefreshBypassesOrdinaryBackoffButWaitsForServer() async throws {
        guard AppRuntimeOptions.isUIQAMode else { throw XCTSkip("Requires isolated QA configuration") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Manual.sgmodule")
        try Data("#!name=Manual\n[Rule]\nDOMAIN,manual.example,DIRECT".utf8).write(to: source)
        var module = RelayModule(name: "Manual", sourceURL: source.absoluteString, outputFileName: "Manual",
                                 consecutiveFailureCount: 3, nextRetryAt: .now.addingTimeInterval(3_600))
        let model = isolatedModel()
        model.modules = [module]
        await model.updateAll(refreshesScriptHubEngine: false)
        let saved = try XCTUnwrap(model.modules.first)
        XCTAssertEqual(saved.consecutiveFailureCount, 0)
        XCTAssertNil(saved.nextRetryAt)
        XCTAssertNotNil(saved.lastUpdatedAt)
        module = saved
        module.serverRetryAfter = .now.addingTimeInterval(3_600)
        module.serverRetrySourceURL = module.updateSourceURL
        model.modules = [module]
        await model.updateAll(refreshesScriptHubEngine: false)
        XCTAssertEqual(model.modules.first?.lastRefreshAttemptAt, module.lastRefreshAttemptAt)
        XCTAssertTrue(model.statusMessage.contains("Retry-After"))
        try await model.fileStore.removeComponent(id: module.id)
    }

    private func isolatedModel() -> AppModel {
        let model = AppModel()
        model.settings.publishToLocal = false
        model.settings.publishToGitHub = false
        model.settings.combinedModuleEnabled = false
        model.settings.automaticallyUpdateScriptHub = false
        model.settings.automaticallyPublish = false
        model.settings.github.owner = ""
        model.settings.github.repository = ""
        model.updateHistory = []
        return model
    }
}
