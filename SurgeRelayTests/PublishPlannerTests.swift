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

    func testLocalPublishedFilesPlannerTracksStaleFilesOnlyForSameRoot() {
        let files = [
            PublishFile(name: "A.sgmodule", data: Data("a".utf8)),
            PublishFile(name: "Folder/C.sgmodule", data: Data("c".utf8))
        ]

        let plan = LocalPublishedFilesPlanner.plan(
            files: files,
            targetDirectory: "/Users/example/Surge",
            previousRootDirectory: "/Users/example/Surge",
            previousPublishedPaths: ["A.sgmodule", "B.sgmodule", "Folder/C.sgmodule"]
        )

        XCTAssertEqual(plan.targetDirectory, "/Users/example/Surge")
        XCTAssertEqual(plan.currentPaths, ["A.sgmodule", "Folder/C.sgmodule"])
        XCTAssertEqual(plan.knownManagedPaths, ["A.sgmodule", "B.sgmodule", "Folder/C.sgmodule"])
        XCTAssertEqual(plan.stalePaths, ["B.sgmodule"])
        XCTAssertTrue(plan.requiresCleanupConfirmation)
        XCTAssertEqual(plan.cleanupStatusMessage, "已写入本地模块，等待确认清理 1 个旧文件")

        let preview = plan.cleanupPreview()
        XCTAssertEqual(preview.destination, .local)
        XCTAssertEqual(preview.targetDescription, "/Users/example/Surge")
        XCTAssertEqual(preview.activeFiles, ["A.sgmodule", "Folder/C.sgmodule"])
        XCTAssertTrue(preview.changedFiles.isEmpty)
        XCTAssertEqual(preview.deletedFiles, ["B.sgmodule"])
    }

    func testLocalPublishedFilesPlannerDoesNotCarryManagedPathsAcrossRootChange() {
        let plan = LocalPublishedFilesPlanner.plan(
            files: [PublishFile(name: "A.sgmodule", data: Data("a".utf8))],
            targetDirectory: "/Users/example/NewRoot",
            previousRootDirectory: "/Users/example/OldRoot",
            previousPublishedPaths: ["A.sgmodule", "Old.sgmodule"]
        )

        XCTAssertEqual(plan.currentPaths, ["A.sgmodule"])
        XCTAssertTrue(plan.knownManagedPaths.isEmpty)
        XCTAssertTrue(plan.stalePaths.isEmpty)
        XCTAssertFalse(plan.requiresCleanupConfirmation)
    }

    func testLocalPublishedFilesPlannerLimitsConfirmedCleanupToPreviewRoot() {
        let preview = PublishPreview(
            destination: .local,
            targetDescription: "/Users/example/Surge",
            activeFiles: ["A.sgmodule"],
            changedFiles: [],
            deletedFiles: ["Old.sgmodule"]
        )

        XCTAssertEqual(
            LocalPublishedFilesPlanner.knownManagedPathsForConfirmedCleanup(
                preview: preview,
                previousRootDirectory: "/Users/example/Surge",
                previousPublishedPaths: ["A.sgmodule", "Old.sgmodule"]
            ),
            ["A.sgmodule", "Old.sgmodule"]
        )
        XCTAssertTrue(
            LocalPublishedFilesPlanner.knownManagedPathsForConfirmedCleanup(
                preview: preview,
                previousRootDirectory: "/Users/example/Other",
                previousPublishedPaths: ["A.sgmodule", "Old.sgmodule"]
            ).isEmpty
        )
    }

    func testAutomaticPublishPlannerBuildsSkipMessages() {
        XCTAssertEqual(
            AutomaticPublishPlanner.noStandaloneModulesStatus,
            "没有开启独立发布的模块，已跳过 GitHub 自动发布"
        )
        XCTAssertEqual(
            AutomaticPublishPlanner.noStandaloneFilesStatus,
            "没有可自动发布的独立模块文件，已跳过 GitHub 自动发布"
        )
        XCTAssertEqual(
            AutomaticPublishPlanner.skippedAfterModuleUpdateStatus(contentChanged: true, failures: 2),
            "模块输出已更新；2 个来源沿用上次成功版本；没有开启独立发布的模块，已跳过 GitHub 自动发布"
        )
        XCTAssertEqual(
            AutomaticPublishPlanner.skippedAfterModuleUpdateStatus(contentChanged: false, failures: 0),
            "模块内容未变化；没有开启独立发布的模块，无需 GitHub 自动发布"
        )
    }

    func testAutomaticPublishPlannerOnlyQueuesStandaloneModulePublishing() {
        let standalone = RelayModule(
            id: UUID(),
            name: "Standalone",
            sourceURL: "https://example.com/standalone.sgmodule",
            outputFileName: "Standalone",
            publishesStandalone: true
        )
        let combinedID = UUID()
        let standalonePlan = PublishPlan(
            standaloneModules: [standalone],
            combinedModuleIDs: [combinedID]
        )
        let combinedOnlyPlan = PublishPlan(
            standaloneModules: [],
            combinedModuleIDs: [combinedID]
        )

        XCTAssertTrue(AutomaticPublishPlanner.shouldRunScheduledPublish(plan: standalonePlan))
        XCTAssertTrue(AutomaticPublishPlanner.shouldQueueAfterModuleUpdate(
            plan: standalonePlan,
            contentChanged: true
        ))
        XCTAssertFalse(AutomaticPublishPlanner.shouldQueueAfterModuleUpdate(
            plan: standalonePlan,
            contentChanged: false
        ))
        XCTAssertFalse(AutomaticPublishPlanner.shouldRunScheduledPublish(plan: combinedOnlyPlan))
        XCTAssertFalse(AutomaticPublishPlanner.shouldQueueAfterModuleUpdate(
            plan: combinedOnlyPlan,
            contentChanged: true
        ))
    }

    func testAutomaticPublishPlannerBuildsContextFromSettings() {
        var settings = AppSettings()

        XCTAssertEqual(
            AutomaticPublishPlanner.context(settings: settings, tokenIsAvailable: true),
            AutomaticPublishContext(
                publishToGitHub: true,
                automaticallyPublish: true,
                gitHubConfigured: true,
                tokenAvailable: true
            )
        )
        XCTAssertTrue(
            AutomaticPublishPlanner.canUseAutomaticPublishing(
                context: AutomaticPublishPlanner.context(settings: settings, tokenIsAvailable: true)
            )
        )

        settings.publishToGitHub = false
        XCTAssertFalse(
            AutomaticPublishPlanner.canUseAutomaticPublishing(
                context: AutomaticPublishPlanner.context(settings: settings, tokenIsAvailable: true)
            )
        )

        settings.publishToGitHub = true
        settings.automaticallyPublish = false
        XCTAssertFalse(
            AutomaticPublishPlanner.canUseAutomaticPublishing(
                context: AutomaticPublishPlanner.context(settings: settings, tokenIsAvailable: true)
            )
        )

        settings.automaticallyPublish = true
        settings.github.owner = ""
        XCTAssertFalse(
            AutomaticPublishPlanner.canUseAutomaticPublishing(
                context: AutomaticPublishPlanner.context(settings: settings, tokenIsAvailable: true)
            )
        )

        settings.github.owner = "owner"
        XCTAssertFalse(
            AutomaticPublishPlanner.canUseAutomaticPublishing(
                context: AutomaticPublishPlanner.context(settings: settings, tokenIsAvailable: false)
            )
        )
    }

    func testAutomaticPublishPlannerBuildsAdmissionDecisions() {
        let standalone = RelayModule(
            id: UUID(),
            name: "Standalone",
            sourceURL: "https://example.com/standalone.sgmodule",
            outputFileName: "Standalone",
            publishesStandalone: true
        )
        let standalonePlan = PublishPlan(
            standaloneModules: [standalone],
            combinedModuleIDs: [UUID()]
        )
        let combinedOnlyPlan = PublishPlan(
            standaloneModules: [],
            combinedModuleIDs: [UUID()]
        )
        let readyContext = AutomaticPublishContext(
            publishToGitHub: true,
            automaticallyPublish: true,
            gitHubConfigured: true,
            tokenAvailable: true
        )
        let missingTokenContext = AutomaticPublishContext(
            publishToGitHub: true,
            automaticallyPublish: true,
            gitHubConfigured: true,
            tokenAvailable: false
        )

        XCTAssertEqual(
            AutomaticPublishPlanner.scheduleAdmission(
                context: readyContext,
                plan: standalonePlan
            ),
            .accepted
        )
        XCTAssertEqual(
            AutomaticPublishPlanner.scheduleAdmission(
                context: missingTokenContext,
                plan: standalonePlan
            ),
            .rejected()
        )
        XCTAssertEqual(
            AutomaticPublishPlanner.scheduleAdmission(
                context: readyContext,
                plan: combinedOnlyPlan
            ),
            .rejected()
        )
        XCTAssertEqual(
            AutomaticPublishPlanner.runAdmission(
                context: readyContext,
                plan: standalonePlan,
                hasCachedStandaloneOutput: true
            ),
            .accepted
        )
        XCTAssertEqual(
            AutomaticPublishPlanner.runAdmission(
                context: readyContext,
                plan: combinedOnlyPlan,
                hasCachedStandaloneOutput: true
            ),
            .rejected(statusMessage: AutomaticPublishPlanner.noStandaloneModulesStatus)
        )
        XCTAssertEqual(
            AutomaticPublishPlanner.runAdmission(
                context: readyContext,
                plan: standalonePlan,
                hasCachedStandaloneOutput: false
            ),
            .rejected(statusMessage: AutomaticPublishPlanner.noStandaloneFilesStatus)
        )
    }

    func testAutomaticPublishPlannerChecksStandaloneCachedOutput() async {
        let standaloneID = UUID()
        let standalone = RelayModule(
            id: standaloneID,
            name: "Standalone",
            sourceURL: "https://example.com/standalone.sgmodule",
            outputFileName: "Standalone",
            publishesStandalone: true
        )
        let combinedOnlyID = UUID()
        let plan = PublishPlan(
            standaloneModules: [standalone],
            combinedModuleIDs: [combinedOnlyID]
        )

        let hasStandaloneOutput = await AutomaticPublishPlanner.hasCachedStandaloneOutput(
            plan: plan
        ) { id in
            id == standaloneID
        }
        XCTAssertTrue(hasStandaloneOutput)

        let onlyCombinedPlan = PublishPlan(
            standaloneModules: [],
            combinedModuleIDs: [combinedOnlyID]
        )
        let combinedOutputDoesNotCount = await AutomaticPublishPlanner.hasCachedStandaloneOutput(
            plan: onlyCombinedPlan
        ) { _ in
            true
        }
        XCTAssertFalse(combinedOutputDoesNotCount)

        let missingStandaloneOutput = await AutomaticPublishPlanner.hasCachedStandaloneOutput(
            plan: plan
        ) { _ in
            false
        }
        XCTAssertFalse(missingStandaloneOutput)
    }

    func testUpdateCompletionStatusPlannerBuildsUserVisibleMessages() {
        XCTAssertEqual(
            UpdateCompletionStatusPlanner.automaticPublishQueuedStatus(contentChanged: true, failures: 0),
            "模块输出已更新，等待发布"
        )
        XCTAssertEqual(
            UpdateCompletionStatusPlanner.automaticPublishQueuedStatus(contentChanged: true, failures: 2),
            "模块输出已更新；2 个来源沿用上次版本，等待发布"
        )
        XCTAssertEqual(
            UpdateCompletionStatusPlanner.automaticPublishQueuedStatus(contentChanged: false, failures: 0),
            "所有模块内容均未变化，无需发布"
        )
        XCTAssertEqual(
            UpdateCompletionStatusPlanner.automaticPublishQueuedStatus(contentChanged: false, failures: 1),
            "模块内容未变化；1 个来源沿用上次版本，无需发布"
        )
        XCTAssertEqual(
            UpdateCompletionStatusPlanner.localCleanupPendingStatus(failures: 0, staleFileCount: 3),
            "模块输出已更新，等待确认清理 3 个本地旧文件"
        )
        XCTAssertEqual(
            UpdateCompletionStatusPlanner.localCleanupPendingStatus(failures: 2, staleFileCount: 3),
            "模块输出已更新；2 个来源沿用上次版本，等待确认清理 3 个本地旧文件"
        )
        XCTAssertEqual(
            UpdateCompletionStatusPlanner.refreshedOutputStatus(
                combinedModuleEnabled: true,
                combinedSourceCount: 4,
                failures: 0
            ),
            "总模块已由 4 个来源合并完成"
        )
        XCTAssertEqual(
            UpdateCompletionStatusPlanner.refreshedOutputStatus(
                combinedModuleEnabled: true,
                combinedSourceCount: 4,
                failures: 1
            ),
            "总模块已更新；1 个来源沿用上次成功版本"
        )
        XCTAssertEqual(
            UpdateCompletionStatusPlanner.refreshedOutputStatus(
                combinedModuleEnabled: false,
                combinedSourceCount: 0,
                failures: 0
            ),
            "模块输出已刷新"
        )
        XCTAssertEqual(
            UpdateCompletionStatusPlanner.refreshedOutputStatus(
                combinedModuleEnabled: false,
                combinedSourceCount: 0,
                failures: 1
            ),
            "模块输出已刷新；1 个来源沿用上次成功版本"
        )
    }

    func testUpdateCompletionStatusPlannerBuildsSchedulingDecision() {
        let standalone = RelayModule(
            id: UUID(),
            name: "Standalone",
            sourceURL: "https://example.com/standalone.sgmodule",
            outputFileName: "Standalone",
            publishesStandalone: true
        )
        let standalonePlan = PublishPlan(
            standaloneModules: [standalone],
            combinedModuleIDs: []
        )
        let combinedOnlyPlan = PublishPlan(
            standaloneModules: [],
            combinedModuleIDs: [UUID()]
        )

        XCTAssertEqual(
            UpdateCompletionStatusPlanner.decision(
                canUseAutomaticGitHubPublish: true,
                publishPlan: standalonePlan,
                contentChanged: true,
                failures: 1,
                pendingLocalCleanupFileCount: nil,
                combinedModuleEnabled: true,
                combinedSourceCount: 2
            ),
            UpdateCompletionDecision(
                scheduleAction: .scheduleAutomaticPublish,
                statusMessage: "模块输出已更新；1 个来源沿用上次版本，等待发布"
            )
        )

        XCTAssertEqual(
            UpdateCompletionStatusPlanner.decision(
                canUseAutomaticGitHubPublish: true,
                publishPlan: standalonePlan,
                contentChanged: false,
                failures: 0,
                pendingLocalCleanupFileCount: nil,
                combinedModuleEnabled: true,
                combinedSourceCount: 2
            ),
            UpdateCompletionDecision(
                scheduleAction: .none,
                statusMessage: "所有模块内容均未变化，无需发布"
            )
        )

        XCTAssertEqual(
            UpdateCompletionStatusPlanner.decision(
                canUseAutomaticGitHubPublish: true,
                publishPlan: combinedOnlyPlan,
                contentChanged: true,
                failures: 2,
                pendingLocalCleanupFileCount: nil,
                combinedModuleEnabled: true,
                combinedSourceCount: 2
            ),
            UpdateCompletionDecision(
                scheduleAction: .clearAutomaticPublishSchedule,
                statusMessage: "模块输出已更新；2 个来源沿用上次成功版本；没有开启独立发布的模块，已跳过 GitHub 自动发布"
            )
        )
    }

    func testUpdateCompletionStatusPlannerFallsBackToLocalCleanupAndRefreshDecision() {
        let plan = PublishPlan(standaloneModules: [], combinedModuleIDs: [])

        XCTAssertEqual(
            UpdateCompletionStatusPlanner.decision(
                canUseAutomaticGitHubPublish: false,
                publishPlan: plan,
                contentChanged: true,
                failures: 1,
                pendingLocalCleanupFileCount: 4,
                combinedModuleEnabled: true,
                combinedSourceCount: 3
            ),
            UpdateCompletionDecision(
                scheduleAction: .none,
                statusMessage: "模块输出已更新；1 个来源沿用上次版本，等待确认清理 4 个本地旧文件"
            )
        )

        XCTAssertEqual(
            UpdateCompletionStatusPlanner.decision(
                canUseAutomaticGitHubPublish: false,
                publishPlan: plan,
                contentChanged: false,
                failures: 0,
                pendingLocalCleanupFileCount: nil,
                combinedModuleEnabled: true,
                combinedSourceCount: 3
            ),
            UpdateCompletionDecision(
                scheduleAction: .none,
                statusMessage: "总模块已由 3 个来源合并完成"
            )
        )
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
