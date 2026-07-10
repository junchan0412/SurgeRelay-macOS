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
        XCTAssertEqual(localFolders, ["", "Custom", "Local"])
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
