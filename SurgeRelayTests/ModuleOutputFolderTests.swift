import Foundation
import XCTest
@testable import SurgeRelay

final class ModuleOutputFolderTests: XCTestCase {
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

        let localFolders = ModuleOutputFolderCatalog.options(
            settings: settings,
            modules: [module],
            localFolders: ["Local"],
            githubFolders: ["GitHub"],
            storageLocation: .local
        )
        XCTAssertEqual(localFolders, ["", "Local"])
    }

    func testLocalFolderCatalogDoesNotReintroduceUnvalidatedStoredOrSelectedPaths() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = root.appending(path: "Surge Relay")
        try FileManager.default.createDirectory(at: configuration.appending(path: "Backups/settings.json"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "User.json"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appending(path: "modules.json"))
        var settings = AppSettings()
        settings.publishToLocal = true
        settings.customModuleOutputFolders = ["modules.json", "Surge Relay/Backups/settings.json", "Future/Nested"]
        let module = RelayModule(name: "Stored", sourceURL: "https://example.com/module.sgmodule",
                                 outputFileName: "Stored", outputFolder: "modules.json", storageLocation: .local)
        let folders = try LocalModuleFolderScanner.folders(
            in: root.path,
            excluding: [configuration],
            including: settings.customModuleOutputFolders + [module.outputFolder]
        )

        for selected in ["modules.json", "Surge Relay/Backups/settings.json", "Future/Nested"] {
            XCTAssertEqual(ModuleOutputFolderCatalog.options(
                settings: settings, modules: [module], localFolders: folders,
                githubFolders: ["Remote"], storageLocation: .local, preserving: selected
            ), ["", "Future/Nested", "User.json"])
        }
        XCTAssertTrue(ModuleOutputFolderCatalog.options(
            settings: settings, modules: [], localFolders: folders,
            githubFolders: ["Remote"], storageLocation: .gitHub, preserving: "GitHub Only"
        ).contains("GitHub Only"))
    }

    func testLocalFolderCreationRejectsFilesAndInternalDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = root.appending(path: "Surge Relay")
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appending(path: "modules.json"))
        var settings = AppSettings()
        settings.localModuleDirectory = root.path

        for path in ["modules.json", "modules.json/Nested", "Surge Relay/Backups"] {
            XCTAssertThrowsError(try ModuleOutputFolderCatalog.createPlan(
                named: path, storageLocation: .local, settings: settings,
                githubModuleOutputFolders: [], excludedLocalDirectories: [configuration]
            ))
        }
        let plan = try ModuleOutputFolderCatalog.createPlan(
            named: "User.json", storageLocation: .local, settings: settings,
            githubModuleOutputFolders: [], excludedLocalDirectories: [configuration]
        )
        XCTAssertEqual(plan.folder, "User.json")
    }

    func testLocalFolderRefreshValidatesNewGitHubSelectionWithLocalPublishingDisabled() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Existing"), withIntermediateDirectories: true)
        var settings = AppSettings()
        settings.publishToLocal = false
        settings.localModuleDirectory = root.path
        let now = Date(timeIntervalSince1970: 10_000)
        let cachedFolders = try LocalModuleFolderScanner.folders(in: root.path)
        let plan = try ModuleOutputFolderCatalog.createPlan(
            named: "New GitHub Folder", storageLocation: .gitHub, settings: settings, githubModuleOutputFolders: []
        )

        XCTAssertFalse(ModuleOutputFolderCatalog.shouldRefreshLocalFolders(
            rootPath: root.path, cachedRootPath: root.path, lastRefreshedAt: now,
            folders: cachedFolders, preserving: "Existing", now: now, force: false
        ))
        XCTAssertTrue(ModuleOutputFolderCatalog.shouldRefreshLocalFolders(
            rootPath: root.path, cachedRootPath: root.path, lastRefreshedAt: now,
            folders: cachedFolders, preserving: plan.folder, now: now, force: false
        ))
        let refreshedFolders = try LocalModuleFolderScanner.folders(in: root.path, including: [plan.folder])
        XCTAssertEqual(ModuleOutputFolderCatalog.options(
            settings: settings, modules: [], localFolders: refreshedFolders,
            githubFolders: plan.githubModuleOutputFolders, storageLocation: .local, preserving: plan.folder
        ), ["", "Existing", "New GitHub Folder"])
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
            storageLocation: .local,
            settings: settings,
            githubModuleOutputFolders: ["", "Remote"]
        )

        XCTAssertEqual(plan.folder, "Tools/Nested")
        XCTAssertEqual(plan.localDirectoryURL?.path, root.appending(path: "Tools/Nested", directoryHint: .isDirectory).path)
        XCTAssertEqual(plan.customModuleOutputFolders, ["Existing", "Tools/Nested"])
        XCTAssertEqual(plan.githubModuleOutputFolders, ["", "Remote"])
        XCTAssertEqual(plan.statusMessage, "已在本地模块根目录创建文件夹 Tools/Nested")
    }

    func testModuleOutputFolderCatalogCreatePlanHandlesGitHubOnlyAndInvalidInput() throws {
        var settings = AppSettings()
        settings.publishToLocal = false
        settings.publishToGitHub = true

        let githubPlan = try ModuleOutputFolderCatalog.createPlan(
            named: "GitHub Only",
            storageLocation: .gitHub,
            settings: settings,
            githubModuleOutputFolders: []
        )
        XCTAssertNil(githubPlan.localDirectoryURL)
        XCTAssertEqual(githubPlan.customModuleOutputFolders, ["GitHub Only"])
        XCTAssertEqual(githubPlan.githubModuleOutputFolders, ["", "GitHub Only"])
        XCTAssertEqual(githubPlan.statusMessage, "已记录 GitHub 文件夹 GitHub Only，发布时会自动创建路径")

        XCTAssertThrowsError(try ModuleOutputFolderCatalog.createPlan(
            named: " / ",
            storageLocation: .gitHub,
            settings: settings,
            githubModuleOutputFolders: []
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("请输入文件夹名称"))
        }

        settings.publishToLocal = true
        settings.localModuleDirectory = " "
        XCTAssertThrowsError(try ModuleOutputFolderCatalog.createPlan(
            named: "Local",
            storageLocation: .local,
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
}
