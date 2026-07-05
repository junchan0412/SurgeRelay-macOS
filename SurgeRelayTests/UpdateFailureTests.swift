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

    func testUpdateFailurePlannerDecidesWhenToProbeOriginalSource() {
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

        XCTAssertTrue(UpdateFailurePlanner.shouldCheckOriginalSourceAfterConversionFailure(
            RelayError.invalidOutput("Script-Hub 转换失败"),
            module: remote,
            existingSourceCheckFailure: nil
        ))
        XCTAssertFalse(UpdateFailurePlanner.shouldCheckOriginalSourceAfterConversionFailure(
            RelayError.httpFailure(status: 404, message: "Not Found"),
            module: remote,
            existingSourceCheckFailure: nil
        ))
        XCTAssertFalse(UpdateFailurePlanner.shouldCheckOriginalSourceAfterConversionFailure(
            RelayError.invalidOutput("Script-Hub 转换失败"),
            module: local,
            existingSourceCheckFailure: nil
        ))
        XCTAssertFalse(UpdateFailurePlanner.shouldCheckOriginalSourceAfterConversionFailure(
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
}
