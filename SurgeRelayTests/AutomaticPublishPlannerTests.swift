import Foundation
import XCTest
@testable import SurgeRelay

final class AutomaticPublishPlannerTests: XCTestCase {
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

    func testAutomaticPublishPlannerChecksAnyStandaloneCachedOutput() async {
        let standaloneID = UUID()
        let standalone = RelayModule(
            id: standaloneID,
            name: "Standalone",
            sourceURL: "https://example.com/standalone.sgmodule",
            outputFileName: "Standalone",
            publishesStandalone: true
        )
        let secondStandaloneID = UUID()
        let secondStandalone = RelayModule(
            id: secondStandaloneID,
            name: "Second Standalone",
            sourceURL: "https://example.com/second.sgmodule",
            outputFileName: "Second",
            publishesStandalone: true
        )
        let combinedOnlyID = UUID()
        let plan = PublishPlan(
            standaloneModules: [standalone],
            combinedModuleIDs: [combinedOnlyID]
        )

        let hasStandaloneOutput = await AutomaticPublishPlanner.hasAnyCachedStandaloneOutput(
            plan: plan
        ) { id in
            id == standaloneID
        }
        XCTAssertTrue(hasStandaloneOutput)

        let mixedCachePlan = PublishPlan(
            standaloneModules: [standalone, secondStandalone],
            combinedModuleIDs: [combinedOnlyID]
        )
        let oneStandaloneOutputIsEnough = await AutomaticPublishPlanner.hasAnyCachedStandaloneOutput(
            plan: mixedCachePlan
        ) { id in
            id == secondStandaloneID
        }
        XCTAssertTrue(oneStandaloneOutputIsEnough)

        let onlyCombinedPlan = PublishPlan(
            standaloneModules: [],
            combinedModuleIDs: [combinedOnlyID]
        )
        let combinedOutputDoesNotCount = await AutomaticPublishPlanner.hasAnyCachedStandaloneOutput(
            plan: onlyCombinedPlan
        ) { _ in
            true
        }
        XCTAssertFalse(combinedOutputDoesNotCount)

        let missingStandaloneOutput = await AutomaticPublishPlanner.hasAnyCachedStandaloneOutput(
            plan: plan
        ) { _ in
            false
        }
        XCTAssertFalse(missingStandaloneOutput)
    }
}
