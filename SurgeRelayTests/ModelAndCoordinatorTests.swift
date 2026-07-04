import Foundation
import XCTest
@testable import SurgeRelay

final class ModelAndCoordinatorTests: XCTestCase {
    private enum CredentialTestError: Error {
        case unavailable
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
        XCTAssertEqual(candidate.sourceOrigin, .remote(.quantumultX))
        XCTAssertEqual(candidate.relationshipSummary, "本地模块 · 远程 Quantumult X")
        XCTAssertEqual(candidate.category, "#工具")
        XCTAssertEqual(candidate.outputFolder, "Converted")
        XCTAssertNil(candidate.sourceContentHash)
        XCTAssertEqual(candidate.scriptHubSubscription?.sourceType, "qx-rewrite")
        XCTAssertFalse(candidate.scriptHubOptions.removeCommentedRewrites)
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

    func testUpdateFailureFormatterExplainsOriginalHTTPFailure() {
        let sourceURL = "https://raw.githubusercontent.com/example/repo/main/Missing.sgmodule?token=secret"
        let message = UpdateFailureFormatter.detailedMessage(
            for: RelayError.httpFailure(status: 404, message: "404: Not Found"),
            sourceURL: sourceURL
        )

        XCTAssertTrue(message.contains("原始链接返回 404"))
        XCTAssertTrue(message.contains("Not Found"))
        XCTAssertTrue(message.contains("https://raw.githubusercontent.com/example/repo/main/Missing.sgmodule"))
        XCTAssertTrue(message.contains("仓库是否公开"))
        XCTAssertTrue(message.contains("访问权限"))
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

    func testUpdateFailureFormatterExplainsOriginalURLError() {
        let message = UpdateFailureFormatter.detailedMessage(
            for: URLError(.timedOut),
            sourceURL: "https://example.com/slow.sgmodule?token=secret"
        )

        XCTAssertTrue(message.contains("连接原始链接超时"))
        XCTAssertTrue(message.contains("https://example.com/slow.sgmodule"))
        XCTAssertFalse(message.contains("token=secret"))
    }

    func testUpdateFailurePlannerDecidesWhenToProbeOriginalSource() {
        let remote = RelayModule(
            name: "Remote",
            sourceURL: "https://example.com/source.conf",
            sourceFormat: .quantumultX,
            outputFileName: "Remote"
        )
        let local = RelayModule(
            name: "Local",
            sourceURL: URL(filePath: "/tmp/Local.sgmodule").absoluteString,
            sourceFormat: .surge,
            outputFileName: "Local"
        )

        XCTAssertTrue(UpdateFailurePlanner.shouldCheckOriginalSourceAfterConversionFailure(
            RelayError.invalidOutput("Script-Hub 转换失败"),
            module: remote,
            existingSourceCheckFailure: nil
        ))
        XCTAssertFalse(UpdateFailurePlanner.shouldCheckOriginalSourceAfterConversionFailure(
            RelayError.httpFailure(status: 404, message: "Not Found"),
            module: remote,
            existingSourceCheckFailure: nil
        ))
        XCTAssertFalse(UpdateFailurePlanner.shouldCheckOriginalSourceAfterConversionFailure(
            RelayError.invalidOutput("Script-Hub 转换失败"),
            module: local,
            existingSourceCheckFailure: nil
        ))
        XCTAssertFalse(UpdateFailurePlanner.shouldCheckOriginalSourceAfterConversionFailure(
            RelayError.invalidOutput("Script-Hub 转换失败"),
            module: remote,
            existingSourceCheckFailure: URLError(.timedOut)
        ))
    }

    func testUpdateFailurePlannerUsesLatestModuleSourceForFailureMessage() {
        let moduleID = UUID()
        let original = RelayModule(
            id: moduleID,
            name: "Module",
            sourceURL: "https://example.com/old.conf?token=secret",
            sourceFormat: .quantumultX,
            outputFileName: "Module"
        )
        let latest = RelayModule(
            id: moduleID,
            name: "Module",
            sourceURL: "https://example.com/new.conf?token=secret",
            sourceFormat: .quantumultX,
            outputFileName: "Module"
        )

        let message = UpdateFailurePlanner.detailedMessage(
            for: RelayError.httpFailure(status: 404, message: ""),
            module: original,
            latestModule: latest
        )

        XCTAssertTrue(message.contains("https://example.com/new.conf"))
        XCTAssertFalse(message.contains("https://example.com/old.conf"))
        XCTAssertFalse(message.contains("token=secret"))
    }

    func testUpdateFailurePlannerFormatsMissingCacheDetails() {
        XCTAssertEqual(
            UpdateFailurePlanner.missingCacheFailureDetail(
                moduleName: "Demo",
                failureMessage: "第一行\n第二行"
            ),
            "- Demo：第一行\n  第二行"
        )
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

    func testModuleRefreshPlannerKeepsRefreshEligibilityInOnePlace() {
        let remoteDisabled = RelayModule(
            name: "Remote",
            sourceURL: "https://example.com/remote.sgmodule",
            outputFileName: "Remote",
            publishesStandalone: false,
            isEnabled: false
        )
        let localCombinedOnly = RelayModule(
            name: "Local Combined",
            sourceURL: "file:///Users/example/Surge/Local.sgmodule",
            outputFileName: "Local.sgmodule",
            publishesStandalone: false,
            isEnabled: true
        )
        let localStandalone = RelayModule(
            name: "Local Standalone",
            sourceURL: "file:///Users/example/Surge/Standalone.sgmodule",
            outputFileName: "Standalone.sgmodule",
            publishesStandalone: true,
            isEnabled: false
        )
        let localIgnored = RelayModule(
            name: "Local Ignored",
            sourceURL: "file:///Users/example/Surge/Ignored.sgmodule",
            outputFileName: "Ignored.sgmodule",
            publishesStandalone: false,
            isEnabled: false
        )

        XCTAssertTrue(ModuleRefreshPlanner.isUpdateable(remoteDisabled, combinedModuleEnabled: false))
        XCTAssertTrue(ModuleRefreshPlanner.isUpdateable(localStandalone, combinedModuleEnabled: false))
        XCTAssertTrue(ModuleRefreshPlanner.isUpdateable(localCombinedOnly, combinedModuleEnabled: true))
        XCTAssertFalse(ModuleRefreshPlanner.isUpdateable(localCombinedOnly, combinedModuleEnabled: false))
        XCTAssertFalse(ModuleRefreshPlanner.isUpdateable(localIgnored, combinedModuleEnabled: true))

        let updateableNames = ModuleRefreshPlanner.updateableModules(
            in: [remoteDisabled, localCombinedOnly, localStandalone, localIgnored],
            combinedModuleEnabled: true
        ).map(\.name)
        XCTAssertEqual(updateableNames, ["Remote", "Local Combined", "Local Standalone"])
    }

    func testModuleRefreshPlannerLaunchUpdateRequiresMissingCacheOrDueRefresh() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = RelayModule(
            name: "Recent",
            sourceURL: "https://example.com/recent.sgmodule",
            outputFileName: "Recent",
            publishesStandalone: true,
            lastUpdatedAt: now.addingTimeInterval(-30)
        )
        let old = RelayModule(
            name: "Old",
            sourceURL: "https://example.com/old.sgmodule",
            outputFileName: "Old",
            publishesStandalone: true,
            lastUpdatedAt: now.addingTimeInterval(-4_000)
        )
        let neverUpdated = RelayModule(
            name: "Never",
            sourceURL: "https://example.com/never.sgmodule",
            outputFileName: "Never",
            publishesStandalone: true,
            lastUpdatedAt: nil
        )
        let ignoredWithoutCache = RelayModule(
            name: "Ignored",
            sourceURL: "file:///Users/example/Surge/Ignored.sgmodule",
            outputFileName: "Ignored.sgmodule",
            publishesStandalone: false,
            isEnabled: false,
            lastUpdatedAt: nil
        )

        let recentCachedShouldUpdate = await ModuleRefreshPlanner.shouldUpdateOnLaunch(
            modules: [recent, ignoredWithoutCache],
            combinedModuleEnabled: false,
            refreshIntervalMinutes: 60,
            now: now,
            componentExists: { _ in true }
        )
        let missingCacheShouldUpdate = await ModuleRefreshPlanner.shouldUpdateOnLaunch(
            modules: [recent],
            combinedModuleEnabled: false,
            refreshIntervalMinutes: 60,
            now: now,
            componentExists: { _ in false }
        )
        let neverUpdatedShouldUpdate = await ModuleRefreshPlanner.shouldUpdateOnLaunch(
            modules: [neverUpdated],
            combinedModuleEnabled: false,
            refreshIntervalMinutes: 60,
            now: now,
            componentExists: { _ in true }
        )
        let oldModuleShouldUpdate = await ModuleRefreshPlanner.shouldUpdateOnLaunch(
            modules: [recent, old],
            combinedModuleEnabled: false,
            refreshIntervalMinutes: 60,
            now: now,
            componentExists: { _ in true }
        )

        XCTAssertFalse(recentCachedShouldUpdate)
        XCTAssertTrue(missingCacheShouldUpdate)
        XCTAssertTrue(neverUpdatedShouldUpdate)
        XCTAssertTrue(oldModuleShouldUpdate)
    }

    func testDiagnosticReportBuilderRedactsModuleSourceURLs() throws {
        var settings = AppSettings()
        settings.publishToLocal = true
        settings.publishToGitHub = true
        settings.github.owner = "someone"
        settings.github.repository = "relay"
        settings.webServerEnabled = true
        settings.webServerPort = 8787

        var upstreamState = ScriptHubUpstreamState()
        upstreamState.revision = "abcdef123456"
        let module = RelayModule(
            name: "Private Source",
            sourceURL: "https://user:pass@example.com/path/module.sgmodule?token=secret#fragment",
            outputFileName: "Private Source",
            publishesStandalone: true
        )
        let request = DiagnosticReportBuildRequest(
            generatedAt: Date(timeIntervalSince1970: 1_000),
            appVersion: "1.3.8",
            operatingSystem: "macOS Test",
            settings: settings,
            modules: [module],
            upstreamState: upstreamState,
            installation: InstallationDiagnosticSnapshot(
                appPath: "/Applications/Surge Relay.app",
                appVersion: "1.3.8",
                buildNumber: "57",
                bundleIdentifier: "com.allenmiao.SurgeRelay",
                runningFromApplications: true,
                signatureStatus: "固定证书签名",
                gatekeeperStatus: "已被 Gatekeeper 接受",
                quarantineStatus: "无隔离属性",
                recentCrashReportStatus: "最近 24 小时未发现崩溃报告",
                recentCrashReports: [],
                sparkleAutomaticChecksEnabled: true,
                sparkleFeedURL: nil,
                updateRecommendation: "App 内更新可用"
            ),
            credentials: CredentialDiagnosticSnapshot.current(
                githubTokenStatus: .keychain,
                webAccessTokenStatus: .memoryOnly,
                keychainAccessProbe: .notChecked
            ),
            localModuleRoot: LocalModuleRootDiagnosticSnapshot(
                path: "/Users/example/Surge",
                exists: true,
                isDirectory: true,
                isWritable: true,
                folderCount: 1,
                moduleFileCount: 1,
                status: "目录可用",
                error: nil
            ),
            webServerState: .running,
            webManagementURL: URL(string: "http://127.0.0.1:8787/"),
            webManagementAccessModeTitle: "仅本机",
            webAccessTokenStorageStatus: .memoryOnly,
            automaticPublishScheduledAt: nil,
            automaticPublishRunsAt: nil,
            latestGitHubPublish: nil,
            workActivity: WorkActivity(
                kind: .publishing,
                startedAt: Date(timeIntervalSince1970: 900),
                blocksUpdates: true,
                canCancel: false
            ),
            statusMessage: "正在提交 GitHub 发布",
            workCancellationRequested: true,
            history: []
        )

        let report = DiagnosticReportBuilder.report(for: request)
        let snapshot = try XCTUnwrap(report.modules.first)

        XCTAssertEqual(report.storageMode, "Local + GitHub")
        XCTAssertEqual(report.githubRepository, "someone/relay")
        XCTAssertEqual(report.engineRevision, "abcdef123456")
        XCTAssertEqual(report.webServerState, "running")
        XCTAssertEqual(report.webManagementURL, "http://127.0.0.1:8787/")
        XCTAssertEqual(report.webAccessTokenStorageStatus, "钥匙串不可用，仅本次运行有效")
        XCTAssertEqual(report.activeWorkKind, "publishing")
        XCTAssertEqual(report.activeWorkTitle, "GitHub 发布")
        XCTAssertEqual(report.activeWorkStatus, "正在提交 GitHub 发布")
        XCTAssertTrue(report.activeWorkCancellationRequested)
        XCTAssertEqual(snapshot.sourceURL, "https://example.com/path/module.sgmodule")
        XCTAssertEqual(snapshot.effectiveOriginalSourceURL, "https://example.com/path/module.sgmodule")

        let json = try XCTUnwrap(String(data: DiagnosticReportBuilder.data(for: request), encoding: .utf8))
        XCTAssertFalse(json.contains("token=secret"))
        XCTAssertFalse(json.contains("user:pass"))
        XCTAssertFalse(json.contains("fragment"))
    }

    @MainActor
    func testModulePreviewContentProviderRecoversLocalSurgeSourceWithoutCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "Local Source.sgmodule")
        let sourceContent = """
        #!name=Original
        #!arguments=Mode:默认策略

        [Rule]
        FINAL,{{{Mode}}}
        """
        try Data(sourceContent.utf8).write(to: source)

