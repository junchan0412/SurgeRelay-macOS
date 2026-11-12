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

    @MainActor
    func testExternalSubscribedOutputEditingPreservesConversionAndAssets() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = localSyncModel(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        var original = module(name: "Remote", sourceURL: "https://example.com/Remote.sgmodule", sourceContentHash: "remote-revision")
        original.storageLocation = .local
        model.modules = [original]
        let converted = "#!name=Remote\n[Rule]\nDOMAIN,old.example,DIRECT\n"
        let asset = GeneratedAsset(relativePath: "assets/\(original.id.uuidString.lowercased())/script.js", data: Data("$done({});".utf8))
        try await model.fileStore.commitConversion(ConversionResult(content: converted, requestURL: URL(string: original.sourceURL)!, assets: [asset]), id: original.id)
        let file = root.appending(path: "Local/Remote.sgmodule")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let edited = "#!name=Renamed\n#!category=Local Edits\n#!desc=Edited on disk\n[Rule]\nDOMAIN,new.example,DIRECT\n"
        try Data(edited.utf8).write(to: file, options: .atomic)

        let changed = await model.syncChangedLocalOutputs(reason: .fileSystemEvent, changedPaths: [file.path])

        XCTAssertEqual(changed, [original.id])
        let effective = try await model.fileStore.readComponent(id: original.id)
        let baseline = try await model.fileStore.readConvertedComponent(id: original.id)
        let assets = try await model.fileStore.generatedAssetFiles(for: [original.id])
        let versions = try await model.fileStore.moduleVersions(id: original.id)
        XCTAssertEqual(effective, edited)
        XCTAssertEqual(baseline, converted)
        XCTAssertEqual(assets.first?.data, asset.data)
        XCTAssertEqual(versions.first?.reason, .beforeEdit)
        XCTAssertEqual(model.modules[0].name, "Renamed")
        XCTAssertEqual(model.modules[0].category, "Local Edits")
        XCTAssertEqual(model.modules[0].moduleDescription, "Edited on disk")
        XCTAssertEqual(model.modules[0].updateSourceURL, original.sourceURL)
        XCTAssertEqual(model.modules[0].sourceContentHash, "remote-revision")
        XCTAssertEqual(model.modules[0].overrideBaseHash, Data(converted.utf8).sha256String)
        XCTAssertEqual(try Data(contentsOf: file), Data(edited.utf8))
        let repeated = await model.syncChangedLocalOutputs(reason: .fileSystemEvent, changedPaths: [file.path])
        XCTAssertTrue(repeated.isEmpty)
    }

    @MainActor
    func testStartupAndUnrelatedEventsKeepNewerCacheAndDetectMissingOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = localSyncModel(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        var original = module(name: "Remote", sourceURL: "https://example.com/Remote.sgmodule")
        original.storageLocation = .local
        model.modules = [original]
        let file = root.appending(path: "Local/Remote.sgmodule")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldDisk = "#!name=Remote\n[Rule]\nDOMAIN,old.example,DIRECT\n"
        try Data(oldDisk.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: file.path)
        let newerCache = "#!name=Remote\n[Rule]\nDOMAIN,new.example,DIRECT\n"
        try await model.fileStore.commitConversion(ConversionResult(content: newerCache, requestURL: URL(string: original.sourceURL)!), id: original.id)

        let launch = await model.syncChangedLocalOutputs(reason: .launch)
        let unrelated = await model.syncChangedLocalOutputs(reason: .fileSystemEvent, changedPaths: [root.appending(path: "Local/Other.sgmodule").path])
        XCTAssertTrue(launch.isEmpty)
        XCTAssertTrue(unrelated.isEmpty)
        let retained = try await model.fileStore.readComponent(id: original.id)
        XCTAssertEqual(retained, newerCache)

        try FileManager.default.removeItem(at: file)
        _ = await model.syncChangedLocalOutputs(reason: .fileSystemEvent, changedPaths: [file.path])
        XCTAssertTrue(model.modules[0].localOutputError?.contains("已缺失") == true)
        let missingOutputCache = try await model.fileStore.readComponent(id: original.id)
        XCTAssertEqual(missingOutputCache, newerCache)
    }

    func testChangedPathsMatchAtomicSaveParentAndExcludeSiblingDirectories() {
        let file = URL(filePath: "/Users/example/Surge/Modules/Local.sgmodule")
        XCTAssertTrue(LocalSourceSyncPlanner.includesFile(file, changedPaths: [file.path]))
        XCTAssertTrue(LocalSourceSyncPlanner.includesFile(file, changedPaths: ["/Users/example/Surge/Modules"]))
        XCTAssertFalse(LocalSourceSyncPlanner.includesFile(file, changedPaths: ["/Users/example/Surge/Module"]))
        XCTAssertFalse(LocalSourceSyncPlanner.includesFile(file, changedPaths: ["/Users/example/Surge/Modules/Other.sgmodule"]))
    }

    @MainActor
    func testMissingSelfAuthoredSourceRetainsCacheAndRecoversIdenticalFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = localSyncModel(root: root)
        defer { model.persistenceFeedbackTask?.cancel() }
        model.settings.watchesLocalModuleChanges = true
        let file = root.appending(path: "Local/Self.sgmodule")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = "#!name=Self\n[Rule]\nDOMAIN,self.example,DIRECT\n"
        let data = Data(content.utf8)
        try data.write(to: file)
        let original = module(name: "Self", sourceURL: file.absoluteString, sourceContentHash: data.sha256String)
        model.modules = [original]
        try await model.fileStore.commitConversion(ConversionResult(content: content, requestURL: file), id: original.id)
        try FileManager.default.removeItem(at: file)

        await model.syncChangedLocalSources(reason: .manual)

        XCTAssertEqual(model.modules[0].state, .failed)
        XCTAssertTrue(model.modules[0].lastError?.contains("已缺失") == true)
        let missingCache = try await model.fileStore.readComponent(id: original.id)
        XCTAssertEqual(missingCache, content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try data.write(to: file, options: .atomic)
        await model.syncChangedLocalSources(reason: .manual)

        XCTAssertEqual(model.modules[0].state, .current)
        XCTAssertNil(model.modules[0].lastError)
        XCTAssertEqual(model.modules[0].sourceContentHash, data.sha256String)
    }

    @MainActor
    private func localSyncModel(root: URL) -> AppModel {
        let context = WorkspaceContext(id: UUID(), name: "Local sync", configurationDirectory: root.appending(path: "Config"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        model.settings.setLocalStorage(ClientLocalStorage(isEnabled: true, directory: root.appending(path: "Local").path), for: .surge)
        model.settings.publishToLocal = false
        model.settings.publishToGitHub = false
        model.settings.automaticallyPublish = false
        model.settings.watchesLocalModuleChanges = false
        return model
    }
}
