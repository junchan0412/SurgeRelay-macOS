import Foundation
import XCTest
@testable import SurgeRelay

final class ModulePlanningTests: XCTestCase {
    func testFilenameSanitizerCreatesSurgeModuleExtension() {
        XCTAssertEqual(FilenameSanitizer.sgmoduleName(from: "YouTube Ads.sgmodule"), "YouTube-Ads.sgmodule")
        XCTAssertEqual(FilenameSanitizer.existingSgmoduleName(from: "YouTube Ads.sgmodule"), "YouTube Ads.sgmodule")
        XCTAssertEqual(FilenameSanitizer.sgmoduleName(from: "folder/bad:name"), "folder-bad-name.sgmodule")
        XCTAssertEqual(FilenameSanitizer.existingSgmoduleName(from: "folder/bad:name"), "bad-name.sgmodule")
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

    func testModuleOutputFolderCatalogCombinesAvailableFolderSources() {
        var settings = AppSettings()
        settings.publishToLocal = true
        settings.publishToGitHub = true
        settings.customModuleOutputFolders = ["Custom"]
        let module = RelayModule(
            name: "Used",
            sourceURL: "https://example.com/used.sgmodule",
            outputFileName: "Used",
            outputFolder: "Used"
        )

        let folders = ModuleOutputFolderCatalog.options(
            settings: settings,
            modules: [module],
            localFolders: ["Local"],
            githubFolders: ["GitHub"],
            preserving: "Selected"
        )

        XCTAssertEqual(folders, ["", "Custom", "GitHub", "Local", "Selected", "Used"])
    }

    func testModuleOutputFolderCatalogCreatePlanBuildsLocalDirectoryAndRecordedFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        var settings = AppSettings()
        settings.publishToLocal = true
        settings.publishToGitHub = true
        settings.localModuleDirectory = root.path
        settings.customModuleOutputFolders = ["Existing"]

        let plan = try ModuleOutputFolderCatalog.createPlan(
            named: " /Tools/Nested/ ",
            settings: settings,
            githubModuleOutputFolders: ["", "Remote"]
        )

        XCTAssertEqual(plan.folder, "Tools/Nested")
        XCTAssertEqual(plan.localDirectoryURL?.path, root.appending(path: "Tools/Nested", directoryHint: .isDirectory).path)
        XCTAssertEqual(plan.customModuleOutputFolders, ["Existing", "Tools/Nested"])
        XCTAssertEqual(plan.githubModuleOutputFolders, ["", "Remote", "Tools/Nested"])
        XCTAssertEqual(plan.statusMessage, "已创建/记录文件夹 Tools/Nested")
    }

    func testModuleOutputFolderCatalogCreatePlanHandlesGitHubOnlyAndInvalidInput() throws {
        var settings = AppSettings()
        settings.publishToLocal = false
        settings.publishToGitHub = true

        let githubPlan = try ModuleOutputFolderCatalog.createPlan(
            named: "GitHub Only",
            settings: settings,
            githubModuleOutputFolders: []
        )
        XCTAssertNil(githubPlan.localDirectoryURL)
        XCTAssertEqual(githubPlan.customModuleOutputFolders, ["GitHub Only"])
        XCTAssertEqual(githubPlan.githubModuleOutputFolders, ["", "GitHub Only"])
        XCTAssertEqual(githubPlan.statusMessage, "已添加 GitHub 文件夹 GitHub Only，发布模块时会自动创建路径")

        XCTAssertThrowsError(try ModuleOutputFolderCatalog.createPlan(
            named: " / ",
            settings: settings,
            githubModuleOutputFolders: []
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("请输入文件夹名称"))
        }

        settings.publishToLocal = true
        settings.localModuleDirectory = " "
        XCTAssertThrowsError(try ModuleOutputFolderCatalog.createPlan(
            named: "Local",
            settings: settings,
            githubModuleOutputFolders: []
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("请先设置本地模块根目录"))
        }
    }

