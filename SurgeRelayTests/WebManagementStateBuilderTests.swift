import XCTest
@testable import SurgeRelay

final class WebManagementStateBuilderTests: XCTestCase {
    func testModuleEditorPayloadUsesSharedDefaultAndTargetFolders() {
        var settings = AppSettings()
        settings.publishToLocal = true
        settings.publishToGitHub = false

        let payload = WebManagementStateBuilder.moduleEditorPayload(
            settings: settings,
            localOutputFolders: ["", "Local"],
            githubOutputFolders: ["", "Remote"]
        )

        XCTAssertEqual(payload.defaultStorageLocation, ModuleStorageLocation.local.rawValue)
        XCTAssertEqual(payload.localOutputFolders, ["", "Local"])
        XCTAssertEqual(payload.githubOutputFolders, ["", "Remote"])
        XCTAssertTrue(payload.publishToLocal)
        XCTAssertFalse(payload.publishToGitHub)
    }

    func testCombinedPayloadHidesSubscriptionWhenCombinedModuleIsDisabled() throws {
        let lastUpdatedAt = Date(timeIntervalSince1970: 100)
        let modules = [
            RelayModule(
                name: "Enabled",
                sourceURL: "https://example.com/enabled.conf",
                outputFileName: "Enabled",
                isEnabled: true,
                lastUpdatedAt: lastUpdatedAt
            ),
            RelayModule(
                name: "Disabled",
                sourceURL: "https://example.com/disabled.conf",
                outputFileName: "Disabled",
                isEnabled: false
            )
        ]
        let summary = ModuleCollectionSummary(modules: modules, isUpdateable: { $0.isEnabled })
        var settings = AppSettings()
        settings.combinedModuleFileName = "My Relay"
        let rawURL = try XCTUnwrap(URL(string: "https://example.com/modules/My-Relay.sgmodule"))
        let localURL = URL(fileURLWithPath: "/tmp/My-Relay.sgmodule")

        settings.combinedModuleEnabled = false
        let disabled = WebManagementStateBuilder.combinedPayload(
            summary: summary,
            settings: settings,
            rawURL: rawURL,
            localFileURL: localURL
        )

        XCTAssertFalse(disabled.isEnabled)
        XCTAssertEqual(disabled.sourceCount, 2)
        XCTAssertEqual(disabled.enabledCount, 0)
        XCTAssertEqual(disabled.lastUpdatedAt, lastUpdatedAt)
        XCTAssertNil(disabled.subscriptionURL)

        settings.combinedModuleEnabled = true
        let enabled = WebManagementStateBuilder.combinedPayload(
            summary: summary,
            settings: settings,
            rawURL: rawURL,
            localFileURL: localURL
        )

        XCTAssertTrue(enabled.isEnabled)
        XCTAssertEqual(enabled.fileName, "My-Relay.sgmodule")
        XCTAssertEqual(enabled.enabledCount, 1)
        XCTAssertEqual(enabled.subscriptionURL, rawURL.absoluteString)
    }

    func testActivityPayloadClampsProgressAndCarriesUpdateAdmission() {
        let moduleID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let module = RelayModule(
            name: "Remote",
            sourceURL: "https://example.com/remote.conf",
            outputFileName: "Remote",
            isEnabled: true
        )
        let summary = ModuleCollectionSummary(modules: [module], isUpdateable: { _ in true })
        let workActivity = WorkActivity(
            kind: .updatingModules,
            title: "更新测试",
            startedAt: Date(timeIntervalSince1970: 10),
            blocksUpdates: true,
            canCancel: true
        )
        let admission = UpdateAdmission(isAccepted: false, message: "正在执行任务。")

        XCTAssertNil(WebManagementStateBuilder.progress(completedCount: 1, totalCount: 0))
        XCTAssertEqual(WebManagementStateBuilder.progress(completedCount: -1, totalCount: 4), 0)
        XCTAssertEqual(WebManagementStateBuilder.progress(completedCount: 6, totalCount: 4), 1)

        let payload = WebManagementStateBuilder.activityPayload(
            isWorking: true,
            workActivity: workActivity,
            statusMessage: "正在更新",
            completedCount: 2,
            totalCount: 4,
            currentModuleID: moduleID,
            updateAdmission: admission,
            summary: summary,
            automaticPublishScheduledAt: nil,
            automaticPublishRunsAt: nil,
            latestGitHubPublish: nil,
            error: "网络超时",
            cancellationRequested: true
        )

        XCTAssertTrue(payload.isWorking)
        XCTAssertEqual(payload.kind, WorkActivityKind.updatingModules.rawValue)
        XCTAssertEqual(payload.title, "更新测试")
        XCTAssertEqual(payload.progress, 0.5)
        XCTAssertEqual(payload.currentModuleID, moduleID.uuidString.lowercased())
        XCTAssertTrue(payload.blocksUpdates)
        XCTAssertTrue(payload.canCancel)
        XCTAssertTrue(payload.cancellationRequested)
        XCTAssertFalse(payload.canStartUpdate)
        XCTAssertEqual(payload.updateBlockedReason, "正在执行任务。")
        XCTAssertEqual(payload.enabledModuleCount, 1)
        XCTAssertEqual(payload.error, "网络超时")
    }

