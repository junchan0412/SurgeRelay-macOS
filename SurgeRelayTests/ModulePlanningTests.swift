import Foundation
import XCTest
@testable import SurgeRelay

final class ModulePlanningTests: XCTestCase {
    func testFilenameSanitizerCreatesSurgeModuleExtension() {
        XCTAssertEqual(FilenameSanitizer.sgmoduleName(from: "YouTube Ads.sgmodule"), "YouTube-Ads.sgmodule")
        XCTAssertEqual(FilenameSanitizer.existingSgmoduleName(from: "YouTube Ads.sgmodule"), "YouTube Ads.sgmodule")
        XCTAssertEqual(FilenameSanitizer.sgmoduleName(from: "folder/bad:name"), "folder-bad-name.sgmodule")
        XCTAssertEqual(FilenameSanitizer.existingSgmoduleName(from: "folder/bad:name"), "bad-name.sgmodule")
    }

    func testLocalFileModulePreservesExistingPublishedFileName() {
        let module = RelayModule(
            name: "Local Demo",
            sourceURL: URL(filePath: "/tmp/Local Demo.sgmodule").absoluteString,
            sourceFormat: .surge,
            outputFileName: "Local Demo.sgmodule",
            outputFolder: "Local Modules"
        )

        XCTAssertEqual(module.outputFileName, "Local Demo.sgmodule")
        XCTAssertEqual(module.publishedRelativePath, "Local Modules/Local Demo.sgmodule")
    }