    func testModuleOutputFolderCatalogPlansGitHubRefreshCache() {
        let now = Date(timeIntervalSince1970: 10_000)
        var settings = AppSettings()
        settings.publishToGitHub = false

        XCTAssertEqual(
            ModuleOutputFolderCatalog.refreshDecision(
                settings: settings,
                cachedConfiguration: nil,
                lastRefreshedAt: nil,
                now: now,
                force: false
            ),
            .reset(ModuleOutputFolderRefreshState(
                githubModuleOutputFolders: [""],
                lastRefreshedAt: nil,
                configuration: nil
            ))
        )

        settings.publishToGitHub = true
        let recent = now.addingTimeInterval(-60)
        XCTAssertEqual(
            ModuleOutputFolderCatalog.refreshDecision(
                settings: settings,
                cachedConfiguration: settings.github,
                lastRefreshedAt: recent,
                now: now,
                force: false
            ),
            .reuseCached
        )
        XCTAssertEqual(
            ModuleOutputFolderCatalog.refreshDecision(
                settings: settings,
                cachedConfiguration: settings.github,
                lastRefreshedAt: recent,
                now: now,
                force: true
            ),
            .fetchRemote
        )
        XCTAssertEqual(
            ModuleOutputFolderCatalog.refreshDecision(
                settings: settings,
                cachedConfiguration: settings.github,
                lastRefreshedAt: now.addingTimeInterval(-301),
                now: now,
                force: false
            ),
            .fetchRemote
        )
    }

    func testModuleOutputFolderCatalogBuildsRefreshStates() {
        var settings = AppSettings().github
        settings.directory = "surge/modules"
        let refreshedAt = Date(timeIntervalSince1970: 12_000)
        let module = RelayModule(
            name: "Local",
            sourceURL: "https://example.com/local.sgmodule",
            outputFileName: "Local",
            outputFolder: "Used"
        )

        XCTAssertEqual(
            ModuleOutputFolderCatalog.successfulRefreshState(
                remoteFolders: ["Remote", "Used"],
                modules: [module],
                settings: settings,
                refreshedAt: refreshedAt
            ),
            ModuleOutputFolderRefreshState(
                githubModuleOutputFolders: ["", "Remote", "Used"],
                lastRefreshedAt: refreshedAt,
                configuration: settings
            )
        )
        XCTAssertEqual(
            ModuleOutputFolderCatalog.failedRefreshState(
                modules: [module],
                settings: settings,
                refreshedAt: refreshedAt
            ),
            ModuleOutputFolderRefreshState(
                githubModuleOutputFolders: ["", "Used"],
                lastRefreshedAt: refreshedAt,
                configuration: settings
            )
        )
    }

    func testModuleNamingPlannerBuildsLocalStorageRelativePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let source = root.appending(path: "Ads/My Module.sgmodule").absoluteString

