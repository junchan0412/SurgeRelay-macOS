import Foundation
import XCTest
@testable import SurgeRelay

final class ModelAndCoordinatorTests: XCTestCase {
    func testAutomaticSourceFormat() throws {
        XCTAssertEqual(ModuleSourceFormat.automatic.scriptHubType(for: try XCTUnwrap(URL(string: "https://example.com/test.plugin"))), "loon-plugin")
        XCTAssertEqual(ModuleSourceFormat.automatic.scriptHubType(for: try XCTUnwrap(URL(string: "https://hub.kelee.one/Tool/Loon/Demo.lpx"))), "loon-plugin")
        XCTAssertEqual(ModuleSourceFormat.automatic.scriptHubType(for: try XCTUnwrap(URL(string: "https://example.com/test.sgmodule"))), "surge-module")
        XCTAssertEqual(ModuleSourceFormat.automatic.scriptHubType(for: try XCTUnwrap(URL(string: "https://example.com/rewrite.conf"))), "qx-rewrite")
        XCTAssertTrue(ModuleSourceFormat.automatic.isNativeSurgeModule(for: try XCTUnwrap(URL(string: "https://example.com/test.sgmodule?x=1"))))
        XCTAssertTrue(ModuleSourceFormat.surge.isNativeSurgeModule(for: try XCTUnwrap(URL(string: "https://example.com/no-extension"))))

        // Definitive extensions must win over a mis-recorded explicit format.
        let mislabeledSgmodule = try XCTUnwrap(URL(string: "https://raw.githubusercontent.com/example/repo/main/sgmodule/Block.HTTPDNS.sgmodule"))
        XCTAssertEqual(ModuleSourceFormat.definitiveFormat(for: mislabeledSgmodule), .surge)
        XCTAssertTrue(ModuleSourceFormat.quantumultX.isNativeSurgeModule(for: mislabeledSgmodule))
        XCTAssertEqual(ModuleSourceFormat.quantumultX.scriptHubType(for: mislabeledSgmodule), "surge-module")
        XCTAssertEqual(
            ModuleSourceFormat.repairedFormat(current: .quantumultX, sourceURL: mislabeledSgmodule),
            .surge
        )

        let detected = RelayModule(
            name: "Detected",
            sourceURL: "https://example.com/demo.lpx",
            outputFileName: "detected",
            detectedSourceFormat: .loon
        )
        XCTAssertEqual(detected.sourceFormatDisplayTitle, "自动识别（Loon）")
    }

    func testSubscriptionFormatPrefersDefinitiveSgmoduleExtensionOverQxType() throws {
        let content = """
        #SUBSCRIBED http://script.hub/file/_start_/https://raw.githubusercontent.com/VirgilClyne/GetSomeFries/refs/heads/beta/sgmodule/HTTPDNS.Block.beta.sgmodule/_end_/HTTPDNS.sgmodule?type=qx-rewrite&target=surge-module
        """
        let subscription = try XCTUnwrap(ModuleMetadataParser.scriptHubSubscription(in: content))
        XCTAssertEqual(subscription.sourceType, "qx-rewrite")
        XCTAssertEqual(subscription.sourceFormat, .surge)

        var module = RelayModule(
            name: "Block HTTPDNS",
            sourceURL: subscription.originalURL,
            sourceFormat: .quantumultX,
            outputFileName: "HTTPDNS.sgmodule",
            scriptHubSubscription: subscription
        )

        XCTAssertTrue(module.reconcileScriptHubSubscriptionMetadata(subscription))
        XCTAssertEqual(module.sourceFormat, .surge)
        XCTAssertEqual(module.scriptHubSubscription?.sourceType, "surge-module")
        XCTAssertEqual(module.scriptHubSubscription?.sourceFormat, .surge)
        XCTAssertEqual(module.initialSource, .subscribed(.surge))
        XCTAssertTrue(module.scriptHubSubscription?.subscriptionURL.contains("type=surge-module") == true)
    }

