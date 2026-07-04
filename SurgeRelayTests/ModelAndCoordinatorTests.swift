import Foundation
import XCTest
@testable import SurgeRelay

final class ModelAndCoordinatorTests: XCTestCase {
    func testFilenameSanitizerCreatesSurgeModuleExtension() {
        XCTAssertEqual(FilenameSanitizer.sgmoduleName(from: "YouTube Ads.sgmodule"), "YouTube-Ads.sgmodule")
        XCTAssertEqual(FilenameSanitizer.existingSgmoduleName(from: "YouTube Ads.sgmodule"), "YouTube Ads.sgmodule")
        XCTAssertEqual(FilenameSanitizer.sgmoduleName(from: "folder/bad:name"), "folder-bad-name.sgmodule")
        XCTAssertEqual(FilenameSanitizer.existingSgmoduleName(from: "folder/bad:name"), "bad-name.sgmodule")
    }

    func testAutomaticSourceFormat() throws {
        XCTAssertEqual(ModuleSourceFormat.automatic.scriptHubType(for: try XCTUnwrap(URL(string: "https://example.com/test.plugin"))), "loon-plugin")
        XCTAssertEqual(ModuleSourceFormat.automatic.scriptHubType(for: try XCTUnwrap(URL(string: "https://hub.kelee.one/Tool/Loon/Demo.lpx"))), "loon-plugin")
        XCTAssertEqual(ModuleSourceFormat.automatic.scriptHubType(for: try XCTUnwrap(URL(string: "https://example.com/test.sgmodule"))), "surge-module")
        XCTAssertEqual(ModuleSourceFormat.automatic.scriptHubType(for: try XCTUnwrap(URL(string: "https://example.com/rewrite.conf"))), "qx-rewrite")
        XCTAssertTrue(ModuleSourceFormat.automatic.isNativeSurgeModule(for: try XCTUnwrap(URL(string: "https://example.com/test.sgmodule?x=1"))))
        XCTAssertTrue(ModuleSourceFormat.surge.isNativeSurgeModule(for: try XCTUnwrap(URL(string: "https://example.com/no-extension"))))

        let detected = RelayModule(
            name: "Detected",
            sourceURL: "https://example.com/demo.lpx",
            outputFileName: "detected",
            detectedSourceFormat: .loon
        )
        XCTAssertEqual(detected.sourceFormatDisplayTitle, "自动识别（Loon）")
    }

    func testModuleSourceIdentityPreventsEquivalentDuplicates() {
        XCTAssertTrue(ModuleSourceIdentity.matches(
            " HTTPS://Example.com:443/path/module.sgmodule#preview ",
            "https://example.com/path/module.sgmodule"
        ))
        XCTAssertTrue(ModuleSourceIdentity.matches("http://example.com", "http://EXAMPLE.com:80/"))
        XCTAssertFalse(ModuleSourceIdentity.matches(
            "https://example.com/path/module.sgmodule?variant=one",
            "https://example.com/path/module.sgmodule?variant=two"
        ))
    }

    func testScriptHubSubscriptionMetadataRestoresOriginalSource() throws {
        let content = """
        #!name=Converted
        #!category=#工具

        # 🔗 模块链接
        #SUBSCRIBED http://script.hub/file/_start_/https://raw.githubusercontent.com/example/repo/main/Loon/demo.plugin/_end_/Demo.sgmodule?type=loon-plugin&target=surge-module&category=%23%E5%B7%A5%E5%85%B7&del=false&jqEnabled=true

        [Script]
        Demo = type=http-request, pattern=^https://example.com, script-path=https://example.com/demo.js
        """

        let info = try XCTUnwrap(ModuleMetadataParser.scriptHubSubscription(in: content))

        XCTAssertEqual(info.originalURL, "https://raw.githubusercontent.com/example/repo/main/Loon/demo.plugin")
        XCTAssertEqual(info.outputName, "Demo.sgmodule")
        XCTAssertEqual(info.sourceType, "loon-plugin")
        XCTAssertEqual(info.sourceFormat, .loon)
        XCTAssertEqual(info.target, "surge-module")
        XCTAssertEqual(info.category, "#工具")
        XCTAssertFalse(info.options.removeCommentedRewrites)
        XCTAssertTrue(info.options.enableJQ)
    }

