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