        let moduleID = UUID()
        var cachedComponent: String?
        let provider = ModulePreviewContentProvider(
            hasComponent: { _ in false },
            readComponent: { _ in throw RelayError.invalidOutput("missing component") },
            readConvertedComponent: { _ in throw RelayError.invalidOutput("missing converted") },
            writeComponent: { content, id in
                XCTAssertEqual(id, moduleID)
                cachedComponent = content
            },
            readCombined: { Data() },
            materialize: { content, overrides in
                ModuleArgumentProcessor.materialize(content, overrides: overrides)
            },
            argumentInfo: { content in
                ModuleArgumentProcessor.info(in: content)
            },
            applyingModuleMetadata: { name, category, content in
                ModuleMetadataParser.applyingModuleMetadata(name: name, category: category, to: content)
            }
        )
        let module = RelayModule(
            id: moduleID,
            name: "Previewed",
            sourceURL: source.absoluteString,
            sourceFormat: .surge,
            outputFileName: "Local Source.sgmodule",
            category: "#工具",
            argumentOverrides: ["Mode": "DIRECT"]
        )

        let preview = try await provider.previewContent(for: module)

        XCTAssertEqual(cachedComponent, SurgeModuleSanitizer.sanitize(sourceContent))
        XCTAssertTrue(preview.contains("#!name=Previewed"))
        XCTAssertTrue(preview.contains("#!category=#工具"))
        XCTAssertFalse(preview.contains("#!arguments="))
        XCTAssertTrue(preview.contains("FINAL,DIRECT"))
    }