    func testRelayModuleAppliesScriptHubSubscriptionMetadataToLocalSource() throws {
        let content = """
        #SUBSCRIBED http://script.hub/file/_start_/https://raw.githubusercontent.com/example/repo/main/QuantumultX/demo.conf/_end_/Demo.sgmodule?type=qx-rewrite&target=surge-module&category=%23%E5%B7%A5%E5%85%B7&del=false&jqEnabled=true
        """
        let subscription = try XCTUnwrap(ModuleMetadataParser.scriptHubSubscription(in: content))
        var module = RelayModule(
            name: "Imported",
            sourceURL: URL(filePath: "/tmp/Demo.sgmodule").absoluteString,
            sourceFormat: .surge,
            outputFileName: "Demo.sgmodule",
            sourceETag: "old-etag",
            sourceLastModified: "old-date",
            sourceContentHash: "old-hash",
            sourceCheckedAt: Date(timeIntervalSince1970: 1),
            conversionEngineRevision: "old-engine"
        )

        XCTAssertTrue(module.applyScriptHubSubscriptionMetadata(subscription))

        XCTAssertEqual(module.sourceURL, "https://raw.githubusercontent.com/example/repo/main/QuantumultX/demo.conf")
        XCTAssertEqual(module.effectiveOriginalSourceURL, module.sourceURL)
        XCTAssertTrue(module.hasRemoteOriginalSource)
        XCTAssertEqual(module.sourceFormat, .quantumultX)
        XCTAssertEqual(module.category, "#工具")
        XCTAssertEqual(module.scriptHubSubscription, subscription)
        XCTAssertTrue(module.scriptHubOptions.enableJQ)
        XCTAssertFalse(module.scriptHubOptions.removeCommentedRewrites)
        XCTAssertNil(module.sourceETag)
        XCTAssertNil(module.sourceLastModified)
        XCTAssertNil(module.sourceContentHash)
        XCTAssertNil(module.sourceCheckedAt)
        XCTAssertNil(module.conversionEngineRevision)
    }

    func testModuleArgumentMaterializePreservesSemanticComments() {
        let content = """
        #!arguments=Notify:开启通知
        #SUBSCRIBED http://script.hub/file/_start_/https://example.com/demo.plugin/_end_/Demo.sgmodule?type=loon-plugin&target=surge-module
        # 普通说明应该保留

        [General]
        force-http-engine-hosts = %APPEND% script.hub

        [Script]
        Demo = type=http-request, argument={{{Notify}}}
        """

        let output = ModuleArgumentProcessor.materialize(content, overrides: ["Notify": "关闭通知"])

        XCTAssertFalse(output.contains("#!arguments="))
        XCTAssertTrue(output.contains("#SUBSCRIBED http://script.hub/file/_start_/https://example.com/demo.plugin/_end_/Demo.sgmodule"))
        XCTAssertTrue(output.contains("# 普通说明应该保留"))
        XCTAssertTrue(output.contains("argument=关闭通知"))
    }

    func testLocalFileSourceIsAcceptedForSurgeModules() {
        var draft = ModuleDraft()
        draft.name = "Local"
        draft.sourceURL = URL(filePath: "/tmp/Local Demo.sgmodule").absoluteString
        draft.sourceFormat = .automatic

        XCTAssertNil(draft.validationMessage)
        XCTAssertFalse(draft.isEnabled)
        XCTAssertTrue(ModuleSourceIdentity.matches(
            draft.sourceURL,
            URL(filePath: "/tmp/./Local Demo.sgmodule").standardizedFileURL.absoluteString
        ))
    }

    func testModuleDraftValidatesCustomIconURL() {
        var draft = ModuleDraft()
        draft.name = "Icon"
        draft.sourceURL = "https://example.com/icon.sgmodule"
        draft.sourceFormat = .surge
        draft.iconURL = "https://example.com/icon.png"
        XCTAssertNil(draft.validationMessage)
        XCTAssertEqual(draft.normalizedCustomIconURL, "https://example.com/icon.png")

        draft.iconURL = "http://example.com/icon.png"
        XCTAssertNil(draft.validationMessage)
        XCTAssertEqual(draft.normalizedCustomIconURL, "http://example.com/icon.png")

        draft.iconURL = "data:image/png;base64,abc"
        XCTAssertEqual(draft.validationMessage, "图标 URL 仅支持 HTTP 或 HTTPS 地址。")

        draft.iconURL = "https://"
        XCTAssertEqual(draft.validationMessage, "图标 URL 仅支持 HTTP 或 HTTPS 地址。")

        draft.sourceURL = URL(filePath: "/tmp/Icon.sgmodule").absoluteString
        XCTAssertEqual(draft.validationMessage, "图标 URL 仅支持 HTTP 或 HTTPS 地址。")
    }

