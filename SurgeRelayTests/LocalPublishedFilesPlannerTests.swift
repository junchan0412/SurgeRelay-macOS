import Foundation
import XCTest
@testable import SurgeRelay

final class LocalPublishedFilesPlannerTests: XCTestCase {
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
}
