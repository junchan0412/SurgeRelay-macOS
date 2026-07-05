import Foundation
import XCTest
@testable import SurgeRelay

final class PublishPlannerTests: XCTestCase {
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

    func testGitHubPublishPlannerBuildsStalePathPlanOnlyForSameRepository() {
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"
        settings.branch = "main"
        settings.directory = "surge/modules"
        let repositoryKey = PublishCoordinator.repositoryKey(settings)

        let sameRepositoryPlan = GitHubPublishPlanner.pathPlan(
            currentPaths: ["A.sgmodule", "Folder/C.sgmodule"],
            settings: settings,
            knownRepositoryKey: repositoryKey,
            knownPublishedPaths: ["A.sgmodule", "B.sgmodule", "Folder/C.sgmodule"]
        )

        XCTAssertEqual(sameRepositoryPlan.repositoryKey, "someone/relay/main/surge/modules")
        XCTAssertEqual(sameRepositoryPlan.currentPaths, ["A.sgmodule", "Folder/C.sgmodule"])
        XCTAssertEqual(sameRepositoryPlan.stalePaths, ["B.sgmodule"])

        let movedRepositoryPlan = GitHubPublishPlanner.pathPlan(
            currentPaths: ["A.sgmodule"],
            settings: settings,
            knownRepositoryKey: "someone/relay/dev/surge/modules",
            knownPublishedPaths: ["A.sgmodule", "Old.sgmodule"]
        )

        XCTAssertTrue(movedRepositoryPlan.stalePaths.isEmpty)
    }

    func testGitHubPublishPlannerPreparesFilesAndRejectsEmptyPublishSet() throws {
        let standalone = RelayModule(
            id: UUID(),
            name: "Standalone",
            sourceURL: "https://example.com/standalone.sgmodule",
            outputFileName: "Standalone",
            publishesStandalone: true
        )
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"
        settings.branch = "main"
        settings.directory = "surge/modules"
        let repositoryKey = PublishCoordinator.repositoryKey(settings)
        let plan = PublishPlan(standaloneModules: [standalone], combinedModuleIDs: [])
        let files = [
            PublishFile(name: "Standalone.sgmodule", data: Data("standalone".utf8)),
            PublishFile(name: "Assets/icon.png", data: Data("icon".utf8))
        ]

        let prepared = try GitHubPublishPlanner.preparedFiles(
            plan: plan,
            files: files,
            settings: settings,
            knownRepositoryKey: repositoryKey,
            knownPublishedPaths: ["Standalone.sgmodule", "Old.sgmodule"]
        )

        XCTAssertEqual(prepared.files.map(\.name), ["Standalone.sgmodule", "Assets/icon.png"])
        XCTAssertEqual(prepared.pathPlan.repositoryKey, "someone/relay/main/surge/modules")
        XCTAssertEqual(prepared.pathPlan.currentPaths, ["Standalone.sgmodule", "Assets/icon.png"])
        XCTAssertEqual(prepared.pathPlan.stalePaths, ["Old.sgmodule"])

        XCTAssertThrowsError(try GitHubPublishPlanner.validatePublishableSelection(
            PublishPlan(standaloneModules: [], combinedModuleIDs: [])
        )) { error in
            XCTAssertTrue(GitHubPublishPlanner.isNoFilesToPublish(error))
        }
        XCTAssertThrowsError(try GitHubPublishPlanner.preparedFiles(
            plan: plan,
            files: [],
            settings: settings,
            knownRepositoryKey: repositoryKey,
            knownPublishedPaths: []
        )) { error in
            XCTAssertTrue(GitHubPublishPlanner.isNoFilesToPublish(error))
        }
    }

    func testGitHubPublishPlannerBuildsRepositoryPrivacyUpdateDecision() {
        XCTAssertEqual(
            GitHubPublishPlanner.repositoryPrivacyUpdate(currentValue: nil, detectedValue: true),
            GitHubRepositoryPrivacyUpdate(repositoryIsPrivate: true, shouldPersist: true)
        )
        XCTAssertEqual(
            GitHubPublishPlanner.repositoryPrivacyUpdate(currentValue: false, detectedValue: true),
            GitHubRepositoryPrivacyUpdate(repositoryIsPrivate: true, shouldPersist: true)
        )
        XCTAssertEqual(
            GitHubPublishPlanner.repositoryPrivacyUpdate(currentValue: true, detectedValue: true),
            GitHubRepositoryPrivacyUpdate(repositoryIsPrivate: true, shouldPersist: false)
        )
        XCTAssertEqual(
            GitHubPublishPlanner.repositoryPrivacyUpdate(currentValue: false, detectedValue: false),
            GitHubRepositoryPrivacyUpdate(repositoryIsPrivate: false, shouldPersist: false)
        )
    }