    func testRelayModuleDefaultsDoNotJoinCombinedModule() throws {
        let module = RelayModule(
            name: "Default",
            sourceURL: "https://example.com/default.sgmodule",
            outputFileName: "Default"
        )
        XCTAssertFalse(module.isEnabled)

        let legacyData = Data("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Legacy",
          "sourceURL": "https://example.com/legacy.sgmodule",
          "sourceFormat": "automatic",
          "outputFileName": "Legacy",
          "publishesStandalone": true
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(RelayModule.self, from: legacyData)
        XCTAssertFalse(decoded.isEnabled)
    }

    func testLocalFileModulePreservesExistingPublishedFileName() {
        let module = RelayModule(
            name: "Local Demo",
            sourceURL: URL(filePath: "/tmp/Local Demo.sgmodule").absoluteString,
            sourceFormat: .surge,
            outputFileName: "Local Demo.sgmodule",
            outputFolder: "Local Modules"
        )

        XCTAssertEqual(module.outputFileName, "Local Demo.sgmodule")
        XCTAssertEqual(module.publishedRelativePath, "Local Modules/Local Demo.sgmodule")
    }

    func testModuleDraftPublishedPathPrefersExplicitOutputFileName() {
        var draft = ModuleDraft()
        draft.name = "Renamed Display"
        draft.sourceURL = "https://example.com/source.sgmodule"
        draft.outputFileName = "Stable Name.sgmodule"
        draft.outputFolder = "Ads"

        XCTAssertEqual(draft.normalizedOutputFileName(), "Stable-Name.sgmodule")
        XCTAssertEqual(draft.publishedRelativePath(), "Ads/Stable-Name.sgmodule")

        draft.outputFileName = ""
        XCTAssertEqual(draft.normalizedOutputFileName(), "Renamed-Display.sgmodule")
        XCTAssertEqual(draft.publishedRelativePath(), "Ads/Renamed-Display.sgmodule")
    }

    func testModuleDraftPublishedPathPreservesLocalFileNameSpacing() {
        var draft = ModuleDraft()
        draft.name = "Renamed Display"
        draft.sourceURL = URL(filePath: "/tmp/Local Source.sgmodule").absoluteString
        draft.outputFileName = "Stable Name.sgmodule"
        draft.outputFolder = "Local Modules"

        XCTAssertEqual(draft.normalizedOutputFileName(), "Stable Name.sgmodule")
        XCTAssertEqual(draft.publishedRelativePath(), "Local Modules/Stable Name.sgmodule")
    }

    func testModuleOutputPathInspectorExplainsNonPublishingAndCollisions() {
        let existingID = UUID()
        let existing = RelayModule(
            id: existingID,
            name: "Existing",
            sourceURL: "https://example.com/existing.sgmodule",
            outputFileName: "Existing",
            outputFolder: "Ads"
        )

        XCTAssertEqual(
            ModuleOutputPathInspector.notice(
                for: "Ads/New.sgmodule",
                publishesStandalone: false,
                modules: [existing],
                editingModuleID: nil,
                combinedFileName: "Surge Relay"
            ),
            ModuleOutputPathNotice(message: "未开启独立发布时，不会写出这个独立模块文件。", isWarning: false)
        )
        XCTAssertEqual(
            ModuleOutputPathInspector.notice(
                for: "Surge-Relay.sgmodule",
                publishesStandalone: true,
                modules: [existing],
                editingModuleID: nil,
                combinedFileName: "Surge Relay"
            ),
            ModuleOutputPathNotice(message: "该路径与总模块文件冲突，保存时会自动加编号避免覆盖。", isWarning: true)
        )
        XCTAssertEqual(
            ModuleOutputPathInspector.notice(
                for: "Ads/Existing.sgmodule",
                publishesStandalone: true,
                modules: [existing],
                editingModuleID: nil,
                combinedFileName: "Surge Relay"
            ),
            ModuleOutputPathNotice(message: "该路径已被“Existing”使用，保存时会自动加编号避免覆盖。", isWarning: true)
        )
        XCTAssertNil(ModuleOutputPathInspector.notice(
            for: "Ads/Existing.sgmodule",
            publishesStandalone: true,
            modules: [existing],
            editingModuleID: existingID,
            combinedFileName: "Surge Relay"
        ))
    }

    func testLocalRootFileSkipsOnlyLocalSelfExport() {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let source = root.appending(path: "Ads/YouTube Ads.sgmodule")
        let module = RelayModule(
            name: "YouTube",
            sourceURL: source.absoluteString,
            sourceFormat: .surge,
            outputFileName: "YouTube Ads.sgmodule",
            outputFolder: "Ads",
            publishesStandalone: true
        )

        XCTAssertTrue(module.publishesStandalone)
        XCTAssertTrue(PublishCoordinator.shouldSkipStandaloneLocalExport(
            module,
            isLocalExport: true,
            localModuleDirectory: root.path
        ))
        XCTAssertFalse(PublishCoordinator.shouldSkipStandaloneLocalExport(
            module,
            isLocalExport: false,
            localModuleDirectory: root.path
        ))

        let copiedModule = RelayModule(
            name: "YouTube Copy",
            sourceURL: source.absoluteString,
            sourceFormat: .surge,
            outputFileName: "YouTube Copy.sgmodule",
            outputFolder: "Ads",
            publishesStandalone: true
        )
        XCTAssertFalse(PublishCoordinator.shouldSkipStandaloneLocalExport(
            copiedModule,
            isLocalExport: true,
            localModuleDirectory: root.path
        ))
    }

    func testLocalRemoteBackedModuleSkipsLocalSelfExport() {
        let module = RelayModule(
            name: "Remote Backed Local",
            sourceURL: "https://raw.githubusercontent.com/example/repo/main/qx.conf",
            sourceFormat: .quantumultX,
            outputFileName: "Remote Backed.sgmodule",
            outputFolder: "Converted",
            storageLocation: .local,
            localStorageRelativePath: "Converted/Remote Backed.sgmodule",
            preservesOutputFileName: true,
            publishesStandalone: true
        )

        XCTAssertEqual(module.storageLocation, .local)
        XCTAssertEqual(module.sourceOrigin, .remote(.quantumultX))
        XCTAssertEqual(module.publishedRelativePath, "Converted/Remote Backed.sgmodule")
        XCTAssertTrue(PublishCoordinator.shouldSkipStandaloneLocalExport(
            module,
            isLocalExport: true,
            localModuleDirectory: "/Users/example/Surge"
        ))
        XCTAssertFalse(PublishCoordinator.shouldSkipStandaloneLocalExport(
            module,
            isLocalExport: false,
            localModuleDirectory: "/Users/example/Surge"
        ))
    }

    func testLocalModuleScannerRestoresScriptHubOriginalSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Converted", directoryHint: .isDirectory), withIntermediateDirectories: true)
        let file = root.appending(path: "Converted/Demo.sgmodule")
        try Data("""
        #!name=Demo
        #!category=#工具
        #SUBSCRIBED http://script.hub/file/_start_/https://raw.githubusercontent.com/example/repo/main/QuantumultX/demo.conf/_end_/Demo.sgmodule?type=qx-rewrite&target=surge-module&del=false

        [URL Rewrite]
        ^https://example.com reject
        """.utf8).write(to: file)

        let report = try LocalModuleScanner.report(
            in: root.path,
            combinedFileName: "Surge Relay",
            existingModules: [],
            publishedFilePaths: []
        )
        let candidate = try XCTUnwrap(report.candidates.first)

        XCTAssertEqual(candidate.sourceURL, "https://raw.githubusercontent.com/example/repo/main/QuantumultX/demo.conf")
        XCTAssertEqual(candidate.localStorageRelativePath, "Converted/Demo.sgmodule")
        XCTAssertEqual(candidate.sourceFormat, .quantumultX)
        XCTAssertEqual(candidate.sourceOrigin, .remote(.quantumultX))
        XCTAssertEqual(candidate.relationshipSummary, "本地模块 · 远程 Quantumult X")
        XCTAssertEqual(candidate.category, "#工具")
        XCTAssertEqual(candidate.outputFolder, "Converted")
        XCTAssertNil(candidate.sourceContentHash)
        XCTAssertEqual(candidate.scriptHubSubscription?.sourceType, "qx-rewrite")
        XCTAssertFalse(candidate.scriptHubOptions.removeCommentedRewrites)
    }