    func testModuleEditorSourceNameLookupUsesRemoteMetadata() async {
        let name = await ModuleEditorSourceNameLookup.autofillName(
            from: " https://example.com/Remote.plugin "
        ) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/Remote.plugin")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Surge Relay")
            return Data("#!name=Remote Module\n[Script]\n".utf8)
        }

        XCTAssertEqual(name, "Remote Module")
    }

    func testModuleEditorSourceNameLookupFallsBackToURLNameWhenMetadataIsMissing() async {
        let name = await ModuleEditorSourceNameLookup.autofillName(
            from: "https://example.com/folder/remote-module.conf"
        ) { _ in
            Data("[rewrite_local]\n".utf8)
        }

        XCTAssertEqual(name, "remote module")
    }

    func testModuleEditorSourceNameLookupFallsBackWhenBoundedFetcherBlocksPrivateURL() async {
        let name = await ModuleEditorSourceNameLookup.autofillName(
            from: "http://127.0.0.1/private-module.sgmodule"
        )

        XCTAssertEqual(name, "private module")
    }

    func testModuleEditorSourceNameLookupReadsLocalMetadataWithoutNetwork() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appending(path: "file-name.sgmodule")
        try Data("#!name = 内容中的默认名称\n[Rule]\nFINAL,DIRECT".utf8).write(to: local)
        let localURL = local.absoluteString
        let name = await ModuleEditorSourceNameLookup.autofillName(from: localURL) { _ in
            XCTFail("Local file URLs should not be fetched for name lookup.")
            return Data()
        }

        XCTAssertEqual(name, "内容中的默认名称")
        XCTAssertNil(ModuleEditorSourceNameLookup.remoteURL(from: "ftp://example.com/demo.sgmodule"))
    }

    func testSourceNameLookupUsesOriginalContentForSubscribedURL() async throws {
        let subscription = "http://script.hub/file/_start_/https://example.com/wrong-filename.plugin/_end_/Wrong.sgmodule?type=loon-plugin&target=surge-module"
        let name = try await ModuleEditorSourceNameLookup.resolvedName(from: subscription) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/wrong-filename.plugin")
            return Data("#!name = \"来源声明名称\"\n[Script]\n".utf8)
        }
        XCTAssertEqual(name, "来源声明名称")
    }

    func testLocalSourceNameFallsBackToFilenameOnlyWithoutNameMetadata() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appending(path: "Fallback-Name.sgmodule")
        try Data("[Rule]\nFINAL,DIRECT".utf8).write(to: local)
        let name = await ModuleEditorSourceNameLookup.autofillName(from: local.absoluteString)
        XCTAssertEqual(name, "Fallback Name")
    }

    func testRemoteSubscriptionNameLookupCannotReadEmbeddedLocalFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appending(path: "Private.sgmodule")
        try Data("#!name=Private local metadata\n[Rule]\nFINAL,DIRECT".utf8).write(to: local)
        let wrapped = "https://example.com/file/_start_/\(local.absoluteString)/_end_/Demo.sgmodule?type=surge-module&target=surge-module"
        do {
            _ = try await ModuleEditorSourceNameLookup.resolvedName(from: wrapped) { _ in
                XCTFail("An embedded local source must not become a remote lookup")
                return Data()
            }
            XCTFail("Remote subscription URLs may not select local files")
        } catch { XCTAssertEqual(error as? BoundedRemoteFetchError, .invalidSourceURL) }
    }

    func testBoundedRemoteDataFetcherRejectsPrivateNetworkTargets() async throws {
        let fetcher = BoundedRemoteDataFetcher(maximumResponseSize: 64, timeoutInterval: 1)
        let blockedURLs = [
            "http://127.0.0.1/demo.sgmodule",
            "http://10.0.0.1/demo.sgmodule",
            "http://[::1]/demo.sgmodule",
            "http://router.local/demo.sgmodule"
        ]

        for value in blockedURLs {
            let url = try XCTUnwrap(URL(string: value))
            do {
                _ = try await fetcher.data(for: URLRequest(url: url))
                XCTFail("Expected \(value) to be blocked")
            } catch let error as BoundedRemoteFetchError {
                guard case .blockedPrivateAddress = error else {
                    return XCTFail("Expected private-address error for \(value), got \(error)")
                }
            }
        }
    }

    func testBoundedRemoteDataFetcherRejectsLargeContentLength() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedRemoteDataFetcherURLProtocol.self]
        let fetcher = BoundedRemoteDataFetcher(
            maximumResponseSize: 8,
            timeoutInterval: 1,
            configuration: configuration
        )
        BoundedRemoteDataFetcherURLProtocol.response = (
            status: 200,
            headers: ["Content-Length": "32"],
            chunks: [Data("tiny".utf8)]
        )

        do {
            _ = try await fetcher.data(for: URLRequest(url: try XCTUnwrap(URL(string: "https://8.8.8.8/large.sgmodule"))))
            XCTFail("Expected oversized Content-Length to be rejected")
        } catch BoundedRemoteFetchError.responseTooLarge(let maximumSize) {
            XCTAssertEqual(maximumSize, 8)
        }
    }

    func testBoundedRemoteDataFetcherAppliesConfiguredTimeout() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedRemoteDataFetcherURLProtocol.self]
        let fetcher = BoundedRemoteDataFetcher(
            maximumResponseSize: 64,
            timeoutInterval: 3,
            configuration: configuration
        )
        BoundedRemoteDataFetcherURLProtocol.requestedTimeouts = []
        BoundedRemoteDataFetcherURLProtocol.response = (
            status: 200,
            headers: [:],
            chunks: [Data("#!name=Tiny\n".utf8)]
        )

        _ = try await fetcher.data(for: URLRequest(url: try XCTUnwrap(URL(string: "https://8.8.8.8/timeout.sgmodule"))))

        XCTAssertEqual(BoundedRemoteDataFetcherURLProtocol.requestedTimeouts, [3])
    }

    func testBoundedRemoteDataFetcherRejectsLargeBodyWithoutContentLength() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedRemoteDataFetcherURLProtocol.self]
        let fetcher = BoundedRemoteDataFetcher(
            maximumResponseSize: 8,
            timeoutInterval: 1,
            configuration: configuration
        )
        BoundedRemoteDataFetcherURLProtocol.response = (
            status: 200,
            headers: [:],
            chunks: [Data("this body is too large".utf8)]
        )

        do {
            _ = try await fetcher.data(for: URLRequest(url: try XCTUnwrap(URL(string: "https://8.8.8.8/body.sgmodule"))))
            XCTFail("Expected oversized response body to be rejected")
        } catch BoundedRemoteFetchError.responseTooLarge(let maximumSize) {
            XCTAssertEqual(maximumSize, 8)
        }
    }

    func testModuleOutputPathInspectorExplainsNonPublishingAndCollisions() {
        let existingID = UUID()
        let existing = RelayModule(
            id: existingID,
            name: "Existing",
            sourceURL: "https://example.com/existing.sgmodule",
            outputFileName: "Existing",
            outputFolder: "Ads"
        )

        XCTAssertNil(ModuleOutputPathInspector.notice(for: "Surge-Relay.sgmodule", modules: [existing], editingModuleID: nil))
        XCTAssertEqual(
            ModuleOutputPathInspector.notice(
                for: "Ads/Existing.sgmodule",
                modules: [existing],
                editingModuleID: nil
            ),
            ModuleOutputPathNotice(message: "该路径已被“Existing”使用，保存时会自动加编号避免覆盖。", isWarning: true)
        )
        XCTAssertNil(ModuleOutputPathInspector.notice(
            for: "Ads/Existing.sgmodule",
            modules: [existing],
            editingModuleID: existingID
        ))
    }

    func testLocalRootFileSkipsOnlyLocalSelfExport() {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let source = root.appending(path: "Ads/YouTube Ads.sgmodule")
        let module = RelayModule(
            name: "YouTube",
            sourceURL: source.absoluteString,
            sourceFormat: .surge,
            outputFileName: "YouTube Ads.sgmodule",
            outputFolder: "Ads"
        )

        XCTAssertTrue(PublishCoordinator.shouldSkipStandaloneLocalExport(
            module,
            isLocalExport: true,
            localModuleDirectory: root.path
        ))
        XCTAssertFalse(PublishCoordinator.shouldSkipStandaloneLocalExport(
            module,
            isLocalExport: false,
            localModuleDirectory: root.path
        ))

        let copiedModule = RelayModule(
            name: "YouTube Copy",
            sourceURL: source.absoluteString,
            sourceFormat: .surge,
            outputFileName: "YouTube Copy.sgmodule",
            outputFolder: "Ads"
        )
        XCTAssertFalse(PublishCoordinator.shouldSkipStandaloneLocalExport(
            copiedModule,
            isLocalExport: true,
            localModuleDirectory: root.path
        ))
    }

    func testLocalRemoteBackedModuleDoesNotSkipLocalExport() {
        let module = RelayModule(
            name: "Remote Backed Local",
            sourceURL: "https://raw.githubusercontent.com/example/repo/main/qx.conf",
            sourceFormat: .quantumultX,
            outputFileName: "Remote Backed.sgmodule",
            outputFolder: "Converted",
            storageLocation: .local,
            localStorageRelativePath: "Converted/Remote Backed.sgmodule",
            preservesOutputFileName: true
        )

        XCTAssertEqual(module.storageLocation, .local)
        XCTAssertEqual(module.initialSource, .remote(.quantumultX))
        XCTAssertEqual(module.publishedRelativePath, "Converted/Remote Backed.sgmodule")
        // 来源是远程 URL，localStorageRelativePath 只是发布输出路径而非来源文件，
        // 因此本地导出不应被自覆盖保护跳过。
        XCTAssertFalse(PublishCoordinator.shouldSkipStandaloneLocalExport(
            module,
            isLocalExport: true,
            localModuleDirectory: "/Users/example/Surge"
        ))
        XCTAssertFalse(PublishCoordinator.shouldSkipStandaloneLocalExport(
            module,
            isLocalExport: false,
            localModuleDirectory: "/Users/example/Surge"
        ))
    }

    func testModuleNamingPlannerBuildsLocalStorageRelativePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let source = root.appending(path: "Ads/My Module.sgmodule").absoluteString

        XCTAssertEqual(
            try ModuleNamingPlanner.localStorageRelativePath(
                storageLocation: .local,
                source: source,
                outputFileName: "Different.sgmodule",
                outputFolder: "Converted",
                localModuleDirectory: root.path
            ),
            "Ads/My Module.sgmodule"
        )
        XCTAssertNil(try ModuleNamingPlanner.localStorageRelativePath(
            storageLocation: .gitHub,
            source: source,
            outputFileName: "Different.sgmodule",
            outputFolder: "Converted",
            localModuleDirectory: ""
        ))
        XCTAssertThrowsError(try ModuleNamingPlanner.localStorageRelativePath(
            storageLocation: .local,
            source: "https://example.com/source.conf",
            outputFileName: "Different.sgmodule",
            outputFolder: "Converted",
            localModuleDirectory: "   "
        ))
    }

    func testModuleNamingPlannerReservesOnlyExistingOutputPaths() {
        let existing = RelayModule(
            name: "Existing",
            sourceURL: "https://example.com/existing.sgmodule",
            outputFileName: "Existing",
            outputFolder: "Folder"
        )
        var draft = ModuleDraft()
        draft.name = "Existing"
        draft.sourceURL = "https://example.com/new.sgmodule"
        draft.outputFolder = "Folder"

        XCTAssertEqual(
            ModuleNamingPlanner.uniqueOutputFileName(
                for: draft,
                source: draft.sourceURL,
                modules: [existing]
            ),
            "Existing-2.sgmodule"
        )

        draft.name = "Surge Relay"
        draft.outputFolder = ""
        XCTAssertEqual(
            ModuleNamingPlanner.uniqueOutputFileName(
                for: draft,
                source: draft.sourceURL,
                modules: []
            ),
            "Surge-Relay.sgmodule"
        )

        XCTAssertEqual(
            ModuleNamingPlanner.uniqueOutputFileName(
                preferredFileName: "My Module.sgmodule",
                folder: "Folder",
                unavailable: ["folder/my module.sgmodule"],
                preservesExistingFileName: true
            ),
            "My Module-2.sgmodule"
        )
    }

    func testModuleNamingPlannerNormalizesLoadedModulesWithoutLosingLocalPaths() {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let localSource = root.appending(path: "Ads/My Module.sgmodule").absoluteString
        let local = RelayModule(
            name: "Imported Local",
            sourceURL: localSource,
            outputFileName: "Old Generated Name",
            outputFolder: " /Ads/ ",
            storageLocation: .local,
            localStorageRelativePath: nil,
            preservesOutputFileName: false
        )
        let combinedCollision = RelayModule(
            name: "Combined",
            sourceURL: "https://example.com/combined.sgmodule",
            outputFileName: "Surge Relay",
            storageLocation: .gitHub
        )

        let normalized = ModuleNamingPlanner.normalizedModuleNaming(
            [local, combinedCollision],
            localModuleDirectory: root.path
        )

        XCTAssertEqual(normalized[0].outputFolder, "Ads")
        XCTAssertEqual(normalized[0].outputFileName, "My Module.sgmodule")
        XCTAssertEqual(normalized[0].localStorageRelativePath, "Ads/My Module.sgmodule")
        XCTAssertTrue(normalized[0].preservesOutputFileName)
        XCTAssertEqual(normalized[1].outputFileName, "Surge-Relay.sgmodule")
    }

    func testLoadedNamingReservesPhysicalLocalPathBeforeRemoteModule() {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let remote = RelayModule(
            name: "Remote collision",
            sourceURL: "https://example.com/remote.sgmodule",
            outputFileName: "My Module.sgmodule",
            outputFolder: "Tools",
            storageLocation: .gitHub,
            preservesOutputFileName: true
        )
        let local = RelayModule(
            name: "Local",
            sourceURL: root.appending(path: "Tools/My Module.sgmodule").absoluteString,
            outputFileName: "My Module.sgmodule",
            outputFolder: "Tools",
            storageLocation: .local,
            localStorageRelativePath: "Tools/My Module.sgmodule"
        )

        let normalized = ModuleNamingPlanner.normalizedModuleNaming(
            [remote, local],
            localModuleDirectory: root.path
        )

        XCTAssertEqual(normalized[0].publishedRelativePath, "Tools/My Module-2.sgmodule")
        XCTAssertEqual(normalized[1].publishedRelativePath, "Tools/My Module.sgmodule")
        XCTAssertEqual(normalized[1].localStorageRelativePath, "Tools/My Module.sgmodule")
        XCTAssertEqual(ModuleNamingPlanner.normalizedModuleNaming(
            normalized,
            localModuleDirectory: root.path
        ), normalized)
    }

    func testModuleNamingPlannerReservesLocalPathsAndUnicodeAliases() {
        let existing = RelayModule(
            name: "Local",
            sourceURL: "https://example.com/existing.sgmodule",
            outputFileName: "Different.sgmodule",
            storageLocation: .local,
            localStorageRelativePath: "Tools/Café.sgmodule"
        )
        var draft = ModuleDraft(defaultStorageLocation: .local)
        draft.name = "New"
        draft.sourceURL = "https://example.com/new.sgmodule"
        draft.outputFileName = "Cafe\u{301}.sgmodule"
        draft.outputFolder = "Tools"

        XCTAssertEqual(ModuleNamingPlanner.uniqueOutputFileName(
            for: draft,
            source: draft.sourceURL,
            modules: [existing]
        ), "Cafe\u{301}-2.sgmodule")
    }

    func testLoadedNamingPreservesExplicitLocalSourceOutputFolder() {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let module = RelayModule(
            name: "Local export",
            sourceURL: root.appending(path: "Sources/My Module.sgmodule").absoluteString,
            outputFileName: "My Module.sgmodule",
            outputFolder: "Exports",
            storageLocation: .local,
            localStorageRelativePath: "Sources/My Module.sgmodule"
        )

        let restored = ModuleNamingPlanner.normalizedModuleNaming(
            [module], localModuleDirectory: root.path
        )

        XCTAssertEqual(restored, [module])
        XCTAssertEqual(restored[0].publishedRelativePath, "Exports/My Module.sgmodule")
        XCTAssertEqual(restored[0].localStorageRelativePath, "Sources/My Module.sgmodule")
    }

    func testLocalSourcePathResolverUsesPhysicalRootAndSourceIdentity() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let root = base.appending(path: "Modules")
        let alias = base.appending(path: "Alias")
        let outside = base.appending(path: "Outside.sgmodule")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "My Module.sgmodule")
        try Data("[General]".utf8).write(to: source)
        try Data("[General]".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let sourceAlias = alias.appending(path: "My Module.sgmodule")

        XCTAssertTrue(ModuleSourceIdentity.matches(source.absoluteString, sourceAlias.absoluteString))
        XCTAssertEqual(LocalSourcePathResolver.relativePath(
            forSourceURL: source.absoluteString,
            rootDirectoryPath: alias.path
        ), "My Module.sgmodule")
        let stale = RelayModule(
            name: "Stale",
            sourceURL: outside.absoluteString,
            outputFileName: "My Module.sgmodule",
            storageLocation: .local,
            localStorageRelativePath: "My Module.sgmodule"
        )
        XCTAssertNil(LocalSourcePathResolver.storageRelativePath(for: stale, rootDirectoryPath: root.path))
        XCTAssertFalse(PublishCoordinator.shouldSkipStandaloneLocalExport(
            stale,
            isLocalExport: true,
            localModuleDirectory: root.path
        ))
        XCTAssertNil(LocalSourcePathResolver.fileURL(relativePath: "../Outside.sgmodule", rootDirectoryPath: root.path))
        XCTAssertNil(LocalSourcePathResolver.fileURL(relativePath: outside.path, rootDirectoryPath: root.path))
    }

    func testModuleArgumentPlannerStoresOverridesAndClearsDefaults() throws {
        var module = RelayModule(
            name: "Arguments",
            sourceURL: "https://example.com/arguments.sgmodule",
            outputFileName: "Arguments",
            argumentOverrides: ["Mode": "strict", "Region": "US"]
        )

        let update = try XCTUnwrap(ModuleArgumentPlanner.setOverride(
            module: module,
            key: "Mode",
            value: " relaxed ",
            defaultValue: "auto"
        ))
        XCTAssertEqual(update.overrides["Mode"], "relaxed")
        XCTAssertEqual(update.overrides["Region"], "US")
        XCTAssertEqual(update.statusMessage, "已更新 Arguments 的模块参数")

        module.argumentOverrides = update.overrides
        XCTAssertNil(ModuleArgumentPlanner.setOverride(
            module: module,
            key: "Mode",
            value: " relaxed ",
            defaultValue: "auto"
        ))

        let clearDefault = try XCTUnwrap(ModuleArgumentPlanner.setOverride(
            module: module,
            key: "Mode",
            value: " auto ",
            defaultValue: "auto"
        ))
        XCTAssertNil(clearDefault.overrides["Mode"])
        XCTAssertEqual(clearDefault.overrides["Region"], "US")

        module.argumentOverrides = clearDefault.overrides
        let reset = try XCTUnwrap(ModuleArgumentPlanner.resetOverrides(module: module))
        XCTAssertTrue(reset.overrides.isEmpty)
        XCTAssertEqual(reset.statusMessage, "已恢复 Arguments 的默认参数")

        module.argumentOverrides.removeAll()
        XCTAssertNil(ModuleArgumentPlanner.resetOverrides(module: module))
    }

    func testModuleSidebarSectionPlannerGroupsVisibleModules() {
        let failed = RelayModule(
            name: "Failed",
            sourceURL: "https://example.com/failed.sgmodule",
            outputFileName: "Failed",
            storageLocation: .local,
            state: .failed
        )
        let conflicted = RelayModule(
            name: "Conflicted",
            sourceURL: "https://example.com/conflicted.sgmodule",
            outputFileName: "Conflicted",
            storageLocation: .gitHub,
            hasOverrideConflict: true
        )
        let local = RelayModule(
            name: "Local",
            sourceURL: "https://example.com/local.sgmodule",
            outputFileName: "Local",
            storageLocation: .local
        )
        let github = RelayModule(
            name: "GitHub",
            sourceURL: "https://example.com/github.sgmodule",
            outputFileName: "GitHub",
            storageLocation: .gitHub
        )
        let remote = RelayModule(
            name: "Remote",
            sourceURL: "https://example.com/remote.sgmodule",
            outputFileName: "Remote",
            storageLocation: .gitHub
        )
        let invalid = RelayModule(
            name: "Invalid",
            sourceURL: "not a url",
            outputFileName: "Invalid",
            storageLocation: .gitHub
        )

        let sections = ModuleSidebarSectionPlanner.sections(for: [failed, conflicted, local, github, remote, invalid])

        XCTAssertEqual(sections.map(\.id), ["attention", "local", "github", "uncategorized"])
        XCTAssertEqual(sections.map(\.title), ["需要处理", "本地模块", "GitHub 模块", "未分类"])
        XCTAssertEqual(sections[0].modules.map(\.name), ["Failed", "Conflicted"])
        XCTAssertEqual(sections[1].modules.map(\.name), ["Local"])
        XCTAssertEqual(sections[2].modules.map(\.name), ["GitHub", "Remote"])
        XCTAssertEqual(sections[3].modules.map(\.name), ["Invalid"])
        XCTAssertTrue(ModuleSidebarSectionPlanner.sections(for: []).isEmpty)
    }

}

private final class BoundedRemoteDataFetcherURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (status: Int, headers: [String: String], chunks: [Data]) = (200, [:], [])
    nonisolated(unsafe) static var requestedTimeouts: [TimeInterval] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let responseValue = Self.response
        Self.requestedTimeouts.append(request.timeoutInterval)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: responseValue.status,
            httpVersion: "HTTP/1.1",
            headerFields: responseValue.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in responseValue.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension ModulePlanningTests {
    func testModuleNamingPlannerDuplicateNameIsUnique() {
        XCTAssertEqual(ModuleNamingPlanner.duplicateName(base: "Demo", existing: []), "Demo 副本")
        XCTAssertEqual(ModuleNamingPlanner.duplicateName(base: "Demo", existing: ["Demo 副本"]), "Demo 副本 2")
        XCTAssertEqual(
            ModuleNamingPlanner.duplicateName(base: "Demo", existing: ["Demo 副本", "Demo 副本 2", "Demo 副本 3"]),
            "Demo 副本 4"
        )
        XCTAssertEqual(
            ModuleNamingPlanner.duplicateName(base: "Demo", existing: ["Demo", "其他"]),
            "Demo 副本"
        )
    }
}