    func testGitHubPublishPlannerBuildsPreviewAndTargetDescription() {
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"
        settings.branch = "main"
        settings.directory = "/surge/modules/"
        let pathPlan = GitHubPublishedPathPlan(
            repositoryKey: "someone/relay/main/surge/modules",
            currentPaths: ["A.sgmodule", "Folder/C.sgmodule"],
            stalePaths: ["Old.sgmodule"]
        )
        let report = PublishReport(
            publishedFiles: ["A.sgmodule"],
            deletedFiles: ["Old.sgmodule"]
        )

        let preview = GitHubPublishPlanner.preview(
            settings: settings,
            pathPlan: pathPlan,
            report: report
        )

        XCTAssertEqual(GitHubPublishPlanner.targetDescription(settings: settings), "someone/relay@main/surge/modules")
        XCTAssertEqual(preview.destination, .gitHub)
        XCTAssertEqual(preview.targetDescription, "someone/relay@main/surge/modules")
        XCTAssertEqual(preview.activeFiles, ["A.sgmodule", "Folder/C.sgmodule"])
        XCTAssertEqual(preview.changedFiles, ["A.sgmodule"])
        XCTAssertEqual(preview.deletedFiles, ["Old.sgmodule"])
        XCTAssertTrue(preview.requiresDeletionConfirmation)

        settings.directory = ""
        XCTAssertEqual(GitHubPublishPlanner.targetDescription(settings: settings), "someone/relay@main")
    }

    func testGitHubPublishPlannerOnlyPersistsPathPlanWhenDeletionIsAllowedOrUnneeded() {
        let cleanPlan = GitHubPublishedPathPlan(
            repositoryKey: "someone/relay/main/modules",
            currentPaths: ["A.sgmodule"],
            stalePaths: []
        )
        let deletionPlan = GitHubPublishedPathPlan(
            repositoryKey: "someone/relay/main/modules",
            currentPaths: ["A.sgmodule"],
            stalePaths: ["Old.sgmodule"]
        )

        XCTAssertTrue(GitHubPublishPlanner.shouldPersistPathPlan(cleanPlan, allowDeleting: false))
        XCTAssertTrue(GitHubPublishPlanner.shouldPersistPathPlan(cleanPlan, allowDeleting: true))
        XCTAssertFalse(GitHubPublishPlanner.shouldPersistPathPlan(deletionPlan, allowDeleting: false))
        XCTAssertTrue(GitHubPublishPlanner.shouldPersistPathPlan(deletionPlan, allowDeleting: true))
    }

    func testGitHubPublishPlannerMergesSelectedPublishPathsOnlyForSameRepository() {
        var settings = GitHubSettings()
        settings.owner = "someone"
        settings.repository = "relay"
        settings.branch = "main"
        settings.directory = "modules"
        let repositoryKey = PublishCoordinator.repositoryKey(settings)

        let sameRepositoryUpdate = GitHubPublishPlanner.selectedPublishPathUpdate(
            currentPaths: ["B.sgmodule", "C.sgmodule"],
            settings: settings,
            knownRepositoryKey: repositoryKey,
            knownPublishedPaths: ["A.sgmodule", "B.sgmodule"]
        )

        XCTAssertEqual(sameRepositoryUpdate.repositoryKey, repositoryKey)
        XCTAssertEqual(sameRepositoryUpdate.publishedPaths, ["A.sgmodule", "B.sgmodule", "C.sgmodule"])

        let movedRepositoryUpdate = GitHubPublishPlanner.selectedPublishPathUpdate(
            currentPaths: ["B.sgmodule", "C.sgmodule"],
            settings: settings,
            knownRepositoryKey: "someone/other/main/modules",
            knownPublishedPaths: ["A.sgmodule"]
        )

        XCTAssertEqual(movedRepositoryUpdate.publishedPaths, ["B.sgmodule", "C.sgmodule"])
    }