    func testModuleOutputFolderBuildsRelativePaths() {
        XCTAssertEqual(ModuleOutputFolder.normalized(" /Ads/Video/ "), "Ads/Video")
        XCTAssertEqual(ModuleOutputFolder.normalized("../Ads"), "Ads")
        XCTAssertEqual(ModuleOutputFolder.components(" /Ads/Video/ "), ["Ads", "Video"])
        XCTAssertEqual(ModuleOutputFolder.relativePath(fileName: "YouTube Ads", folder: "Ads"), "Ads/YouTube-Ads.sgmodule")
        XCTAssertEqual(
            ModuleOutputFolder.relativePath(
                fileName: "YouTube Ads.sgmodule",
                folder: "Ads",
                preservesExistingFileName: true
            ),
            "Ads/YouTube Ads.sgmodule"
        )
        XCTAssertEqual(ModuleOutputFolder.displayTitle(for: ""), "根目录")
        XCTAssertEqual(
            ModuleOutputFolder.options(from: ["Video", "Ads/Video"], preserving: "Tools"),
            ["", "Ads/Video", "Tools", "Video"]
        )
    }

    func testUpdateFailureFormatterExplainsOriginalHTTPFailure() {
        let sourceURL = "https://raw.githubusercontent.com/example/repo/main/Missing.sgmodule?token=secret"
        let message = UpdateFailureFormatter.detailedMessage(
            for: RelayError.httpFailure(status: 404, message: "404: Not Found"),
            sourceURL: sourceURL
        )

        XCTAssertTrue(message.contains("原始链接返回 404"))
        XCTAssertTrue(message.contains("Not Found"))
        XCTAssertTrue(message.contains("https://raw.githubusercontent.com/example/repo/main/Missing.sgmodule"))
        XCTAssertFalse(message.contains("token=secret"))
        let summary = UpdateFailureFormatter.summary(from: message, maxLength: 10)
        XCTAssertTrue(summary.hasPrefix("原始链接返回"))
        XCTAssertTrue(summary.hasSuffix("…"))
    }

