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
