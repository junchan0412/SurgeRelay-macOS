import Foundation
import XCTest
@testable import SurgeRelay

final class UpdateFailureTests: XCTestCase {
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

    func testUpdateFailurePlannerDecidesWhenToProbeUpdateSource() {
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

        XCTAssertTrue(UpdateFailurePlanner.shouldCheckUpdateSourceAfterConversionFailure(
            RelayError.invalidOutput("Script-Hub 转换失败"),
            module: remote,
            existingSourceCheckFailure: nil
        ))
        XCTAssertFalse(UpdateFailurePlanner.shouldCheckUpdateSourceAfterConversionFailure(
            RelayError.httpFailure(status: 404, message: "Not Found"),
            module: remote,
            existingSourceCheckFailure: nil
        ))
        XCTAssertFalse(UpdateFailurePlanner.shouldCheckUpdateSourceAfterConversionFailure(
            RelayError.invalidOutput("Script-Hub 转换失败"),
            module: local,
            existingSourceCheckFailure: nil
        ))
        XCTAssertFalse(UpdateFailurePlanner.shouldCheckUpdateSourceAfterConversionFailure(
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

    func testUpdateFailurePlannerBuildsCachedFailureOutcome() {
        let moduleID = UUID()
        let module = RelayModule(
            id: moduleID,
            name: "Cached",
            sourceURL: "https://example.com/cached.conf",
            sourceFormat: .quantumultX,
            outputFileName: "Cached"
        )

        let plan = UpdateFailurePlanner.cachedFailureOutcome(
            module: module,
            failureMessage: "原始链接返回 404",
            duration: 1.25,
            contributesToCombined: true
        )

        XCTAssertTrue(plan.shouldUseCachedContentInCombined)
        XCTAssertNil(plan.missingCacheModuleName)
        XCTAssertNil(plan.missingCacheDetail)
        XCTAssertEqual(plan.historyEntry.moduleID, moduleID)
        XCTAssertEqual(plan.historyEntry.moduleName, "Cached")
        XCTAssertEqual(plan.historyEntry.outcome, .cachedAfterFailure)
        XCTAssertEqual(plan.historyEntry.duration, 1.25)
        XCTAssertEqual(plan.historyEntry.message, "原始链接返回 404")
        XCTAssertTrue(plan.historyEntry.usedCache)
    }

    func testUpdateFailurePlannerBuildsMissingCacheOutcomeOnlyForCombinedContributors() {
        let module = RelayModule(
            name: "Missing",
            sourceURL: "https://example.com/missing.conf",
            sourceFormat: .quantumultX,
            outputFileName: "Missing"
        )

        let contributingPlan = UpdateFailurePlanner.missingCacheFailureOutcome(
            module: module,
            failureMessage: "第一行\n第二行",
            duration: 2.5,
            contributesToCombined: true
        )

        XCTAssertFalse(contributingPlan.shouldUseCachedContentInCombined)
        XCTAssertEqual(contributingPlan.missingCacheModuleName, "Missing")
        XCTAssertEqual(contributingPlan.missingCacheDetail, "- Missing：第一行\n  第二行")
        XCTAssertEqual(contributingPlan.historyEntry.outcome, .failed)
        XCTAssertEqual(contributingPlan.historyEntry.duration, 2.5)
        XCTAssertEqual(contributingPlan.historyEntry.message, "第一行\n第二行")
        XCTAssertFalse(contributingPlan.historyEntry.usedCache)

        let standaloneOnlyPlan = UpdateFailurePlanner.missingCacheFailureOutcome(
            module: module,
            failureMessage: "失败",
            duration: 0.5,
            contributesToCombined: false
        )

        XCTAssertNil(standaloneOnlyPlan.missingCacheModuleName)
        XCTAssertNil(standaloneOnlyPlan.missingCacheDetail)
        XCTAssertEqual(standaloneOnlyPlan.historyEntry.outcome, .failed)
    }

    func testUpdateFailurePlannerBuildsMissingCacheBlockage() throws {
        XCTAssertNil(UpdateFailurePlanner.missingCacheBlockage(moduleNames: [], details: []))

        let blockage = try XCTUnwrap(UpdateFailurePlanner.missingCacheBlockage(
            moduleNames: ["A", "B"],
            details: ["- A：404", "- B：DNS"]
        ))

        XCTAssertEqual(blockage.statusMessage, "无法重建总模块：A、B 尚无可用缓存")
        XCTAssertEqual(blockage.presentedError, "以下来源首次转换失败，因此没有覆盖当前总模块：\n- A：404\n- B：DNS")

        let fallback = try XCTUnwrap(UpdateFailurePlanner.missingCacheBlockage(
            moduleNames: ["A"],
            details: []
        ))
        XCTAssertEqual(fallback.presentedError, "以下来源首次转换失败，因此没有覆盖当前总模块：\nA")
    }
}