    func testUpdateFailureFormatterKeepsSourceCheckReasonWhenConversionIsGeneric() {
        let message = UpdateFailureFormatter.detailedMessage(
            for: RelayError.invalidOutput("Script-Hub 转换失败。"),
            sourceURL: "https://example.com/missing.conf",
            sourceCheckError: RelayError.httpFailure(status: 404, message: "")
        )

        XCTAssertTrue(message.contains("原始链接返回 404"))
        XCTAssertTrue(message.contains("转换阶段同时失败"))
    }

    func testModuleCollectionSummaryCountsDerivedStateInOnePlace() {
        let olderDate = Date(timeIntervalSince1970: 1_000)
        let newerDate = Date(timeIntervalSince1970: 2_000)
        var failed = RelayModule(
            name: "Failed",
            sourceURL: "https://example.com/failed.sgmodule",
            outputFileName: "Failed",
            publishesStandalone: true,
            isEnabled: true
        )
        failed.state = .failed
        failed.lastUpdatedAt = olderDate

        var conflicted = RelayModule(
            name: "Conflicted",
            sourceURL: "file:///Users/example/Surge/Conflicted.sgmodule",
            outputFileName: "Conflicted",
            publishesStandalone: false,
            isEnabled: true
        )
        conflicted.hasOverrideConflict = true
        conflicted.lastUpdatedAt = newerDate

        let ignored = RelayModule(
            name: "Ignored",
            sourceURL: "https://example.com/ignored.sgmodule",
            outputFileName: "Ignored",
            publishesStandalone: false,
            isEnabled: false
        )

        let summary = ModuleCollectionSummary(modules: [failed, conflicted, ignored]) { module in
            module.sourceURL.hasPrefix("https://")
        }

        XCTAssertEqual(summary.totalCount, 3)
        XCTAssertEqual(summary.enabledCount, 2)
        XCTAssertEqual(summary.standaloneCount, 1)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(summary.overrideConflictCount, 1)
        XCTAssertEqual(summary.attentionCount, 2)
        XCTAssertEqual(summary.updateableCount, 2)
        XCTAssertEqual(summary.latestUpdatedAt, newerDate)
    }

