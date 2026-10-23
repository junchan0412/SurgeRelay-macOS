import Foundation
import XCTest
@testable import SurgeRelay

final class LocalModuleImportPlannerTests: XCTestCase {
    func testLocalModuleImportPlannerPreservesPhysicalModulePath() {
        let plannedAt = Date(timeIntervalSince1970: 10_000)
        let candidate = scanCandidate(
            relativePath: "Ads/My Module.sgmodule",
            sourceURL: "https://example.com/ads.conf",
            sourceFormat: .loon,
            name: "  Imported Module  ",
            outputFileName: "Stale Generated Name.sgmodule",
            category: " #工具 ",
            outputFolder: "Stale Folder",
            sourceContentHash: "source-hash"
        )

        let plan = LocalModuleImportPlanner.plan(
            candidates: [candidate],
            existingModules: [],
            combinedModuleFileName: "Relay",
            plannedAt: plannedAt
        )

        XCTAssertTrue(plan.failures.isEmpty)
        XCTAssertEqual(plan.entries.count, 1)
        let imported = plan.entries[0].module
        XCTAssertEqual(imported.name, "Imported Module")
        XCTAssertEqual(imported.sourceFormat, .loon)
        XCTAssertEqual(imported.outputFileName, "My Module.sgmodule")
        XCTAssertEqual(imported.outputFolder, "Ads")
        XCTAssertEqual(imported.category, "#工具")
        XCTAssertEqual(imported.storageLocation, .local)
        XCTAssertEqual(imported.localStorageRelativePath, "Ads/My Module.sgmodule")
        XCTAssertEqual(imported.publishedRelativePath, "Ads/My Module.sgmodule")
        XCTAssertTrue(imported.preservesOutputFileName)
        XCTAssertFalse(imported.isEnabled)
        XCTAssertTrue(imported.publishesStandalone)
        XCTAssertEqual(imported.detectedSourceFormat, .loon)
        XCTAssertEqual(imported.sourceContentHash, "source-hash")
        XCTAssertEqual(imported.sourceCheckedAt, plannedAt)
        XCTAssertEqual(imported.createdAt, plannedAt)
    }

    func testLocalModuleImportPlannerRejectsStalePreviewAndReservedPaths() {
        let existing = RelayModule(
            name: "Existing",
            sourceURL: "https://example.com/existing.sgmodule",
            outputFileName: "Renamed.sgmodule",
            outputFolder: "Ads",
            storageLocation: .local,
            localStorageRelativePath: "Ads/Existing.sgmodule"
        )
        let candidates = [
            scanCandidate(relativePath: "Relay.sgmodule", sourceURL: "https://example.com/relay.sgmodule"),
            scanCandidate(relativePath: "Ads/Existing.sgmodule", sourceURL: "https://example.com/new.sgmodule"),
            scanCandidate(relativePath: "Copy.sgmodule", sourceURL: "HTTPS://EXAMPLE.COM:443/existing.sgmodule#preview")
        ]

        let plan = LocalModuleImportPlanner.plan(
            candidates: candidates,
            existingModules: [existing],
            combinedModuleFileName: "Relay"
        )

        XCTAssertTrue(plan.entries.isEmpty)
        XCTAssertEqual(plan.failures.count, 3)
        XCTAssertTrue(plan.failures[0].contains("与总模块冲突"))
        XCTAssertTrue(plan.failures[1].contains("路径已纳入管理"))
        XCTAssertTrue(plan.failures[2].contains("来源文件已纳入管理"))
    }

    func testLocalModuleImportPlannerDeduplicatesSourceAndPhysicalPath() {
        let blank = scanCandidate(relativePath: "Blank.sgmodule", name: "   ")
        let first = scanCandidate(relativePath: "Tools/Demo.sgmodule", sourceURL: "https://example.com/one.sgmodule")
        let repeatedPath = scanCandidate(relativePath: "tools/demo.sgmodule", sourceURL: "https://example.com/two.sgmodule")
        let repeatedSource = scanCandidate(relativePath: "Tools/Demo Copy.sgmodule", sourceURL: "https://example.com/one.sgmodule")
        let distinct = scanCandidate(relativePath: "Tools/Demo Two.sgmodule", sourceURL: "https://example.com/two.sgmodule")

        let plan = LocalModuleImportPlanner.plan(
            candidates: [blank, first, repeatedPath, repeatedSource, distinct],
            existingModules: [],
            combinedModuleFileName: "Relay"
        )

        XCTAssertEqual(plan.failures.count, 3)
        XCTAssertEqual(plan.failures[0], "Blank.sgmodule：模块名称不能为空")
        XCTAssertEqual(plan.entries.map(\.module.publishedRelativePath), ["Tools/Demo.sgmodule", "Tools/Demo Two.sgmodule"])
        let repeatedPlan = LocalModuleImportPlanner.plan(
            candidates: [first, distinct],
            existingModules: plan.entries.map(\.module),
            combinedModuleFileName: "Relay"
        )
        XCTAssertTrue(repeatedPlan.entries.isEmpty)
        XCTAssertEqual(repeatedPlan.failures.count, 2)
    }

