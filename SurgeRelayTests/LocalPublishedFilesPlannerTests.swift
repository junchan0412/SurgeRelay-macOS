import Foundation
import XCTest
@testable import SurgeRelay

final class LocalPublishedFilesPlannerTests: XCTestCase {
    func testCurrentLocalSourcesAreExcludedFromPublishAndConfirmedCleanupOwnership() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Source.sgmodule")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("personal".utf8).write(to: source)
        let module = RelayModule(name: "Source", sourceURL: source.absoluteString, outputFileName: "Source.sgmodule",
            storageLocation: .local, localStorageRelativePath: "Source.sgmodule")
        let protected = LocalPublishedFilesPlanner.protectedSourcePaths(modules: [module], targetDirectory: root.path)
        let plan = LocalPublishedFilesPlanner.plan(files: [], targetDirectory: root.path,
            previousRootDirectory: root.path, previousPublishedPaths: ["SOURCE.sgmodule", "Old.sgmodule"],
            protectedSourcePaths: protected)
        XCTAssertEqual(plan.knownManagedPaths, ["Old.sgmodule"])
        XCTAssertEqual(plan.stalePaths, ["Old.sgmodule"])
        let oldPreview = PublishPreview(destination: .local, targetDescription: root.path,
            activeFiles: ["Source.sgmodule"], changedFiles: [], deletedFiles: ["SOURCE.sgmodule", "Old.sgmodule"])
        let confirmed = LocalPublishedFilesPlanner.confirmedCleanupPlan(preview: oldPreview,
            previousRootDirectory: root.path, previousPublishedPaths: ["Source.sgmodule", "Old.sgmodule"],
            protectedSourcePaths: protected)
        XCTAssertEqual(confirmed.obsoleteRelativePaths, ["Old.sgmodule"])
        XCTAssertEqual(confirmed.knownManagedRelativePaths, ["Old.sgmodule"])
        XCTAssertTrue(confirmed.persistedFilePaths.isEmpty)
        XCTAssertEqual(confirmed.statusMessage, "已清理 1 个本地旧文件")
    }

    func testProtectedSourcesIncludeRegisteredSelfAuthoredCopiesButNotRemoteOutputs() {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let authored = RelayModule(name: "Authored", sourceURL: root.appending(path: "Original.sgmodule").absoluteString,
            outputFileName: "Copy.sgmodule", storageLocation: .local, localStorageRelativePath: "Copy.sgmodule")
        let remote = RelayModule(name: "Remote", sourceURL: "https://example.com/remote.sgmodule", outputFileName: "Remote.sgmodule",
            storageLocation: .local, localStorageRelativePath: "Remote.sgmodule")
        XCTAssertEqual(LocalPublishedFilesPlanner.protectedSourcePaths(modules: [authored, remote], targetDirectory: root.path),
            ["Copy.sgmodule", "Original.sgmodule"])
    }

    func testRootAliasesAndEquivalentPathsKeepOneManagedIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "Output", directoryHint: .isDirectory)
        let alias = root.appending(path: "Alias", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: output)
        let plan = LocalPublishedFilesPlanner.plan(
            files: [PublishFile(name: "Ads/Caf\u{e9}.sgmodule", data: Data())],
            targetDirectory: alias.path + "/", previousRootDirectory: output.path,
            previousPublishedPaths: ["ads\\Cafe\u{301}.sgmodule", "Ads/Caf\u{e9}.sgmodule", "Old.sgmodule"]
        )
        XCTAssertEqual(plan.targetDirectory, output.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(plan.knownManagedPaths.count, 2)
        XCTAssertEqual(plan.stalePaths, ["Old.sgmodule"])
        XCTAssertEqual(LocalPublishedFilesPlanner.mergedPaths(plan.knownManagedPaths, adding: plan.currentPaths),
            ["Ads/Caf\u{e9}.sgmodule", "Old.sgmodule"])
        XCTAssertEqual(LocalPublishedFilesPlanner.knownManagedPathsForConfirmedCleanup(preview: plan.cleanupPreview(),
            previousRootDirectory: alias.path, previousPublishedPaths: ["Old.sgmodule"]), ["Old.sgmodule"])
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

        switch LocalPublishedFilesPlanner.completion(afterExporting: plan) {
        case .requiresCleanup(let completionPreview, let message):
            XCTAssertEqual(completionPreview.destination, .local)
            XCTAssertEqual(completionPreview.targetDescription, "/Users/example/Surge")
            XCTAssertEqual(completionPreview.activeFiles, ["A.sgmodule", "Folder/C.sgmodule"])
            XCTAssertEqual(completionPreview.deletedFiles, ["B.sgmodule"])
            XCTAssertEqual(message, "已写入本地模块，等待确认清理 1 个旧文件")
        case .persisted:
            XCTFail("Expected stale local files to require cleanup confirmation")
        }
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
        XCTAssertEqual(
            LocalPublishedFilesPlanner.completion(afterExporting: plan),
            .persisted(rootDirectory: "/Users/example/NewRoot", filePaths: ["A.sgmodule"])
        )
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

    func testLocalPublishedFilesPlannerBuildsConfirmedCleanupPlan() {
        let preview = PublishPreview(
            destination: .local,
            targetDescription: "/Users/example/Surge",
            activeFiles: ["A.sgmodule", "Folder/B.sgmodule"],
            changedFiles: [],
            deletedFiles: ["Old.sgmodule", "Folder/Removed.sgmodule"]
        )

        let plan = LocalPublishedFilesPlanner.confirmedCleanupPlan(
            preview: preview,
            previousRootDirectory: "/Users/example/Surge",
            previousPublishedPaths: ["A.sgmodule", "Old.sgmodule", "Folder/Removed.sgmodule"]
        )

        XCTAssertEqual(plan.targetDirectory, "/Users/example/Surge")
        XCTAssertEqual(plan.obsoleteRelativePaths, ["Old.sgmodule", "Folder/Removed.sgmodule"])
        XCTAssertEqual(plan.knownManagedRelativePaths, ["A.sgmodule", "Old.sgmodule", "Folder/Removed.sgmodule"])
        XCTAssertEqual(plan.persistedRootDirectory, "/Users/example/Surge")
        XCTAssertEqual(plan.persistedFilePaths, ["A.sgmodule", "Folder/B.sgmodule"])
        XCTAssertEqual(plan.statusMessage, "已清理 2 个本地旧文件")

        let movedRootPlan = LocalPublishedFilesPlanner.confirmedCleanupPlan(
            preview: preview,
            previousRootDirectory: "/Users/example/Other",
            previousPublishedPaths: ["A.sgmodule", "Old.sgmodule"]
        )
        XCTAssertTrue(movedRootPlan.knownManagedRelativePaths.isEmpty)
    }
}