    func testPublishCoordinatorRequiresAtLeastOnePublishableModule() {
        let standalone = RelayModule(
            id: UUID(),
            name: "Standalone",
            sourceURL: "https://example.com/standalone.sgmodule",
            outputFileName: "Standalone",
            publishesStandalone: true,
            isEnabled: false
        )
        let combinedOnly = RelayModule(
            id: UUID(),
            name: "Combined",
            sourceURL: "https://example.com/combined.sgmodule",
            outputFileName: "Combined",
            publishesStandalone: false,
            isEnabled: true
        )
        let ignored = RelayModule(
            id: UUID(),
            name: "Ignored",
            sourceURL: "https://example.com/ignored.sgmodule",
            outputFileName: "Ignored",
            publishesStandalone: false,
            isEnabled: false
        )

        XCTAssertEqual(
            PublishCoordinator.publishableModuleIDs(
                modules: [standalone, combinedOnly, ignored],
                combinedModuleEnabled: true
            ),
            Set([standalone.id, combinedOnly.id])
        )
        let combinedPlan = PublishCoordinator.plan(
            modules: [standalone, combinedOnly, ignored],
            combinedModuleEnabled: true
        )
        XCTAssertEqual(combinedPlan.standaloneModules.map(\.id), [standalone.id])
        XCTAssertEqual(combinedPlan.combinedModuleIDs, Set([combinedOnly.id]))
        XCTAssertEqual(combinedPlan.assetModuleIDs, Set([standalone.id, combinedOnly.id]))
        XCTAssertTrue(combinedPlan.hasStandaloneModuleSelection)
        XCTAssertEqual(combinedPlan.scopeTitle, "总模块与独立模块")

        let combinedOnlyPlan = PublishCoordinator.plan(
            modules: [combinedOnly, ignored],
            combinedModuleEnabled: true
        )
        XCTAssertTrue(combinedOnlyPlan.hasPublishableModuleSelection)
        XCTAssertFalse(combinedOnlyPlan.hasStandaloneModuleSelection)

        XCTAssertEqual(
            PublishCoordinator.publishableModuleIDs(
                modules: [standalone, combinedOnly, ignored],
                combinedModuleEnabled: false
            ),
            Set([standalone.id])
        )
        let standalonePlan = PublishCoordinator.plan(
            modules: [standalone, combinedOnly, ignored],
            combinedModuleEnabled: false
        )
        XCTAssertEqual(standalonePlan.standaloneModules.map(\.id), [standalone.id])
        XCTAssertTrue(standalonePlan.combinedModuleIDs.isEmpty)
        XCTAssertEqual(standalonePlan.assetModuleIDs, Set([standalone.id]))
        XCTAssertEqual(standalonePlan.scopeTitle, "独立模块")

        XCTAssertFalse(PublishCoordinator.hasPublishableModuleSelection(
            modules: [ignored],
            combinedModuleEnabled: true
        ))
    }

    func testSelectedPublishPlanIgnoresNonStandaloneModules() {
        let standalone = RelayModule(
            id: UUID(),
            name: "Standalone",
            sourceURL: "https://example.com/standalone.sgmodule",
            outputFileName: "Standalone",
            publishesStandalone: true,
            isEnabled: false
        )
        let combinedOnly = RelayModule(
            id: UUID(),
            name: "Combined",
            sourceURL: "https://example.com/combined.sgmodule",
            outputFileName: "Combined",
            publishesStandalone: false,
            isEnabled: true
        )

        let plan = PublishCoordinator.selectedPlan(
            modules: [standalone, combinedOnly],
            moduleIDs: [standalone.id, combinedOnly.id]
        )

        XCTAssertEqual(plan.standaloneModules.map(\.id), [standalone.id])
        XCTAssertTrue(plan.combinedModuleIDs.isEmpty)
        XCTAssertEqual(plan.assetModuleIDs, Set([standalone.id]))
        XCTAssertTrue(plan.hasPublishableModuleSelection)

        let emptyPlan = PublishCoordinator.selectedPlan(
            modules: [standalone, combinedOnly],
            moduleIDs: [combinedOnly.id]
        )
        XCTAssertFalse(emptyPlan.hasPublishableModuleSelection)
        XCTAssertTrue(emptyPlan.assetModuleIDs.isEmpty)
    }