    func testModulePayloadPreservesStorageSourceAndAdvancedFields() throws {
        var options = ScriptHubOptions()
        options.policy = "Proxy"
        options.includeKeywords = "api"
        options.excludeKeywords = "ads"
        options.mitmAdd = "example.com"
        options.mitmRemove = "old.example.com"
        options.noResolve = true
        options.enableJQ = false

        let id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let module = RelayModule(
            id: id,
            name: "Managed Local",
            sourceURL: "file:///Users/example/Surge/Managed%20Local.sgmodule",
            sourceFormat: .surge,
            outputFileName: "Managed Local.sgmodule",
            category: "Network",
            outputFolder: "Rules",
            storageLocation: .local,
            localStorageRelativePath: "Rules/Managed Local.sgmodule",
            publishesStandalone: false,
            isEnabled: true,
            scriptHubOptions: options,
            customIconURL: "https://example.com/icon.png",
            state: .failed,
            lastError: "原链接 404"
        )
        let publishedURL = try XCTUnwrap(URL(string: "https://example.com/modules/Rules/Managed%20Local.sgmodule"))

        let payload = WebManagementStateBuilder.modulePayload(
            module,
            publishedURL: publishedURL,
            iconURL: "/api/modules/\(id.uuidString.lowercased())/icon"
        )

        XCTAssertEqual(payload.id, id.uuidString.lowercased())
        XCTAssertEqual(payload.initialSourceTitle, "自写模块")
        XCTAssertNil(payload.initialSourceURL)
        XCTAssertEqual(payload.updateSourceURL, module.sourceURL)
        XCTAssertEqual(payload.storageLocation, ModuleStorageLocation.local.rawValue)
        XCTAssertEqual(payload.storageLocationTitle, "本地模块")
        XCTAssertEqual(payload.storageLocationDetail, "未开启独立发布；转换结果保存在本地缓存")
        XCTAssertEqual(payload.relationshipSummary, "本地模块 · 自写模块")
        XCTAssertEqual(payload.outputFileName, "Managed Local.sgmodule")
        XCTAssertEqual(payload.publishedRelativePath, "Rules/Managed Local.sgmodule")
        XCTAssertEqual(payload.localStorageRelativePath, "Rules/Managed Local.sgmodule")
        XCTAssertFalse(payload.publishesStandalone)
        XCTAssertEqual(payload.state, ModuleUpdateState.failed.rawValue)
        XCTAssertEqual(payload.stateTitle, "更新失败")
        XCTAssertEqual(payload.lastError, "原链接 404")
        XCTAssertEqual(payload.publishedURL, publishedURL.absoluteString)
        XCTAssertEqual(payload.iconURL, "/api/modules/\(id.uuidString.lowercased())/icon")
        XCTAssertEqual(payload.customIconURL, "https://example.com/icon.png")
        XCTAssertEqual(payload.policy, "Proxy")
        XCTAssertEqual(payload.includeKeywords, "api")
        XCTAssertEqual(payload.excludeKeywords, "ads")
        XCTAssertEqual(payload.mitmAdd, "example.com")
        XCTAssertEqual(payload.mitmRemove, "old.example.com")
        XCTAssertTrue(payload.noResolve)
        XCTAssertFalse(payload.enableJQ)
        XCTAssertTrue(payload.advancedSummary?.contains("策略：Proxy") == true)
    }
}
