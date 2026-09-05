import XCTest
@testable import SurgeRelay

final class LocalSourceSyncPlannerTests: XCTestCase {
    private func module(
        name: String,
        sourceURL: String,
        sourceContentHash: String? = nil,
        subscription: ScriptHubSubscriptionInfo? = nil
    ) -> RelayModule {
        RelayModule(
            name: name,
            sourceURL: sourceURL,
            outputFileName: "\(name).sgmodule",
            scriptHubSubscription: subscription,
            sourceContentHash: sourceContentHash
        )
    }

    func testOnlyFileUpdateSourcesAreWatched() {
        let local = module(
            name: "Local",
            sourceURL: "file:///Users/example/Surge/Sgmodule/Local.sgmodule",
            sourceContentHash: "aaa"
        )
        let remote = module(name: "Remote", sourceURL: "https://example.com/remote.sgmodule")
        // 本地文件但带 Script-Hub 订阅：更新来源是远程地址，不应由文件监听驱动。
        let subscribed = module(
            name: "Subscribed",
            sourceURL: "file:///Users/example/Surge/Sgmodule/Subscribed.sgmodule",
            subscription: ScriptHubSubscriptionInfo(
                subscriptionURL: "http://script.hub/file/_start_/https://example.com/upstream.plugin/_end_/Subscribed.sgmodule?type=loon-plugin&target=surge-module",
                originalURL: "https://example.com/upstream.plugin",
                outputName: "Subscribed.sgmodule",
                sourceType: "loon-plugin",
                target: "surge-module",
                category: nil,
                options: ScriptHubOptions()
            )
        )

        let sources = LocalSourceSyncPlanner.sourceFiles(in: [local, remote, subscribed])
        XCTAssertEqual(sources.map(\.moduleID), [local.id])
        XCTAssertEqual(sources.first?.recordedContentHash, "aaa")
        XCTAssertEqual(
            sources.first?.url.path,
            "/Users/example/Surge/Sgmodule/Local.sgmodule"
        )
    }

    func testWatchedDirectoriesDropPathsCoveredByTheLocalRoot() {
        let insideRoot = module(
            name: "Inside",
            sourceURL: "file:///Users/example/Surge/Sgmodule(%235)/Inside.sgmodule"
        )
        let outsideRoot = module(
            name: "Outside",
            sourceURL: "file:///Users/example/Elsewhere/Outside.sgmodule"
        )

        XCTAssertEqual(
            LocalSourceSyncPlanner.watchedDirectories(
                modules: [insideRoot, outsideRoot],
                localModuleDirectory: "/Users/example/Surge"
            ),
            ["/Users/example/Elsewhere", "/Users/example/Surge"]
        )
    }

    func testWatchedDirectoriesFallBackToSourceFoldersWithoutARoot() {
        let module = module(
            name: "Inside",
            sourceURL: "file:///Users/example/Surge/Sgmodule/Inside.sgmodule"
        )

        XCTAssertEqual(
            LocalSourceSyncPlanner.watchedDirectories(
                modules: [module],
                localModuleDirectory: "   "
            ),
            ["/Users/example/Surge/Sgmodule"]
        )
        XCTAssertTrue(
            LocalSourceSyncPlanner.watchedDirectories(modules: [], localModuleDirectory: "").isEmpty
        )
    }

    func testCanonicalDirectoryPathResolvesSymlinkedPathsAndKeepsMissingOnes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LocalSourceSyncPlannerCanonical-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appending(path: "target", directoryHint: .isDirectory)
        let link = directory.appending(path: "link", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertEqual(
            LocalSourceSyncPlanner.canonicalDirectoryPath(link.path),
            LocalSourceSyncPlanner.canonicalDirectoryPath(target.path)
        )
        // 不存在的路径保持原样，规则表仍然可以用虚构路径描述。
        XCTAssertEqual(
            LocalSourceSyncPlanner.canonicalDirectoryPath("/Users/example/Surge"),
            "/Users/example/Surge"
        )
    }