    func testPublishFileAssemblerBuildsCombinedStandaloneAndAssets() async throws {
        let standaloneID = UUID()
        let combinedID = UUID()
        let standalone = RelayModule(
            id: standaloneID,
            name: "Standalone",
            sourceURL: "https://example.com/standalone.sgmodule",
            outputFileName: "Standalone",
            category: "Rules",
            outputFolder: "Folder",
            publishesStandalone: true,
            argumentOverrides: ["mode": "strict"]
        )
        let combinedOnly = RelayModule(
            id: combinedID,
            name: "Combined",
            sourceURL: "https://example.com/combined.sgmodule",
            outputFileName: "Combined",
            publishesStandalone: false,
            isEnabled: true
        )
        var requestedAssetIDs = Set<UUID>()

        let files = try await PublishFileAssembler.files(
            request: PublishFileAssemblyRequest(
                plan: PublishPlan(
                    standaloneModules: [standalone],
                    combinedModuleIDs: [combinedOnly.id]
                ),
                combinedData: Data("combined".utf8),
                combinedFileName: "Combined",
                includeAssets: true,
                destination: .gitHub,
                localModuleDirectory: "/Users/example/Surge"
            ),
            readComponent: { id in
                id == standaloneID ? "source" : nil
            },
            generatedAssetFiles: { ids in
                requestedAssetIDs = ids
                return [PublishFile(name: "assets/icon.png", data: Data("asset".utf8))]
            },
            materialize: { content, overrides in
                "\(content):\(overrides["mode"] ?? "")"
            },
            applyingModuleMetadata: { name, category, content in
                "\(name)|\(category)|\(content)"
            },
            cancellationCheckpoint: {}
        )

        XCTAssertEqual(files.map(\.name), ["Combined.sgmodule", "Folder/Standalone.sgmodule", "assets/icon.png"])
        XCTAssertEqual(String(data: files[0].data, encoding: .utf8), "combined")
        XCTAssertEqual(String(data: files[1].data, encoding: .utf8), "Standalone|Rules|source:strict")
        XCTAssertEqual(String(data: files[2].data, encoding: .utf8), "asset")
        XCTAssertEqual(requestedAssetIDs, [standaloneID, combinedID])
    }

    func testPublishFileAssemblerSkipsLocalSelfExportOnlyForLocalDestination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let source = root.appending(path: "Ads/Original.sgmodule")
        let module = RelayModule(
            id: UUID(),
            name: "Original",
            sourceURL: source.absoluteString,
            sourceFormat: .surge,
            outputFileName: "Original.sgmodule",
            outputFolder: "Ads",
            publishesStandalone: true
        )
        let plan = PublishPlan(standaloneModules: [module], combinedModuleIDs: [])

        let localFiles = try await PublishFileAssembler.files(
            request: PublishFileAssemblyRequest(
                plan: plan,
                combinedData: nil,
                combinedFileName: "Combined",
                includeAssets: false,
                destination: .local,
                localModuleDirectory: root.path
            ),
            readComponent: { _ in "source" },
            generatedAssetFiles: { _ in [] },
            materialize: { content, _ in content },
            applyingModuleMetadata: { _, _, content in content },
            cancellationCheckpoint: {}
        )
        let gitHubFiles = try await PublishFileAssembler.files(
            request: PublishFileAssemblyRequest(
                plan: plan,
                combinedData: nil,
                combinedFileName: "Combined",
                includeAssets: false,
                destination: .gitHub,
                localModuleDirectory: root.path
            ),
            readComponent: { _ in "source" },
            generatedAssetFiles: { _ in [] },
            materialize: { content, _ in content },
            applyingModuleMetadata: { _, _, content in content },
            cancellationCheckpoint: {}
        )

        XCTAssertTrue(localFiles.isEmpty)
        XCTAssertEqual(gitHubFiles.map(\.name), ["Ads/Original.sgmodule"])
        XCTAssertEqual(String(data: try XCTUnwrap(gitHubFiles.first?.data), encoding: .utf8), "source")
    }
}