    @MainActor
    func testModulePreviewContentProviderRejectsRemoteSourceWithoutCache() async {
        let provider = ModulePreviewContentProvider(
            hasComponent: { _ in false },
            readComponent: { _ in throw RelayError.invalidOutput("missing component") },
            readConvertedComponent: { _ in throw RelayError.invalidOutput("missing converted") },
            writeComponent: { _, _ in },
            readCombined: { Data() },
            materialize: { content, _ in content },
            argumentInfo: { _ in ModuleArgumentInfo() },
            applyingModuleMetadata: { _, _, content in content }
        )
        let module = RelayModule(
            name: "Remote",
            sourceURL: "https://example.com/remote.sgmodule",
            sourceFormat: .surge,
            outputFileName: "Remote.sgmodule"
        )

        do {
            _ = try await provider.previewContent(for: module)
            XCTFail("Remote modules without cache should ask the user to update first")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("模块尚无转换缓存"))
        }
    }

    func testCredentialTokenCoordinatorUsesStoredGitHubTokenAndClearsLegacy() {
        var savedTokens: [String] = []

        let result = CredentialTokenCoordinator.loadGitHubToken(
            migratingLegacyToken: " ghp_legacy ",
            loadStoredToken: { "ghp_stored" },
            saveStoredToken: { savedTokens.append($0) }
        )

        XCTAssertEqual(result.token, "ghp_stored")
        XCTAssertEqual(result.storageStatus, .keychain)
        XCTAssertTrue(result.shouldClearLegacyToken)
        XCTAssertEqual(result.statusMessage, "GitHub Token 已改由系统钥匙串管理")
        XCTAssertTrue(savedTokens.isEmpty)
    }

    func testCredentialTokenCoordinatorMigratesLegacyGitHubToken() {
        var savedToken: String?

        let result = CredentialTokenCoordinator.loadGitHubToken(
            migratingLegacyToken: " ghp_legacy\n",
            loadStoredToken: { "" },
            saveStoredToken: { savedToken = $0 }
        )

        XCTAssertEqual(result.token, "ghp_legacy")
        XCTAssertEqual(result.storageStatus, .keychain)
        XCTAssertTrue(result.shouldClearLegacyToken)
        XCTAssertEqual(result.statusMessage, "GitHub Token 已从同步配置迁移到系统钥匙串")
        XCTAssertEqual(savedToken, "ghp_legacy")
    }

    func testCredentialTokenCoordinatorReportsEmptyGitHubTokenConfiguration() {
        let result = CredentialTokenCoordinator.loadGitHubToken(
            migratingLegacyToken: " \n",
            loadStoredToken: { "" },
            saveStoredToken: { _ in XCTFail("Empty legacy token should not be saved") }
        )

        XCTAssertEqual(result.token, "")
        XCTAssertEqual(result.storageStatus, .notConfigured)
        XCTAssertTrue(result.shouldClearLegacyToken)
        XCTAssertNil(result.statusMessage)
    }

    func testCredentialTokenCoordinatorFallsBackToLegacyGitHubTokenWhenKeychainFails() {
        let result = CredentialTokenCoordinator.loadGitHubToken(
            migratingLegacyToken: " ghp_legacy ",
            loadStoredToken: { throw CredentialTestError.unavailable },
            saveStoredToken: { _ in XCTFail("Save should not run when loading throws") }
        )

        XCTAssertEqual(result.token, "ghp_legacy")
        XCTAssertEqual(result.storageStatus, .legacyConfigurationFallback)
        XCTAssertFalse(result.shouldClearLegacyToken)
        XCTAssertEqual(result.statusMessage, "无法访问系统钥匙串，暂时沿用旧同步配置中的 GitHub Token")
    }

    func testCredentialTokenCoordinatorMarksGitHubTokenUnavailableWithoutLegacyFallback() {
        let result = CredentialTokenCoordinator.loadGitHubToken(
            migratingLegacyToken: "",
            loadStoredToken: { throw CredentialTestError.unavailable },
            saveStoredToken: { _ in XCTFail("Save should not run without a legacy token") }
        )

        XCTAssertEqual(result.token, "")
        XCTAssertEqual(result.storageStatus, .unavailable)
        XCTAssertFalse(result.shouldClearLegacyToken)
        XCTAssertNil(result.statusMessage)
    }

    func testCredentialTokenCoordinatorLoadsStoredWebAccessToken() {
        let result = CredentialTokenCoordinator.loadWebAccessToken(
            loadStoredToken: { " web-token\n" },
            saveStoredToken: { _ in XCTFail("Existing Web token should not be saved again") },
            generateToken: {
                XCTFail("Existing Web token should not generate a replacement")
                return "unused"
            }
        )

        XCTAssertEqual(result.token, "web-token")
        XCTAssertEqual(result.storageStatus, .keychain)
        XCTAssertNil(result.statusMessage)
    }

    func testCredentialTokenCoordinatorGeneratesAndStoresWebAccessTokenWhenMissing() {
        var savedToken: String?

        let result = CredentialTokenCoordinator.loadWebAccessToken(
            loadStoredToken: { " " },
            saveStoredToken: { savedToken = $0 },
            generateToken: { "generated-web-token" }
        )

        XCTAssertEqual(result.token, "generated-web-token")
        XCTAssertEqual(result.storageStatus, .keychain)
        XCTAssertNil(result.statusMessage)
        XCTAssertEqual(savedToken, "generated-web-token")
    }

    func testCredentialTokenCoordinatorUsesMemoryOnlyWebTokenWhenSaveFails() {
        var generatedTokens = ["token-for-failed-save", "memory-token"]
        var attemptedSave: String?

        let result = CredentialTokenCoordinator.loadWebAccessToken(
            loadStoredToken: { "" },
            saveStoredToken: {
                attemptedSave = $0
                throw CredentialTestError.unavailable
            },
            generateToken: { generatedTokens.removeFirst() }
        )

        XCTAssertEqual(attemptedSave, "token-for-failed-save")
        XCTAssertEqual(result.token, "memory-token")
        XCTAssertEqual(result.storageStatus, .memoryOnly)
        XCTAssertEqual(result.statusMessage, "无法访问系统钥匙串，Web 管理访问令牌仅在本次运行中有效")
        XCTAssertTrue(generatedTokens.isEmpty)
    }

    func testCredentialTokenCoordinatorGeneratesHexWebAccessTokenFromRandomBytes() {
        let token = CredentialTokenCoordinator.generateWebAccessToken(
            randomBytes: { count in (0..<count).map { UInt8($0) } }
        )

        XCTAssertEqual(
            token,
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        )
    }

    func testCredentialTokenCoordinatorFallsBackToUUIDWebAccessToken() {
        let token = CredentialTokenCoordinator.generateWebAccessToken(randomBytes: { _ in nil })

        XCTAssertEqual(token.count, 64)
        XCTAssertFalse(token.contains("-"))
    }
}
