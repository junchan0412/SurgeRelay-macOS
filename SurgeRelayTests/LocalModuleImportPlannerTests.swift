import Foundation
import XCTest
@testable import SurgeRelay

final class LocalModuleImportPlannerTests: XCTestCase {
    func testLocalModuleImportPlannerBuildsLocalModulesAndAvoidsReservedPaths() {
        let plannedAt = Date(timeIntervalSince1970: 10_000)
        let existing = RelayModule(
            name: "Existing",
            sourceURL: "https://example.com/existing.sgmodule",
            outputFileName: "Existing.sgmodule",
            outputFolder: "Ads"
        )
        let combinedCollision = scanCandidate(
            relativePath: "Relay.sgmodule",
            localStorageRelativePath: "Relay.sgmodule",
            sourceURL: "https://example.com/relay.conf",
            sourceFormat: .quantumultX,
            name: "  Imported Relay  ",
            outputFileName: "Relay.sgmodule",
            category: " #工具 ",
            sourceContentHash: "source-hash"
        )
        let existingCollision = scanCandidate(
            relativePath: "Ads/Existing.sgmodule",
            localStorageRelativePath: "Ads/Existing.sgmodule",
            sourceURL: "https://example.com/ads.conf",
            sourceFormat: .loon,
            name: "Ads",
            outputFileName: "Existing.sgmodule",
            outputFolder: "Ads"
        )

        let plan = LocalModuleImportPlanner.plan(
            candidates: [combinedCollision, existingCollision],
            existingModules: [existing],
            combinedModuleFileName: "Relay",
            plannedAt: plannedAt
        )

        XCTAssertTrue(plan.failures.isEmpty)
        XCTAssertEqual(plan.entries.count, 2)
        let relay = plan.entries[0].module
        XCTAssertEqual(relay.name, "Imported Relay")
        XCTAssertEqual(relay.sourceFormat, .quantumultX)
        XCTAssertEqual(relay.outputFileName, "Relay-2.sgmodule")
        XCTAssertEqual(relay.outputFolder, "")
        XCTAssertEqual(relay.category, "#工具")
        XCTAssertEqual(relay.storageLocation, .local)
        XCTAssertEqual(relay.localStorageRelativePath, "Relay.sgmodule")
        XCTAssertTrue(relay.preservesOutputFileName)
        XCTAssertFalse(relay.isEnabled)
        XCTAssertTrue(relay.publishesStandalone)
        XCTAssertEqual(relay.detectedSourceFormat, .quantumultX)
        XCTAssertEqual(relay.sourceContentHash, "source-hash")
        XCTAssertEqual(relay.sourceCheckedAt, plannedAt)
        XCTAssertEqual(relay.createdAt, plannedAt)

        let ads = plan.entries[1].module
        XCTAssertEqual(ads.outputFolder, "Ads")
        XCTAssertEqual(ads.outputFileName, "Existing-2.sgmodule")
        XCTAssertEqual(ads.publishedRelativePath, "Ads/Existing-2.sgmodule")
        XCTAssertEqual(ads.detectedSourceFormat, .loon)
    }

    func testLocalModuleImportPlannerRecordsInvalidNamesAndDeduplicatesCandidates() {
        let blank = scanCandidate(
            relativePath: "Blank.sgmodule",
            name: "   ",
            outputFileName: "Blank.sgmodule"
        )
        let first = scanCandidate(
            relativePath: "Tools/Demo.sgmodule",
            name: "Demo One",
            outputFileName: "Demo.sgmodule",
            outputFolder: "Tools"
        )
        let second = scanCandidate(
            relativePath: "Tools/Demo Copy.sgmodule",
            name: "Demo Two",
            outputFileName: "Demo.sgmodule",
            outputFolder: "Tools"
        )

        let plan = LocalModuleImportPlanner.plan(
            candidates: [blank, first, second],
            existingModules: [],
            combinedModuleFileName: "Relay",
            plannedAt: Date(timeIntervalSince1970: 20_000)
        )

        XCTAssertEqual(plan.failures, ["Blank.sgmodule：模块名称不能为空"])
        XCTAssertEqual(plan.entries.map(\.candidate.relativePath), ["Tools/Demo.sgmodule", "Tools/Demo Copy.sgmodule"])
        XCTAssertEqual(plan.entries.map(\.module.outputFileName), ["Demo.sgmodule", "Demo-2.sgmodule"])
        XCTAssertEqual(plan.entries.map(\.module.publishedRelativePath), ["Tools/Demo.sgmodule", "Tools/Demo-2.sgmodule"])
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
