import XCTest
@testable import SurgeRelay

final class WorkActivityTests: XCTestCase {
    func testWorkActivityDescribesActiveAndNonBlockingWork() {
        let startedAt = Date(timeIntervalSince1970: 1_800)
        let publishing = WorkActivity(kind: .publishing, startedAt: startedAt)

        XCTAssertTrue(publishing.isActive)
        XCTAssertEqual(publishing.title, "GitHub 发布")
        XCTAssertEqual(publishing.startedAt, startedAt)
        XCTAssertTrue(publishing.blocksUpdates)
        XCTAssertTrue(publishing.canCancel)
        XCTAssertEqual(
            publishing.updateBlockedReason(statusMessage: "正在生成 GitHub 发布预览…"),
            "Surge Relay 正在执行“GitHub 发布”任务：正在生成 GitHub 发布预览…"
        )

        let keychain = WorkActivity(kind: .checkingKeychain)
        XCTAssertTrue(keychain.isActive)
        XCTAssertFalse(keychain.blocksUpdates)
        XCTAssertFalse(keychain.canCancel)
        XCTAssertNil(keychain.updateBlockedReason(statusMessage: "正在写入、读取并清理临时诊断项。"))
        XCTAssertFalse(WorkActivity.idle.isActive)
        XCTAssertFalse(WorkActivity.idle.canCancel)
    }

    func testWorkActivityCanOverrideCancellationAvailability() {
        XCTAssertFalse(WorkActivity(kind: .updatingModules, canCancel: false).canCancel)
        XCTAssertTrue(WorkActivity(kind: .savingPreview, canCancel: true).canCancel)
    }

    func testUpdateAdmissionExplainsBlockedAndAcceptedStates() {
        let busy = UpdateAdmission.allModules(
            isWorking: true,
            updateableModuleCount: 2,
            statusMessage: "正在检查 Demo…"
        )
        XCTAssertFalse(busy.isAccepted)
        XCTAssertEqual(busy.blockedReason, "Surge Relay 正在执行其他任务：正在检查 Demo…")

        let empty = UpdateAdmission.allModules(
            isWorking: false,
            updateableModuleCount: 0,
            statusMessage: "准备就绪"
        )
        XCTAssertFalse(empty.isAccepted)
        XCTAssertEqual(empty.message, "没有可更新的模块。请添加远程原始地址，或扫描带 Script-Hub 模块链接的本地模块。")

        let disabled = RelayModule(
            name: "Demo",
            sourceURL: URL(filePath: "/tmp/demo.sgmodule").absoluteString,
            outputFileName: "Demo",
            isEnabled: false
        )
        let disabledAdmission = UpdateAdmission.module(
            disabled,
            moduleIsUpdateable: false,
            isWorking: false,
            updateableModuleCount: 0,
            statusMessage: "准备就绪"
        )
        XCTAssertFalse(disabledAdmission.isAccepted)
        XCTAssertEqual(disabledAdmission.message, "“Demo”没有远程原始地址，无法从上游更新。")

        let enabled = RelayModule(
            name: "Demo",
            sourceURL: "https://example.com/demo.sgmodule",
            outputFileName: "Demo",
            isEnabled: true
        )
        let accepted = UpdateAdmission.module(
            enabled,
            moduleIsUpdateable: true,
            isWorking: false,
            updateableModuleCount: 1,
            statusMessage: "准备就绪"
        )
        XCTAssertTrue(accepted.isAccepted)
        XCTAssertNil(accepted.blockedReason)
    }

    func testUpdateAdmissionUsesStructuredWorkActivity() {
        let busy = UpdateAdmission.allModules(
            activity: WorkActivity(kind: .previewingPublish),
            updateableModuleCount: 2,
            statusMessage: "正在生成 GitHub 发布预览…"
        )
        XCTAssertFalse(busy.isAccepted)
        XCTAssertEqual(
            busy.blockedReason,
            "Surge Relay 正在执行“发布预览”任务：正在生成 GitHub 发布预览…"
        )

        let checkingKeychain = UpdateAdmission.allModules(
            activity: WorkActivity(kind: .checkingKeychain),
            updateableModuleCount: 1,
            statusMessage: "正在写入、读取并清理临时诊断项。"
        )
        XCTAssertTrue(checkingKeychain.isAccepted)
    }
}