    func testLocalModuleImportPlannerRejectsPreviewFromChangedRoot() {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        var candidate = scanCandidate(relativePath: "Demo.sgmodule")
        candidate.rootDirectoryPath = base.appending(path: "Old").path
        let plan = LocalModuleImportPlanner.plan(
            candidates: [candidate],
            existingModules: [],
            combinedModuleFileName: "Relay",
            localModuleDirectory: base.appending(path: "New").path
        )
        XCTAssertTrue(plan.entries.isEmpty)
        XCTAssertEqual(plan.failures, ["Demo.sgmodule：本地模块根目录已改变，请重新扫描"])
    }

    func testImportRejectsRegisteredPhysicalSourceEvenWhenCandidateRestoresRemoteSubscription() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let subscription = try XCTUnwrap(ModuleMetadataParser.scriptHubSubscription(from:
            "https://script.hub/file/_start_/https://example.com/demo.conf/_end_/Demo.sgmodule?type=qx-rewrite&target=surge-module"))
        let existing = RelayModule(name: "Existing",
            sourceURL: root.appending(path: "Demo.sgmodule").absoluteString,
            outputFileName: "Published-Elsewhere.sgmodule", storageLocation: .gitHub)
        var candidate = scanCandidate(relativePath: "Demo.sgmodule", sourceURL: subscription.originalURL)
        candidate.scriptHubSubscription = subscription

        let plan = LocalModuleImportPlanner.plan(candidates: [candidate], existingModules: [existing],
            combinedModuleFileName: "Relay", localModuleDirectory: root.path)