    func testMinimalDirectorySetRemovesNestedAndDuplicatePaths() {
        XCTAssertEqual(
            LocalSourceSyncPlanner.minimalDirectorySet([
                "/a/b",
                "/a/b/",
                "/a/b/c",
                "/a/bc",
                "/d",
            ]),
            ["/a/b", "/a/bc", "/d"]
        )
        XCTAssertEqual(LocalSourceSyncPlanner.minimalDirectorySet(["/", "/a"]), ["/"])
    }

    func testChangedModuleIDsCompareAgainstTheRecordedRevisionHash() {
        let changed = module(
            name: "Changed",
            sourceURL: "file:///Users/example/Surge/Changed.sgmodule",
            sourceContentHash: "old"
        )
        let unchanged = module(
            name: "Unchanged",
            sourceURL: "file:///Users/example/Surge/Unchanged.sgmodule",
            sourceContentHash: "same"
        )
        let neverSynced = module(
            name: "NeverSynced",
            sourceURL: "file:///Users/example/Surge/NeverSynced.sgmodule"
        )
        let sources = LocalSourceSyncPlanner.sourceFiles(in: [changed, unchanged, neverSynced])

        let result = LocalSourceSyncPlanner.changedModuleIDs(
            sourceFiles: sources,
            currentHashes: [
                changed.id: "new",
                unchanged.id: "same",
                neverSynced.id: "first",
            ]
        )

        XCTAssertEqual(result, [changed.id, neverSynced.id])
    }

    func testMissingSourceFilesAreNotReportedAsChanged() {
        let missing = module(
            name: "Missing",
            sourceURL: "file:///Users/example/Surge/Missing.sgmodule",
            sourceContentHash: "old"
        )
        let sources = LocalSourceSyncPlanner.sourceFiles(in: [missing])

        XCTAssertTrue(
            LocalSourceSyncPlanner.changedModuleIDs(sourceFiles: sources, currentHashes: [:]).isEmpty
        )
    }

    func testContentHashesReadDiskAndSkipEmptyOrMissingFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LocalSourceSyncPlannerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let populated = directory.appending(path: "Populated.sgmodule")
        let empty = directory.appending(path: "Empty.sgmodule")
        let payload = Data("#!name=Populated\n[Rule]\nFINAL,DIRECT\n".utf8)
        try payload.write(to: populated)
        try Data().write(to: empty)

        let populatedModule = module(
            name: "Populated",
            sourceURL: populated.absoluteString,
            sourceContentHash: "stale"
        )
        let emptyModule = module(name: "Empty", sourceURL: empty.absoluteString)
        let missingModule = module(
            name: "Missing",
            sourceURL: directory.appending(path: "Missing.sgmodule").absoluteString
        )
        let sources = LocalSourceSyncPlanner.sourceFiles(
            in: [populatedModule, emptyModule, missingModule]
        )

        let hashes = LocalSourceSyncPlanner.contentHashes(for: sources)

        XCTAssertEqual(hashes[populatedModule.id], payload.sha256String)
        XCTAssertNil(hashes[emptyModule.id])
        XCTAssertNil(hashes[missingModule.id])
        XCTAssertEqual(
            LocalSourceSyncPlanner.changedModuleIDs(sourceFiles: sources, currentHashes: hashes),
            [populatedModule.id]
        )
    }

    func testDetectedStatusNamesTheSingleChangedModule() {
        XCTAssertEqual(
            LocalSourceSyncPlanner.detectedStatus(changedCount: 1, firstModuleName: "Applications"),
            "检测到 Applications 的本地文件已修改，正在同步…"
        )
        XCTAssertEqual(
            LocalSourceSyncPlanner.detectedStatus(changedCount: 3, firstModuleName: nil),
            "检测到 3 个本地模块文件已修改，正在同步…"
        )
        XCTAssertEqual(
            LocalSourceSyncPlanner.detectedStatus(changedCount: 0, firstModuleName: nil),
            "本地模块文件没有变化"
        )
    }
}
