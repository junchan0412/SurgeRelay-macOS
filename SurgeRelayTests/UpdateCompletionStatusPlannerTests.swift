import Foundation
import XCTest
@testable import SurgeRelay

final class UpdateCompletionStatusPlannerTests: XCTestCase {
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
}