        XCTAssertEqual(
            try ModuleNamingPlanner.localStorageRelativePath(
                storageLocation: .local,
                source: source,
                outputFileName: "Different.sgmodule",
                outputFolder: "Converted",
                localModuleDirectory: root.path
            ),
            "Ads/My Module.sgmodule"
        )
        XCTAssertNil(try ModuleNamingPlanner.localStorageRelativePath(
            storageLocation: .gitHub,
            source: source,
            outputFileName: "Different.sgmodule",
            outputFolder: "Converted",
            localModuleDirectory: ""
        ))
        XCTAssertThrowsError(try ModuleNamingPlanner.localStorageRelativePath(
            storageLocation: .local,
            source: "https://example.com/source.conf",
            outputFileName: "Different.sgmodule",
            outputFolder: "Converted",
            localModuleDirectory: "   "
        ))
    }

    func testModuleNamingPlannerAvoidsCombinedAndExistingOutputPaths() {
        let existing = RelayModule(
            name: "Existing",
            sourceURL: "https://example.com/existing.sgmodule",
            outputFileName: "Existing",
            outputFolder: "Folder"
        )
        var draft = ModuleDraft()
        draft.name = "Existing"
        draft.sourceURL = "https://example.com/new.sgmodule"
        draft.outputFolder = "Folder"

        XCTAssertEqual(
            ModuleNamingPlanner.uniqueOutputFileName(
                for: draft,
                source: draft.sourceURL,
                modules: [existing],
                combinedModuleFileName: "Surge Relay"
            ),
            "Existing-2.sgmodule"
        )

        draft.name = "Surge Relay"
        draft.outputFolder = ""
        XCTAssertEqual(
            ModuleNamingPlanner.uniqueOutputFileName(
                for: draft,
                source: draft.sourceURL,
                modules: [],
                combinedModuleFileName: "Surge Relay"
            ),
            "Surge-Relay-2.sgmodule"
        )

        XCTAssertEqual(
            ModuleNamingPlanner.uniqueOutputFileName(
                preferredFileName: "My Module.sgmodule",
                folder: "Folder",
                unavailable: ["folder/my module.sgmodule"],
                preservesExistingFileName: true
            ),
            "My Module-2.sgmodule"
        )
    }

    func testModuleNamingPlannerNormalizesLoadedModulesWithoutLosingLocalPaths() {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let localSource = root.appending(path: "Ads/My Module.sgmodule").absoluteString
        let local = RelayModule(
            name: "Imported Local",
            sourceURL: localSource,
            outputFileName: "Old Generated Name",
            outputFolder: " /Ads/ ",
            storageLocation: .local,
            localStorageRelativePath: nil,
            preservesOutputFileName: false
        )
        let combinedCollision = RelayModule(
            name: "Combined",
            sourceURL: "https://example.com/combined.sgmodule",
            outputFileName: "Surge Relay",
            storageLocation: .gitHub
        )

        let normalized = ModuleNamingPlanner.normalizedModuleNaming(
            [local, combinedCollision],
            combinedFileName: "Surge Relay",
            localModuleDirectory: root.path
        )

        XCTAssertEqual(normalized[0].outputFolder, "Ads")
        XCTAssertEqual(normalized[0].outputFileName, "My Module.sgmodule")
        XCTAssertEqual(normalized[0].localStorageRelativePath, "Ads/My Module.sgmodule")
        XCTAssertTrue(normalized[0].preservesOutputFileName)
        XCTAssertEqual(normalized[1].outputFileName, "Surge-Relay-2.sgmodule")
    }

    func testModuleDraftPlannerBuildsLocalAddPlanWithoutLosingOriginalPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let source = root.appending(path: "Ads/My Module.sgmodule").absoluteString
        var draft = ModuleDraft()
        draft.name = "  My Local Module  "
        draft.sourceURL = source
        draft.sourceFormat = .automatic
        draft.outputFileName = "Converted Copy.sgmodule"
        draft.outputFolder = " Converted "
        draft.category = " #工具 "
        draft.storageLocation = .local
        draft.publishesStandalone = true
        draft.iconURL = " https://example.com/icon.png "

        let plan = try ModuleDraftPlanner.addPlan(
            from: draft,
            modules: [],
            combinedModuleFileName: "Surge Relay",
            localModuleDirectory: root.path
        )

        XCTAssertEqual(plan.module.name, "My Local Module")
        XCTAssertEqual(plan.module.sourceURL, source)
        XCTAssertEqual(plan.module.category, "#工具")
        XCTAssertEqual(plan.module.outputFolder, "Converted")
        XCTAssertEqual(plan.module.outputFileName, "Converted Copy.sgmodule")
        XCTAssertEqual(plan.module.localStorageRelativePath, "Ads/My Module.sgmodule")
        XCTAssertTrue(plan.module.preservesOutputFileName)
        XCTAssertEqual(plan.module.storageLocation, .local)
        XCTAssertEqual(plan.module.detectedSourceFormat, .surge)
        XCTAssertEqual(plan.customIconURL, "https://example.com/icon.png")
        XCTAssertEqual(plan.module.iconURL, "https://example.com/icon.png")
    }

    func testModuleDraftPlannerRejectsDuplicateEffectiveSource() throws {
        let existing = RelayModule(
            name: "Existing",
            sourceURL: "HTTPS://Example.com:443/modules/demo.sgmodule#fragment",
            outputFileName: "Existing"
        )
        var draft = ModuleDraft()
        draft.name = "Duplicate"
        draft.sourceURL = "https://example.com/modules/demo.sgmodule"

        XCTAssertThrowsError(try ModuleDraftPlanner.addPlan(
            from: draft,
            modules: [existing],
            combinedModuleFileName: "Surge Relay",
            localModuleDirectory: ""
        )) { error in
            XCTAssertEqual(error.localizedDescription, RelayError.duplicateSourceURL.localizedDescription)
        }
    }

    func testModuleDraftPlannerReturnsNoChangeUpdatePlan() throws {
        let module = RelayModule(
            name: "Stable",
            sourceURL: "https://example.com/stable.sgmodule",
            sourceFormat: .surge,
            outputFileName: "Stable",
            category: "#工具",
            outputFolder: "Tools",
            publishesStandalone: true,
            isEnabled: false,
            customIconURL: "https://example.com/icon.png"
        )
        let plan = try XCTUnwrap(ModuleDraftPlanner.updatePlan(
            id: module.id,
            from: ModuleDraft(module: module),
            modules: [module],
            combinedModuleFileName: "Surge Relay",
            localModuleDirectory: ""
        ))

        XCTAssertFalse(plan.hasChanges)
        XCTAssertFalse(plan.sourceChanged)
        XCTAssertFalse(plan.customIconChanged)
        XCTAssertEqual(plan.module, module)
    }

    func testModuleDraftPlannerClearsSourceStateWhenSourceChanges() throws {
        let module = RelayModule(
            name: "Wrapped",
            sourceURL: "https://example.com/old.conf",
            sourceFormat: .quantumultX,
            outputFileName: "Wrapped",
            iconURL: "https://example.com/detected.png",
            customIconURL: "https://example.com/custom.png",
            scriptHubSubscription: ScriptHubSubscriptionInfo(
                subscriptionURL: "http://script.hub/file/_start_/https://example.com/old.conf/_end_/Wrapped.sgmodule",
                originalURL: "https://example.com/old.conf",
                outputName: "Wrapped.sgmodule",
                sourceType: "qx-rewrite",
                target: "surge-module",
                category: nil,
                options: ScriptHubOptions()
            ),
            lastUpdatedAt: Date(timeIntervalSince1970: 1_000),
            contentHash: "converted-hash",
            sourceETag: "etag",
            sourceLastModified: "date",
            sourceContentHash: "source-hash",
            sourceCheckedAt: Date(timeIntervalSince1970: 1_100),
            conversionEngineRevision: "revision",
            state: .current,
            lastError: "old error"
        )
        var draft = ModuleDraft(module: module)
        draft.sourceURL = "https://example.com/new.conf"
        draft.iconURL = ""

        let plan = try XCTUnwrap(ModuleDraftPlanner.updatePlan(
            id: module.id,
            from: draft,
            modules: [module],
            combinedModuleFileName: "Surge Relay",
            localModuleDirectory: ""
        ))

        XCTAssertTrue(plan.hasChanges)
        XCTAssertTrue(plan.sourceChanged)
        XCTAssertTrue(plan.customIconChanged)
        XCTAssertEqual(plan.module.sourceURL, "https://example.com/new.conf")
        XCTAssertNil(plan.module.iconURL)
        XCTAssertNil(plan.module.customIconURL)
        XCTAssertEqual(plan.module.state, .never)
        XCTAssertNil(plan.module.lastError)
        XCTAssertNil(plan.module.sourceETag)
        XCTAssertNil(plan.module.sourceLastModified)
        XCTAssertNil(plan.module.sourceContentHash)
        XCTAssertNil(plan.module.sourceCheckedAt)
        XCTAssertNil(plan.module.conversionEngineRevision)
        XCTAssertNil(plan.module.scriptHubSubscription)
        XCTAssertEqual(plan.module.lastUpdatedAt, module.lastUpdatedAt)
        XCTAssertEqual(plan.module.contentHash, module.contentHash)
    }
}
