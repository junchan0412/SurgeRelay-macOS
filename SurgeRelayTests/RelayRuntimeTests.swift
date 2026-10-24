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

    func testCurrentAndSelectedPublishDoNotReplaceManifestAfterRootChangesDuringExport() async throws {
        for selected in [false, true] {
            try await assertLocalPublishRejectsContextChange(.root, selected: selected)
        }
    }

    func testCurrentAndSelectedPublishRetainJournalAfterGenerationOrWorkspaceChangesDuringExport() async throws {
        for selected in [false, true] {
            for change in [LocalPublishContextChange.generation, .transition, .retirement] {
                try await assertLocalPublishRejectsContextChange(change, selected: selected)
            }
        }
    }

    func testPartialLocalPublishDoesNotReplaceManifestAfterRootChangesDuringExport() async throws {
        for selected in [false, true] {
            try await assertLocalPublishRejectsContextChange(.root, selected: selected, failsAfterWrite: true)
        }
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

    func testDuplicateLocalModuleKeepsDistinctOutputAfterReload() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(
            id: UUID(), name: "Duplicate regression",
            configurationDirectory: root.appending(path: "Configuration"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false
        )
        let model = AppModel(context: context, persistsOnInit: false)
        model.workspaceIsActive = false
        model.settings.publishToLocal = false
        model.settings.publishToGitHub = false
        model.settings.localModuleDirectory = root.appending(path: "Modules").path
        let source = RelayModule(
            name: "Local",
            sourceURL: root.appending(path: "Modules/My Module.sgmodule").absoluteString,
            outputFileName: "My Module.sgmodule",
            storageLocation: .local,
            localStorageRelativePath: "My Module.sgmodule"
        )
        model.modules = [source]

        try model.duplicateModule(id: source.id)
        try await model.flushPersistence()
        let copy = try XCTUnwrap(model.modules.last)
        XCTAssertEqual(copy.outputFileName, "My Module-2.sgmodule")
        XCTAssertEqual(copy.localStorageRelativePath, "My Module-2.sgmodule")
        XCTAssertNotEqual(copy.publishedRelativePath, source.publishedRelativePath)
        let restored = ModuleNamingPlanner.normalizedModuleNaming(
            model.modules,
            combinedFileName: model.settings.combinedModuleFileName,
            localModuleDirectory: model.settings.localModuleDirectory
        )
        XCTAssertEqual(restored, model.modules)
        model.persistenceFeedbackTask?.cancel()
    }

    func testMissingBiliverseOutputCanBeWrittenDespiteUnrelatedUnmanagedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "Missing local output",
            configurationDirectory: root.appending(path: "Config"), cacheDirectory: root.appending(path: "Cache"),
            allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        defer { model.persistenceFeedbackTask?.cancel() }
        let directory = root.appending(path: "Modules")
        model.settings.localModuleDirectory = directory.path
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = true
        model.settings.combinedModuleEnabled = false
        var missing = RelayModule(name: "Biliverse.Enhanced", sourceURL: "https://test.invalid/Biliverse.sgmodule",
            outputFileName: "Biliverse.Enhanced.sgmodule", outputFolder: "Sgmodule(#7增强模块)",
            storageLocation: .local, localStorageRelativePath: "Sgmodule(#7增强模块)/Biliverse.Enhanced.sgmodule",
            publishesStandalone: true, isEnabled: false)
        missing.storageTargets = [.local, .gitHub]
        let blocked = RelayModule(name: "Unmanaged", sourceURL: "https://test.invalid/Unmanaged.sgmodule",
            outputFileName: "Unmanaged.sgmodule", storageLocation: .local)
        model.modules = [blocked, missing]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("#!name=Personal\n[Rule]\nFINAL,DIRECT\n".utf8)
        try original.write(to: directory.appending(path: blocked.publishedRelativePath))
        for module in model.modules {
            try await model.fileStore.writeComponent("#!name=Cached\n[Rule]\nDOMAIN,example.org,DIRECT\n", id: module.id)
        }
        let before = await model.localModuleOutputSnapshot(for: missing)
        XCTAssertEqual(before.state, .missing)
        let rebuilt = await model.rebuildCombinedFromCache(schedulesAutomaticPublish: false)
        XCTAssertFalse(rebuilt)

        try await model.writeLocalModuleOutput(moduleID: missing.id)

        let after = await model.localModuleOutputSnapshot(for: missing)
        XCTAssertEqual(after.state, .present)
        XCTAssertTrue(after.hasManagementHeader)
        XCTAssertTrue(model.settings.localPublishedFilePaths.contains(missing.publishedRelativePath))
        XCTAssertNil(model.presentedError)
        XCTAssertNil(model.latestGitHubPublish)
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: blocked.publishedRelativePath)), original)
    }

    func testLocalOutputAdoptionReviewsCurrentOutputAndRejectsChangedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "Recover changed source",
            configurationDirectory: root.appending(path: "Config"), cacheDirectory: root.appending(path: "Cache"),
            allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        defer { model.persistenceFeedbackTask?.cancel() }
        let directory = root.appending(path: "Modules")
        model.settings.localModuleDirectory = directory.path
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = false
        model.settings.combinedModuleEnabled = false
        let module = RelayModule(name: "百度网盘去广告", sourceURL: "https://test.invalid/Baidu.plugin", sourceFormat: .loon,
            outputFileName: "百度网盘去广告.beta.sgmodule", outputFolder: "Sgmodule(#3广告模块)",
            storageLocation: .local, localStorageRelativePath: "Sgmodule(#3广告模块)/百度网盘去广告.beta.sgmodule",
            publishesStandalone: false)
        model.modules = [module]
        let destination = directory.appending(path: module.publishedRelativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("#!name=Personal\n[Rule]\nDOMAIN,old.example,DIRECT\n".utf8)
        try original.write(to: destination)
        try await model.fileStore.writeComponent("#!name=Converted\n[Rule]\nDOMAIN,new.example,REJECT\n", id: module.id)
        let review = try await model.prepareLocalOutputAdoption(moduleID: module.id)
        XCTAssertGreaterThan(review.diff.addedCount, 0)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let edited = original + Data("# Edited after review\n".utf8)
        try edited.write(to: destination)
        do {
            try await model.confirmLocalOutputAdoption(review)
            XCTFail("Adoption must reject a file changed since comparison")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: destination), edited)

        let refreshed = try await model.prepareLocalOutputAdoption(moduleID: module.id)
        try await model.confirmLocalOutputAdoption(refreshed)
        XCTAssertTrue(ManagedPublishedFile.isManaged(try Data(contentsOf: destination), relativePath: module.publishedRelativePath))
        XCTAssertTrue(String(decoding: try Data(contentsOf: destination), as: UTF8.self).contains("DOMAIN,new.example,REJECT"))
        let backups = try XCTUnwrap(FileManager.default.enumerator(at: context.configurationDirectory.appending(path: "Backups/LocalOutputAdoption"),
            includingPropertiesForKeys: nil)).allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "sgmodule" }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), edited)
    }

    func testFullLocalRebuildPublishesAndRetainsCurrentAssets() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "Local asset regression",
            configurationDirectory: root.appending(path: "Configuration"), cacheDirectory: root.appending(path: "Cache"),
            allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        let directory = root.appending(path: "Modules")
        model.settings.localModuleDirectory = directory.path
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = false
        model.settings.combinedModuleEnabled = false
        model.settings.watchesLocalModuleChanges = false
        model.settings.automaticallyPublish = false
        let module = RelayModule(name: "With assets", sourceURL: "https://test.invalid/assets.sgmodule", sourceFormat: .surge,
            outputFileName: "With-assets.sgmodule", storageLocation: .local, isEnabled: true)
        model.modules = [module]
        let assetPath = "assets/\(module.id.uuidString.lowercased())/demo.js"
        let content = "#!name=With assets\n[Script]\nDemo = type=http-request, pattern=^https://example.org, script-path=\(assetPath)\n"
        let firstAsset = Data("const version = 1;".utf8)
        try await model.fileStore.commitConversion(ConversionResult(content: content,
            requestURL: try XCTUnwrap(URL(string: module.sourceURL)), assets: [GeneratedAsset(relativePath: assetPath, data: firstAsset)]), id: module.id)
        let selected = try await model.selectedLocalPublishedFiles(moduleIDs: [module.id])
        try await model.publishSelectedLocalFiles(selected)
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: assetPath)), firstAsset)

        for includesCombined in [false, true] {
            model.settings.combinedModuleEnabled = includesCombined
            let currentAsset = Data("const combined = \(includesCombined);".utf8)
            try await model.fileStore.replaceAssets([GeneratedAsset(relativePath: assetPath, data: currentAsset)], id: module.id)
            let succeeded = await model.rebuildCombinedFromCache(schedulesAutomaticPublish: false)
            XCTAssertTrue(succeeded, model.presentedError ?? "Local rebuild failed")
            XCTAssertNil(model.pendingPublishPreview, "Current assets must never appear in obsolete-file cleanup")
            XCTAssertTrue(model.settings.localPublishedFilePaths.contains(assetPath))
            XCTAssertEqual(try Data(contentsOf: directory.appending(path: assetPath)), currentAsset)
        }
        model.persistenceFeedbackTask?.cancel()
    }

    func testLocalSelfExportSourceIsNeverProposedOrDeletedByCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "Source cleanup regression",
            configurationDirectory: root.appending(path: "Configuration"), cacheDirectory: root.appending(path: "Cache"),
            allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        let directory = root.appending(path: "Modules")
        model.settings.localModuleDirectory = directory.path
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = false
        model.settings.combinedModuleEnabled = false
        model.settings.watchesLocalModuleChanges = false
        model.settings.automaticallyPublish = false
        let sourcePath = "Source.sgmodule"
        _ = try await model.fileStore.exportPublishedFiles([
            PublishFile(name: sourcePath, data: Data("#!name=Source\n[General]\n".utf8)),
            PublishFile(name: "Old.sgmodule", data: Data("#!name=Old\n[General]\n".utf8))
        ], toRootDirectory: directory.path)
        let source = directory.appending(path: sourcePath)
        let original = try Data(contentsOf: source)
        model.settings.localPublishedRootDirectory = directory.path
        model.settings.localPublishedFilePaths = [sourcePath, "Old.sgmodule"]
        model.modules = [RelayModule(name: "Source", sourceURL: source.absoluteString, sourceFormat: .surge,
            outputFileName: sourcePath, storageLocation: .local, localStorageRelativePath: sourcePath)]

        try await model.publishCurrentFiles(combinedData: nil)
        XCTAssertEqual(model.pendingPublishPreview?.deletedFiles, ["Old.sgmodule"])
        XCTAssertEqual(model.settings.localPublishedFilePaths, ["Old.sgmodule"])
        await model.confirmPendingPublish()
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "Old.sgmodule").path))
        XCTAssertNil(model.pendingPublishPreview)

        model.pendingPublishPreview = PublishPreview(destination: .local, targetDescription: directory.path,
            activeFiles: [], changedFiles: [], deletedFiles: [sourcePath], localExpectedHashes: [sourcePath: original.sha256String],
            localReviewFingerprint: model.localCleanupReviewFingerprint())
        await model.confirmPendingPublish()
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertNotNil(model.presentedError)
        model.persistenceFeedbackTask?.cancel()
    }

    func testLocalImportIsIdempotentAndNeverChangesSourceFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = root.appending(path: "Modules")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("#!name=Local\n[General]\n".utf8)
        let source = directory.appending(path: "My Module.sgmodule")
        try original.write(to: source)
        let context = WorkspaceContext(
            id: UUID(), name: "Import regression",
            configurationDirectory: root.appending(path: "Configuration"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false
        )
        let model = AppModel(context: context, persistsOnInit: false)
        model.settings.localModuleDirectory = directory.path
        model.settings.watchesLocalModuleChanges = false
        model.settings.combinedModuleEnabled = false
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = false
        model.settings.automaticallyPublish = false
        model.settings.localPublishedRootDirectory = root.appending(path: "Previous").path
        model.settings.localPublishedFilePaths = ["My Module.sgmodule"]

        let report = try await model.scanExistingLocalModules()
        XCTAssertEqual(report.candidates.count, 1)
        await model.importLocalModules(report.candidates)
        XCTAssertEqual(model.modules.count, 1)
        XCTAssertEqual(model.statusMessage, "已导入 1 个本地模块")
        let imported = try XCTUnwrap(model.modules.first)
        let content = try await model.fileStore.readConvertedComponent(id: imported.id)
        XCTAssertTrue(content.contains("#!name=Local"))
        await model.importLocalModules(report.candidates)
        XCTAssertEqual(model.modules.count, 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["My Module.sgmodule"])
        model.persistenceFeedbackTask?.cancel()
    }

    func testClearOutputPreservesRegisteredSourceWithManagedMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "Modules")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "Source.sgmodule")
        let original = ManagedPublishedFile.dataWrapping(Data("#!name=Source\n[Rule]\nFINAL,DIRECT\n".utf8),
            relativePath: "Source.sgmodule")
        try original.write(to: source)
        let context = WorkspaceContext(id: UUID(), name: "Delete regression",
            configurationDirectory: root.appending(path: "Configuration"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        model.settings.localModuleDirectory = directory.path
        model.settings.combinedModuleEnabled = false
        model.settings.publishToLocal = false
        model.settings.publishToGitHub = false
        model.settings.watchesLocalModuleChanges = false
        let module = RelayModule(name: "Source", sourceURL: source.absoluteString,
            outputFileName: "Source.sgmodule", storageLocation: .local,
            localStorageRelativePath: "Source.sgmodule")
        model.modules = [module]

        model.settings.publishToLocal = true
        model.settings.localPublishedRootDirectory = directory.path
        model.settings.localPublishedFilePaths = ["Source.sgmodule"]

        await model.deleteModule(id: module.id, mode: .clearOutput)

        XCTAssertTrue(model.modules.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(model.pendingPublishPreview?.deletedFiles.contains("Source.sgmodule") == true)
        XCTAssertFalse(model.settings.localPublishedFilePaths.contains("Source.sgmodule"))
        XCTAssertFalse(model.isWorking)
        model.persistenceFeedbackTask?.cancel()
    }

    func testFailedOutputDeletionRetainsModuleAndCachedContent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "Modules")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "Source.sgmodule")
        let personal = Data("personal module".utf8)
        try personal.write(to: source)
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "Output.sgmodule"),
            withDestinationURL: source)
        let context = WorkspaceContext(id: UUID(), name: "Failed delete regression",
            configurationDirectory: root.appending(path: "Configuration"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        model.settings.localModuleDirectory = directory.path
        model.settings.watchesLocalModuleChanges = false
        let module = RelayModule(name: "Output", sourceURL: "https://test.invalid/output.sgmodule",
            outputFileName: "Output.sgmodule", storageLocation: .local,
            localStorageRelativePath: "Output.sgmodule")
        model.modules = [module]
        try await model.fileStore.writeComponent("[Rule]\nFINAL,DIRECT", id: module.id)
        let cached = try await model.fileStore.readComponent(id: module.id)

        await model.deleteModule(id: module.id, mode: .clearOutput)

        XCTAssertEqual(model.modules, [module])
        XCTAssertTrue(model.presentedError?.contains("符号链接") == true)
        let retained = try await model.fileStore.readComponent(id: module.id)
        XCTAssertEqual(retained, cached)
        XCTAssertEqual(try Data(contentsOf: source), personal)
        XCTAssertFalse(model.isWorking)
        model.persistenceFeedbackTask?.cancel()
    }

    func testSubscribedLocalImportUsesPhysicalBytesAndOnlyRebuildsCache() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = root.appending(path: "Modules")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory.appending(path: "assets"), withIntermediateDirectories: true)
        let source = directory.appending(path: "Subscribed.sgmodule")
        let original = Data("""
        #!name=Subscribed Local
        #SUBSCRIBED http://script.hub/file/_start_/https://upstream.invalid/Loon/demo.plugin/_end_/Subscribed.sgmodule?type=loon-plugin&target=surge-module
        # Keep this local explanation
        [Script]
        Local = type=http-request, pattern=^https://local.example, script-path=assets/local.js
        """.utf8)
        let resource = Data("const retained = true;".utf8)
        try original.write(to: source)
        try resource.write(to: directory.appending(path: "assets/local.js"))
        let context = WorkspaceContext(
            id: UUID(), name: "Subscribed import regression",
            configurationDirectory: root.appending(path: "Configuration"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false
        )
        let model = AppModel(context: context, persistsOnInit: false)
        model.settings.localModuleDirectory = directory.path
        model.settings.watchesLocalModuleChanges = false
        model.settings.combinedModuleEnabled = true
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = true
        model.settings.automaticallyPublish = true
        let contributor = RelayModule(name: "Combined contributor", sourceURL: "https://test.invalid/existing.sgmodule",
                                      outputFileName: "Existing", isEnabled: true)
        model.modules = [contributor]
        try await model.fileStore.writeComponent("[Rule]\nDOMAIN,existing.example,DIRECT", id: contributor.id)

        let report = try await model.scanExistingLocalModules()
        await model.importLocalModules(report.candidates)

        XCTAssertEqual(model.modules.count, 2)
        XCTAssertEqual(model.statusMessage, "已导入 1 个本地模块")
        XCTAssertNil(model.presentedError)
        XCTAssertNil(model.automaticPublishRunsAt)
        let imported = try XCTUnwrap(model.modules.last)
        XCTAssertEqual(imported.sourceFormat, .loon)
        XCTAssertEqual(imported.updateSourceURL, "https://upstream.invalid/Loon/demo.plugin")
        XCTAssertEqual(imported.initialSource, .subscribed(.loon))
        let cached = try await model.fileStore.readConvertedComponent(id: imported.id)
        XCTAssertTrue(cached.contains("# Keep this local explanation"))
        XCTAssertTrue(cached.contains("script-path=assets/local.js"))
        let combined = try await model.fileStore.readCombined()
        XCTAssertTrue(String(decoding: combined, as: UTF8.self).contains("existing.example"))
        await model.importLocalModules(report.candidates)
        XCTAssertEqual(model.modules.count, 2)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: "assets/local.js")), resource)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["Subscribed.sgmodule", "assets"])
        model.persistenceFeedbackTask?.cancel()
    }

    func testScheduledRefreshUpdatesOnlyDueModulesAndPreservesCombinedCache() async throws {
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
        let context = WorkspaceContext(
            id: UUID(), name: "Scheduled refresh regression",
            configurationDirectory: root.appending(path: "Configuration"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false
        )
        let model = AppModel(context: context, persistsOnInit: false)
        model.settings.publishToLocal = false
        model.settings.publishToGitHub = false
        model.settings.automaticallyUpdateScriptHub = false
        model.settings.automaticallyPublish = false
        model.settings.watchesLocalModuleChanges = false
        model.settings.localModuleDirectory = root.path
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
        model.persistenceFeedbackTask?.cancel()
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

    private enum LocalPublishContextChange {
        case root, generation, transition, retirement
    }

    private func assertLocalPublishRejectsContextChange(
        _ change: LocalPublishContextChange,
        selected: Bool,
        failsAfterWrite: Bool = false
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(id: UUID(), name: "Local publish context regression",
            configurationDirectory: root.appending(path: "Configuration"), cacheDirectory: root.appending(path: "Cache"),
            allowsLegacyFallback: false)
        let oldDirectory = root.appending(path: "OldModules")
        let newDirectory = root.appending(path: "NewModules")
        let checkpoint = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let store = ModuleFileStore(cacheDirectory: context.cacheDirectory, configurationDirectory: context.configurationDirectory,
            allowsLegacyFallback: false, resourceInterruption: { phase in
                guard phase == .renamed else { return }
                checkpoint.continuation.yield(())
                guard resume.wait(timeout: .now() + 10) == .success else {
                    throw RelayError.invalidOutput("Timed out waiting for the context change")
                }
                if failsAfterWrite { throw RelayError.invalidOutput("Injected post-write failure") }
            })
        let model = AppModel(context: context, fileStore: store, persistsOnInit: false)
        defer { model.persistenceFeedbackTask?.cancel() }
        model.settings.localModuleDirectory = oldDirectory.path
        model.settings.localPublishedRootDirectory = oldDirectory.path
        model.settings.localPublishedFilePaths = ["Existing.sgmodule"]
        model.settings.publishToLocal = true
        model.settings.publishToGitHub = false
        model.settings.combinedModuleEnabled = false
        model.settings.automaticallyPublish = false
        model.settings.watchesLocalModuleChanges = false
        let module = RelayModule(name: "Context", sourceURL: "https://test.invalid/context.sgmodule", sourceFormat: .surge,
            outputFileName: "Context.sgmodule", storageLocation: .local)
        model.modules = [module]
        let assetPath = "assets/\(module.id.uuidString.lowercased())/context.js"
        let assetData = Data("const context = 1;".utf8)
        let content = "#!name=Context\n[Script]\nContext = type=http-request, pattern=^https://example.org, script-path=\(assetPath)\n"
        try await store.commitConversion(ConversionResult(content: content,
            requestURL: try XCTUnwrap(URL(string: module.sourceURL)),
            assets: [GeneratedAsset(relativePath: assetPath, data: assetData)]), id: module.id)
        let files = [PublishFile(name: module.publishedRelativePath, data: Data(content.utf8)),
                     PublishFile(name: assetPath, data: assetData)]
        let publish = Task { @MainActor in
            defer { checkpoint.continuation.finish() }
            if selected { try await model.publishSelectedLocalFiles(files) }
            else { try await model.publishCurrentFiles(combinedData: nil) }
        }
        var events = checkpoint.stream.makeAsyncIterator()
        let reachedCheckpoint = await events.next()
        XCTAssertNotNil(reachedCheckpoint)
        switch change {
        case .root:
            model.settings.localModuleDirectory = newDirectory.path
            model.settings.localPublishedRootDirectory = newDirectory.path
            model.settings.localPublishedFilePaths = ["New.sgmodule"]
        case .generation:
            model.registerLocalChange()
        case .transition:
            model.isWorkspaceTransitioning = true
        case .retirement:
            model.workspaceIsActive = false
        }
        let expectedRoot = model.settings.localPublishedRootDirectory
        let expectedPaths = model.settings.localPublishedFilePaths
        resume.signal()
        do {
            try await publish.value
            XCTFail("A stale publish must not commit the previous context's manifest")
        } catch {
            XCTAssertTrue(error is CancellationError, error.localizedDescription)
        }
        XCTAssertEqual(model.settings.localPublishedRootDirectory, expectedRoot)
        XCTAssertEqual(model.settings.localPublishedFilePaths, expectedPaths)
        XCTAssertNil(model.pendingPublishPreview)
        XCTAssertEqual(try Data(contentsOf: oldDirectory.appending(path: assetPath)), assetData)
        let recovered = try await store.recoverPublishedResourcePaths(rootDirectoryPath: oldDirectory.path)
        XCTAssertEqual(recovered, [assetPath])
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDirectory.path))
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