    func testGitHubPublishPlannerBuildsUserVisibleStatuses() {
        let changedReport = PublishReport(
            publishedFiles: ["A.sgmodule"],
            deletedFiles: ["Old.sgmodule"],
            retriedAfterConflict: true
        )
        let unchangedReport = PublishReport(publishedFiles: [])
        let preview = PublishPreview(
            destination: .gitHub,
            targetDescription: "someone/relay@main/modules",
            activeFiles: ["A.sgmodule"],
            changedFiles: ["A.sgmodule"],
            deletedFiles: ["Old.sgmodule"]
        )
        let unchangedPreview = PublishPreview(
            destination: .gitHub,
            targetDescription: "someone/relay@main/modules",
            activeFiles: ["A.sgmodule"],
            changedFiles: [],
            deletedFiles: []
        )

        XCTAssertEqual(GitHubPublishPlanner.noFilesStatus(for: .publishAll), "没有可发布的模块文件")
        XCTAssertEqual(GitHubPublishPlanner.noFilesStatus(for: .publishSelected), "所选模块没有可发布的独立输出")
        XCTAssertEqual(GitHubPublishPlanner.noFilesStatus(for: .preview), "没有可发布的模块文件，已跳过 GitHub 发布预览")
        XCTAssertEqual(GitHubPublishPlanner.unchangedStatus(for: .publishAll), "没有文件需要发布")
        XCTAssertEqual(GitHubPublishPlanner.unchangedStatus(for: .publishSelected), "所选模块没有文件需要发布")
        XCTAssertEqual(GitHubPublishPlanner.unchangedStatus(for: .preview), "GitHub 内容没有变化")
        XCTAssertEqual(GitHubPublishPlanner.deletionConfirmationStatus(deletedFileCount: 3), "发布前需要确认删除 3 个旧文件")
        XCTAssertEqual(
            GitHubPublishPlanner.automaticDeletionConfirmationStatus(deletedFileCount: 3),
            "GitHub 发布需要确认删除 3 个旧文件"
        )
        XCTAssertEqual(GitHubPublishPlanner.previewStatus(preview), "已生成 GitHub 发布预览（2 个文件变更）")
        XCTAssertEqual(GitHubPublishPlanner.previewStatus(unchangedPreview), "GitHub 内容没有变化")
        XCTAssertEqual(
            GitHubPublishPlanner.reportStatus(
                for: .publishAll,
                report: changedReport,
                scopeTitle: "独立模块"
            ),
            "远端分支已更新并重新同步；独立模块已发布到 GitHub（2 个文件变更）"
        )
        XCTAssertEqual(
            GitHubPublishPlanner.reportStatus(
                for: .publishSelected,
                report: changedReport,
                scopeTitle: "独立模块"
            ),
            "远端分支已更新并重新同步；已发布所选模块到 GitHub（2 个文件变更）"
        )
        XCTAssertEqual(
            GitHubPublishPlanner.reportStatus(
                for: .publishAll,
                report: unchangedReport,
                scopeTitle: "独立模块"
            ),
            "没有文件需要发布"
        )
        XCTAssertEqual(
            GitHubPublishPlanner.reportStatus(
                for: .publishSelected,
                report: unchangedReport,
                scopeTitle: "独立模块"
            ),
            "所选模块没有文件需要发布"
        )
        XCTAssertEqual(
            GitHubPublishPlanner.automaticReportStatus(changedReport),
            "远端分支已更新并重新同步；已合并发布到 GitHub（2 个文件变更）"
        )
        XCTAssertEqual(
            GitHubPublishPlanner.automaticReportStatus(unchangedReport),
            "GitHub 内容没有变化，无需上传"
        )
    }

    func testGitHubPublishPlannerBuildsMessagesHistoryAndNoFilesDecision() throws {
        let report = PublishReport(
            publishedFiles: ["A.sgmodule"],
            deletedFiles: ["Old.sgmodule"],
            commitSHA: "abcdef1234567890",
            retriedAfterConflict: true
        )

        XCTAssertEqual(
            GitHubPublishPlanner.successMessage(scopeTitle: "独立模块", report: report),
            "远端分支已更新并重新同步；独立模块已发布到 GitHub（2 个文件变更）"
        )
        XCTAssertEqual(
            GitHubPublishPlanner.automaticSuccessMessage(report: report),
            "远端分支已更新并重新同步；已合并发布到 GitHub（2 个文件变更）"
        )
        XCTAssertEqual(
            GitHubPublishPlanner.selectedSuccessMessage(report: report),
            "远端分支已更新并重新同步；已发布所选模块到 GitHub（2 个文件变更）"
        )

        let entry = try XCTUnwrap(GitHubPublishPlanner.historyEntry(for: report))
        XCTAssertEqual(entry.moduleName, "GitHub")
        XCTAssertEqual(entry.outcome, .published)
        XCTAssertEqual(entry.message, "原子提交 abcdef12：上传/更新 1 个，删除 1 个（已处理远端更新）")
        XCTAssertTrue(entry.contentChanged)
        XCTAssertEqual(entry.publishedFiles, ["A.sgmodule"])
        XCTAssertEqual(entry.deletedFiles, ["Old.sgmodule"])
        XCTAssertEqual(entry.commitSHA, "abcdef1234567890")

        XCTAssertNil(GitHubPublishPlanner.historyEntry(for: PublishReport(publishedFiles: [])))
        XCTAssertTrue(GitHubPublishPlanner.isNoFilesToPublish(RelayError.noFilesToPublish))
        XCTAssertFalse(GitHubPublishPlanner.isNoFilesToPublish(RelayError.githubTokenMissing))
    }

}