    func testRepairSourceFormatFromUpdateSourceFixesMislabeledSgmodule() {
        var module = RelayModule(
            name: "Block HTTPDNS",
            sourceURL: "https://raw.githubusercontent.com/VirgilClyne/GetSomeFries/refs/heads/beta/sgmodule/HTTPDNS.Block.beta.sgmodule",
            sourceFormat: .quantumultX,
            outputFileName: "HTTPDNS.sgmodule"
        )

        XCTAssertTrue(module.repairSourceFormatFromUpdateSource())
        XCTAssertEqual(module.sourceFormat, .surge)
        XCTAssertNil(module.detectedSourceFormat)
        XCTAssertFalse(module.repairSourceFormatFromUpdateSource())
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

        XCTAssertTrue(module.reconcileScriptHubSubscriptionMetadata(subscription))

        XCTAssertEqual(module.sourceURL, "https://raw.githubusercontent.com/example/repo/main/QuantumultX/demo.conf")
        XCTAssertEqual(module.initialSourceURL, module.sourceURL)
        XCTAssertEqual(module.updateSourceURL, module.sourceURL)
        XCTAssertEqual(module.initialSource, .subscribed(.quantumultX))
        XCTAssertTrue(module.hasRemoteUpdateSource)
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

    func testRelayModuleWithoutSubscriptionIsSelfAuthored() {
        let module = RelayModule(
            name: "Demo",
            sourceURL: "https://example.com/demo.sgmodule",
            sourceFormat: .surge,
            outputFileName: "Demo"
        )

        XCTAssertEqual(module.initialSource, .selfAuthored)
        XCTAssertNil(module.initialSourceURL)
        XCTAssertEqual(module.updateSourceURL, module.sourceURL)
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
        XCTAssertEqual(candidate.initialSource, .subscribed(.quantumultX))
        XCTAssertEqual(candidate.relationshipSummary, "本地模块 · 订阅 Quantumult X")
        XCTAssertEqual(candidate.category, "#工具")
        XCTAssertEqual(candidate.outputFolder, "Converted")
        XCTAssertNil(candidate.sourceContentHash)
        XCTAssertEqual(candidate.scriptHubSubscription?.sourceType, "qx-rewrite")
        XCTAssertFalse(candidate.scriptHubOptions.removeCommentedRewrites)
    }

    func testLocalModuleMetadataReaderRestoresSubscriptionFromManagedPhysicalFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SurgeRelayMetadataReader-\(UUID().uuidString)", directoryHint: .isDirectory)
        let directory = root.appending(path: "Modules", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directory.appending(path: "Demo Module.sgmodule")
        try Data("""
        #!name=Demo
        #SUBSCRIBED http://script.hub/file/_start_/https://example.com/original.sgmodule/_end_/Demo.sgmodule?type=surge-module&target=surge-module
        [General]
        """.utf8).write(to: file)
        let module = RelayModule(
            name: "Demo",
            sourceURL: "https://example.com/original.sgmodule",
            sourceFormat: .surge,
            outputFileName: "Demo-Module.sgmodule",
            storageLocation: .local,
            localStorageRelativePath: "Modules/Demo-Module.sgmodule"
        )

        let snapshot = try XCTUnwrap(LocalModuleMetadataReader.snapshot(
            for: module,
            rootDirectoryPath: root.path
        ))
        let subscription = try XCTUnwrap(snapshot.scriptHubSubscription)

        XCTAssertEqual(snapshot.localStorageRelativePath, "Modules/Demo Module.sgmodule")
        XCTAssertEqual(subscription.originalURL, "https://example.com/original.sgmodule")
        XCTAssertEqual(subscription.sourceFormat, .surge)
    }

    func testPublishedAddressResolverBuildsOnlyAvailableAddresses() throws {
        var settings = AppSettings()
        settings.github.owner = "someone"
        settings.github.repository = "relay"
        settings.github.branch = "main"
        settings.github.directory = "surge/modules"
        settings.github.repositoryIsPrivate = false
        settings.publishToGitHub = true
        settings.publishToLocal = true
        settings.combinedModuleEnabled = true
        settings.combinedModuleFileName = "Surge Relay"
        settings.localModuleDirectory = "/tmp/Surge Relay"
        let published = RelayModule(
            name: "Ads",
            sourceURL: "https://example.com/ads.sgmodule",
            outputFileName: "Ads",
            outputFolder: "Folder",
            publishesStandalone: true
        )
        let combinedOnly = RelayModule(
            name: "Combined",
            sourceURL: "https://example.com/combined.sgmodule",
            outputFileName: "Combined",
            publishesStandalone: false
        )

        XCTAssertEqual(
            try XCTUnwrap(PublishedAddressResolver.standaloneURL(for: published, settings: settings)).absoluteString,
            "https://raw.githubusercontent.com/someone/relay/main/surge/modules/Folder/Ads.sgmodule"
        )
        XCTAssertNil(PublishedAddressResolver.standaloneURL(for: combinedOnly, settings: settings))
        XCTAssertEqual(
            try XCTUnwrap(PublishedAddressResolver.combinedGitHubURL(settings: settings)).lastPathComponent,
            "Surge-Relay.sgmodule"
        )
        XCTAssertEqual(
            try XCTUnwrap(PublishedAddressResolver.combinedLocalFileURL(settings: settings)).path,
            "/tmp/Surge Relay/Surge-Relay.sgmodule"
        )

        settings.github.repositoryIsPrivate = true
        XCTAssertNil(PublishedAddressResolver.standaloneURL(for: published, settings: settings))
        settings.github.publicBaseURL = "https://surge-relay.example.workers.dev/"
        XCTAssertEqual(
            try XCTUnwrap(PublishedAddressResolver.standaloneURL(for: published, settings: settings)).absoluteString,
            "https://surge-relay.example.workers.dev/Folder/Ads.sgmodule"
        )

        settings.publishToGitHub = false
        XCTAssertNil(PublishedAddressResolver.combinedGitHubURL(settings: settings))
        XCTAssertNil(PublishedAddressResolver.standaloneURL(for: published, settings: settings))
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

}
