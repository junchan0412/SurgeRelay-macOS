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

    func testModuleEditorSourceNameLookupSkipsNonRemoteSources() async {
        let localURL = URL(filePath: "/tmp/Local Module.sgmodule").absoluteString
        let name = await ModuleEditorSourceNameLookup.autofillName(from: localURL) { _ in
            XCTFail("Local file URLs should not be fetched for name lookup.")
            return Data()
        }

        XCTAssertNil(name)
        XCTAssertNil(ModuleEditorSourceNameLookup.remoteURL(from: "ftp://example.com/demo.sgmodule"))
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

        XCTAssertEqual(
            ModuleOutputPathInspector.notice(
                for: "Ads/New.sgmodule",
                publishesStandalone: false,
                modules: [existing],
                editingModuleID: nil,
                combinedFileName: "Surge Relay"
            ),
            ModuleOutputPathNotice(message: "未开启独立发布时，不会写出这个独立模块文件。", isWarning: false)
        )
        XCTAssertEqual(
            ModuleOutputPathInspector.notice(
                for: "Surge-Relay.sgmodule",
                publishesStandalone: true,
                modules: [existing],
                editingModuleID: nil,
                combinedFileName: "Surge Relay"
            ),
            ModuleOutputPathNotice(message: "该路径与总模块文件冲突，保存时会自动加编号避免覆盖。", isWarning: true)
        )
        XCTAssertEqual(
            ModuleOutputPathInspector.notice(
                for: "Ads/Existing.sgmodule",
                publishesStandalone: true,
                modules: [existing],
                editingModuleID: nil,
                combinedFileName: "Surge Relay"
            ),
            ModuleOutputPathNotice(message: "该路径已被“Existing”使用，保存时会自动加编号避免覆盖。", isWarning: true)
        )
        XCTAssertNil(ModuleOutputPathInspector.notice(
            for: "Ads/Existing.sgmodule",
            publishesStandalone: true,
            modules: [existing],
            editingModuleID: existingID,
            combinedFileName: "Surge Relay"
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
            outputFolder: "Ads",
            publishesStandalone: true
        )

        XCTAssertTrue(module.publishesStandalone)
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
            outputFolder: "Ads",
            publishesStandalone: true
        )
        XCTAssertFalse(PublishCoordinator.shouldSkipStandaloneLocalExport(
            copiedModule,
            isLocalExport: true,
            localModuleDirectory: root.path
        ))
    }

    func testLocalRemoteBackedModuleSkipsLocalSelfExport() {
        let module = RelayModule(
            name: "Remote Backed Local",
            sourceURL: "https://raw.githubusercontent.com/example/repo/main/qx.conf",
            sourceFormat: .quantumultX,
            outputFileName: "Remote Backed.sgmodule",
            outputFolder: "Converted",
            storageLocation: .local,
            localStorageRelativePath: "Converted/Remote Backed.sgmodule",
            preservesOutputFileName: true,
            publishesStandalone: true
        )

        XCTAssertEqual(module.storageLocation, .local)
        XCTAssertEqual(module.sourceOrigin, .remote(.quantumultX))
        XCTAssertEqual(module.publishedRelativePath, "Converted/Remote Backed.sgmodule")
        XCTAssertTrue(PublishCoordinator.shouldSkipStandaloneLocalExport(
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

    func testModuleNamingPlannerAvoidsCombinedAndExistingOutputPaths() {
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
                modules: [existing],
                combinedModuleFileName: "Surge Relay"
            ),
            "Existing-2.sgmodule"
        )

        draft.name = "Surge Relay"
        draft.outputFolder = ""
        XCTAssertEqual(
            ModuleNamingPlanner.uniqueOutputFileName(
                for: draft,
                source: draft.sourceURL,
                modules: [],
                combinedModuleFileName: "Surge Relay"
            ),
            "Surge-Relay-2.sgmodule"
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
            combinedFileName: "Surge Relay",
            localModuleDirectory: root.path
        )

        XCTAssertEqual(normalized[0].outputFolder, "Ads")
        XCTAssertEqual(normalized[0].outputFileName, "My Module.sgmodule")
        XCTAssertEqual(normalized[0].localStorageRelativePath, "Ads/My Module.sgmodule")
        XCTAssertTrue(normalized[0].preservesOutputFileName)
        XCTAssertEqual(normalized[1].outputFileName, "Surge-Relay-2.sgmodule")
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
            storageLocation: .gitHub,
            publishesStandalone: false
        )
        let invalid = RelayModule(
            name: "Invalid",
            sourceURL: "not a url",
            outputFileName: "Invalid",
            storageLocation: .gitHub
        )

        let sections = ModuleSidebarSectionPlanner.sections(for: [failed, conflicted, local, github, remote, invalid])

        XCTAssertEqual(sections.map(\.id), ["attention", "local", "remote", "github", "uncategorized"])
        XCTAssertEqual(sections.map(\.title), ["需要处理", "本地模块", "远程模块", "GitHub 模块", "未分类"])
        XCTAssertEqual(sections[0].modules.map(\.name), ["Failed", "Conflicted"])
        XCTAssertEqual(sections[1].modules.map(\.name), ["Local"])
        XCTAssertEqual(sections[2].modules.map(\.name), ["Remote"])
        XCTAssertEqual(sections[3].modules.map(\.name), ["GitHub"])
        XCTAssertEqual(sections[4].modules.map(\.name), ["Invalid"])
        XCTAssertTrue(ModuleSidebarSectionPlanner.sections(for: []).isEmpty)
    }

}