        XCTAssertTrue(plan.entries.isEmpty)
        XCTAssertEqual(plan.failures.count, 1)
        XCTAssertTrue(plan.failures[0].contains("路径已纳入管理"))
    }

    func testLocalModuleImportPlannerBuildsUserVisibleStatuses() {
        let candidate = scanCandidate(relativePath: "Tools/Demo.sgmodule")
        let skipped = LocalModuleScanSkippedFile(relativePath: "Relay.sgmodule", reason: "这是当前总模块文件")
        let emptyReport = LocalModuleScanReport(candidates: [], skippedFiles: [])
        let skippedOnlyReport = LocalModuleScanReport(candidates: [], skippedFiles: [skipped])
        let candidateReport = LocalModuleScanReport(candidates: [candidate], skippedFiles: [skipped])

        XCTAssertEqual(LocalModuleImportPlanner.scanStartedStatus, "正在扫描本地模块根目录…")
        XCTAssertEqual(LocalModuleImportPlanner.scanFailedStatus, "本地模块扫描失败")
        XCTAssertEqual(LocalModuleImportPlanner.noSelectionStatus, "没有选择需要导入的本地模块")
        XCTAssertEqual(LocalModuleImportPlanner.emptyImportStatus, "本地模块扫描完成，但没有可导入项目")
        XCTAssertEqual(
            LocalModuleImportPlanner.scanStatus(for: emptyReport),
            "未发现可导入的新本地模块"
        )
        XCTAssertEqual(
            LocalModuleImportPlanner.scanStatus(for: skippedOnlyReport),
            "未发现可导入的新本地模块；已跳过 1 个文件"
        )
        XCTAssertEqual(
            LocalModuleImportPlanner.scanStatus(for: candidateReport),
            "发现 1 个可导入本地模块，跳过 1 个文件"
        )
        XCTAssertEqual(
            LocalModuleImportPlanner.importStatus(importedCount: 2, failureCount: 0),
            "已导入 2 个本地模块"
        )
        XCTAssertEqual(
            LocalModuleImportPlanner.importStatus(importedCount: 2, failureCount: 1),
            "已导入 2 个本地模块；1 个文件无法导入"
        )
        XCTAssertNil(LocalModuleImportPlanner.failureDetails([], isPartialImport: true))
        XCTAssertEqual(
            LocalModuleImportPlanner.failureDetails(["A.sgmodule：失败"], isPartialImport: false),
            "以下本地模块无法导入：\nA.sgmodule：失败"
        )
        XCTAssertEqual(
            LocalModuleImportPlanner.failureDetails(["A.sgmodule：失败"], isPartialImport: true),
            "部分本地模块无法导入：\nA.sgmodule：失败"
        )
    }

    func testLocalModuleImportPlannerBuildsSuccessfulImportedModuleState() {
        let importedAt = Date(timeIntervalSince1970: 30_000)
        let localSourceURL = URL(filePath: "/Users/example/Surge/Demo.sgmodule").absoluteString
        let module = RelayModule(
            name: "Imported",
            sourceURL: localSourceURL,
            sourceFormat: .surge,
            outputFileName: "Demo.sgmodule",
            storageLocation: .local,
            localStorageRelativePath: "Demo.sgmodule",
            preservesOutputFileName: true,
            detectedSourceFormat: .surge,
            contentHash: "old-hash",
            state: .failed,
            lastError: "previous failure"
        )
        let convertedContent = """
        #!name=Converted
        #SUBSCRIBED http://script.hub/file/_start_/https://example.com/QuantumultX/demo.conf/_end_/Demo.sgmodule?type=qx-rewrite&target=surge-module&category=%23%E5%B7%A5%E5%85%B7&jqEnabled=true

        [Script]
        Demo = type=http-request, pattern=^https://example.com
        """

        let imported = LocalModuleImportPlanner.successfulImportModule(
            module,
            convertedContent: convertedContent,
            contentHash: "new-hash",
            importedAt: importedAt
        )

        XCTAssertEqual(imported.sourceURL, "https://example.com/QuantumultX/demo.conf")
        XCTAssertEqual(imported.storageLocation, .local)
        XCTAssertTrue(imported.preservesOutputFileName)
        XCTAssertEqual(imported.sourceFormat, .quantumultX)
        XCTAssertEqual(imported.category, "#工具")
        XCTAssertTrue(imported.scriptHubOptions.enableJQ)
        XCTAssertNil(imported.sourceETag)
        XCTAssertNil(imported.sourceLastModified)
        XCTAssertNil(imported.sourceContentHash)
        XCTAssertNil(imported.sourceCheckedAt)
        XCTAssertNil(imported.conversionEngineRevision)
        XCTAssertEqual(imported.contentHash, "new-hash")
        XCTAssertEqual(imported.lastUpdatedAt, importedAt)
        XCTAssertEqual(imported.state, .current)
        XCTAssertNil(imported.lastError)
        XCTAssertNil(imported.detectedSourceFormat)
    }

    func testSuccessfulImportPreservesSubscriptionDiscoveredFromPhysicalFile() throws {
        let subscription = try XCTUnwrap(ModuleMetadataParser.scriptHubSubscription(in: """
        #SUBSCRIBED http://script.hub/file/_start_/https://example.com/original.sgmodule/_end_/Demo.sgmodule?type=surge-module&target=surge-module
        """))
        let module = RelayModule(
            name: "Imported",
            sourceURL: subscription.originalURL,
            sourceFormat: .surge,
            outputFileName: "Demo.sgmodule",
            storageLocation: .local,
            localStorageRelativePath: "Demo.sgmodule",
            scriptHubSubscription: subscription
        )

        let imported = LocalModuleImportPlanner.successfulImportModule(
            module,
            convertedContent: "#!name=Native upstream without wrapper metadata\n[General]",
            contentHash: "new-hash"
        )

        XCTAssertEqual(imported.scriptHubSubscription, subscription)
        XCTAssertEqual(imported.initialSource, .subscribed(.surge))
        XCTAssertEqual(imported.updateSourceURL, subscription.originalURL)
    }

    private func scanCandidate(
        relativePath: String,
        localStorageRelativePath: String? = nil,
        sourceURL: String = "https://example.com/source.sgmodule",
        sourceFormat: ModuleSourceFormat = .surge,
        name: String = "Demo",
        outputFileName: String = "Demo.sgmodule",
        category: String = "",
        outputFolder: String = "",
        sourceContentHash: String? = nil
    ) -> LocalModuleScanCandidate {
        LocalModuleScanCandidate(
            relativePath: relativePath,
            localStorageRelativePath: localStorageRelativePath ?? relativePath,
            sourceURL: sourceURL,
            sourceFormat: sourceFormat,
            name: name,
            outputFileName: outputFileName,
            category: category,
            outputFolder: outputFolder,
            scriptHubOptions: ScriptHubOptions(),
            scriptHubSubscription: nil,
            sourceContentHash: sourceContentHash
        )
    }
}
