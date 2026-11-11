import Foundation
import XCTest
@testable import SurgeRelay

final class LocalModuleScannerTests: XCTestCase {
    func testScanRecoversNativeFormatsAndClientVariantsFromOneSubscription() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalURL = "https://example.com/original.plugin"
        let variants: [(String, ModuleOutputFormat, String)] = [
            ("Demo.sgmodule", .surge, "[Rule]\nFINAL,DIRECT"),
            ("Demo.plugin", .loon, "[Rewrite]\n^https://example.com reject"),
            ("Demo.conf", .quantumultX, "^https://example.com url reject"),
            ("Demo.stoverride", .stash, "http:\n  mitm:\n    - example.com")
        ]
        for (name, format, body) in variants {
            let content = "#SUBSCRIBED http://script.hub/file/_start_/\(originalURL)/_end_/Demo.\(format.fileExtension)?type=loon-plugin&target=\(format.scriptHubTarget)\n\(body)\n"
            try Data(content.utf8).write(to: root.appending(path: name))
        }
        try Data("[Rule]\nFINAL,DIRECT\n".utf8).write(to: root.appending(path: "Native.module"))
        try Data("[Rewrite]\n^https://example.com reject\n".utf8).write(to: root.appending(path: "Native.lpx"))
        try Data("http:\n  mitm:\n    - example.com\n".utf8).write(to: root.appending(path: "Raw.stoverride"))
        let report = try LocalModuleScanner.report(in: root.path, existingModules: [], publishedFilePaths: [])
        XCTAssertEqual(report.candidates.count, 6)
        let candidates = Dictionary(uniqueKeysWithValues: report.candidates.map { ($0.relativePath, $0) })
        for (name, outputFormat, _) in variants {
            let candidate = try XCTUnwrap(candidates[name])
            XCTAssertEqual(candidate.outputFormat, outputFormat)
            XCTAssertEqual(candidate.sourceFormat, .loon)
            XCTAssertEqual(candidate.sourceURL, originalURL)
            XCTAssertEqual(candidate.outputFileName, name)
        }
        XCTAssertEqual(candidates["Native.module"]?.sourceFormat, .surge)
        XCTAssertEqual(candidates["Native.module"]?.outputFormat, .surge)
        XCTAssertEqual(candidates["Native.lpx"]?.sourceFormat, .loon)
        XCTAssertEqual(candidates["Native.lpx"]?.outputFormat, .loon)
        XCTAssertEqual(LocalModuleRootDiagnosticSnapshot.current(path: root.path).moduleFileCount, 7)
        XCTAssertEqual(report.skippedFiles.map(\.relativePath), ["Raw.stoverride"])
        let existing = RelayModule(name: "Registered Surge", sourceURL: originalURL, outputFileName: "Remote.sgmodule")
        let filtered = try LocalModuleScanner.report(in: root.path, existingModules: [existing], publishedFilePaths: [])
        XCTAssertFalse(filtered.candidates.contains { $0.relativePath == "Demo.sgmodule" })
        XCTAssertTrue(filtered.candidates.contains { $0.relativePath == "Demo.plugin" })
        XCTAssertTrue(filtered.candidates.contains { $0.relativePath == "Demo.conf" })
        XCTAssertTrue(filtered.candidates.contains { $0.relativePath == "Demo.stoverride" })
    }

    @MainActor
    func testImportBuildsAllNativeCachesFromPhysicalBytesWithoutChangingSources() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "Modules")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files: [(String, ModuleOutputFormat, String)] = [
            ("Surge.module", .surge, "[Rule]\nFINAL,DIRECT"),
            ("Loon.lpx", .loon, "[Rewrite]\n^https://example.com reject"),
            ("QX.conf", .quantumultX, "^https://example.com url reject"),
            ("Stash.stoverride", .stash, "#SUBSCRIBED http://script.hub/file/_start_/https://example.com/original.plugin/_end_/Stash.stoverride?type=loon-plugin&target=stash-stoverride\nhttp:\n  mitm:\n    - example.com")
        ]
        for (name, _, content) in files { try Data(content.utf8).write(to: directory.appending(path: name)) }
        let context = WorkspaceContext(id: UUID(), name: "Native imports", configurationDirectory: root.appending(path: "Config"),
            cacheDirectory: root.appending(path: "Cache"), allowsLegacyFallback: false)
        let model = AppModel(context: context, persistsOnInit: false)
        defer { model.persistenceFeedbackTask?.cancel() }
        model.settings.localModuleDirectory = directory.path
        for (_, format, _) in files {
            model.settings.setLocalStorage(ClientLocalStorage(isEnabled: true, directory: directory.path), for: format)
        }
        model.settings.publishToLocal = false
        model.settings.publishToGitHub = false
        model.settings.watchesLocalModuleChanges = false
        let candidates = try LocalModuleScanner.candidates(in: directory.path, existingModules: [], publishedFilePaths: [])
        await model.importLocalModules(candidates)
        XCTAssertNil(model.presentedError)
        XCTAssertEqual(model.modules.count, files.count)
        for (name, format, original) in files {
            let module = try XCTUnwrap(model.modules.first { $0.outputFileName == name })
            XCTAssertEqual(module.outputFormat, format)
            XCTAssertEqual(module.lastConvertedOutputFormat, format)
            XCTAssertEqual(module.publishedRelativePath, name)
            XCTAssertEqual(module.state, .current)
            XCTAssertNil(module.conversionEngineRevision)
            let cachedContent = try await model.fileStore.readComponent(id: module.id)
            let cached = try XCTUnwrap(cachedContent)
            XCTAssertTrue(cached.contains(format == .stash ? "http:" : format == .loon ? "[Rewrite]" : format == .surge ? "[Rule]" : " url reject"))
            XCTAssertEqual(try Data(contentsOf: directory.appending(path: name)), Data(original.utf8))
        }
        XCTAssertTrue(model.settings.localPublishedFilePaths.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.cacheDirectory.appending(path: "ScriptHubEngine").path))
    }

    func testMetadataReaderHandlesLoonAndQXPhysicalPathsAndRefreshesStashSubscription() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cases: [(String, ModuleOutputFormat)] = [("My Plugin.lpx", .loon), ("My Rewrite.conf", .quantumultX)]
        for (name, format) in cases {
            let content = "#SUBSCRIBED http://script.hub/file/_start_/https://example.com/original.plugin/_end_/Demo.\(format.fileExtension)?type=loon-plugin&target=\(format.scriptHubTarget)\n"
            try Data(content.utf8).write(to: root.appending(path: name))
            let expected = name.replacingOccurrences(of: " ", with: "-")
            let module = RelayModule(name: "Recovered", sourceURL: "https://example.com/original.plugin", outputFormat: format,
                outputFileName: expected, storageLocation: .local, localStorageRelativePath: expected)
            let snapshot = try XCTUnwrap(LocalModuleMetadataReader.snapshot(for: module, rootDirectoryPath: root.path))
            XCTAssertEqual(snapshot.localStorageRelativePath, name)
            XCTAssertEqual(snapshot.scriptHubSubscription?.originalURL, "https://example.com/original.plugin")
        }
        let stash = root.appending(path: "Demo.stoverride")
        try Data("#SUBSCRIBED http://script.hub/file/_start_/https://example.com/original.plugin/_end_/Demo.stoverride?type=loon-plugin&target=stash-stoverride\nhttp:\n".utf8).write(to: stash)
        let candidate = try XCTUnwrap(LocalModuleScanner.candidates(in: root.path, existingModules: [], publishedFilePaths: []).first { $0.outputFormat == .stash })
        try Data("http:\n".utf8).write(to: stash)
        XCTAssertThrowsError(try LocalModuleScanner.snapshotForImport(candidate, rootDirectoryPath: root.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("缺少可识别的 Script-Hub 订阅来源"))
        }
    }

    func testScanSkipsHistoricalAndCopiedPublishedOutputsWithoutManifest() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data("#!name=Original\n[Rule]\nFINAL,DIRECT\n".utf8)
        try original.write(to: root.appending(path: "Original.sgmodule"))
        let published = ManagedPublishedFile.dataWrapping(original, relativePath: "Old-Combined.sgmodule")
        try published.write(to: root.appending(path: "Old-Combined.sgmodule"))
        try published.write(to: root.appending(path: "Copied-Output.sgmodule"))
        try Data("# Surge Relay managed output\n[Rule]\n".utf8)
            .write(to: root.appending(path: "Damaged-Output.sgmodule"))

        let report = try LocalModuleScanner.report(in: root.path,
            existingModules: [], publishedFilePaths: [])

        XCTAssertEqual(report.candidates.map(\.relativePath), ["Original.sgmodule"])
        XCTAssertEqual(report.skippedFiles.count, 3)
        XCTAssertTrue(report.skippedFiles.allSatisfy { $0.reason == "这是 Surge Relay 发布文件" })
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "Original.sgmodule")), original)
    }

    func testImportRejectsFilePublishedAfterScan() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "Demo.sgmodule")
        let original = Data("#!name=Demo\n[Rule]\nFINAL,DIRECT\n".utf8)
        try original.write(to: source)
        let candidate = try XCTUnwrap(LocalModuleScanner.candidates(in: root.path, existingModules: [], publishedFilePaths: []).first)
        let published = ManagedPublishedFile.dataWrapping(original, relativePath: "Demo.sgmodule")
        try published.write(to: source)

        XCTAssertThrowsError(try LocalModuleScanner.snapshotForImport(candidate, rootDirectoryPath: root.path)) {
            XCTAssertTrue($0.localizedDescription.contains("Surge Relay 发布文件"))
        }
        XCTAssertEqual(try Data(contentsOf: source), published)
    }

    func testLocalModuleScannerDiscoversExistingModules() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: "Ads", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("""
        #!name=YouTube
        #!category=Video
        [General]
        """.utf8).write(to: root.appending(path: "Ads/YouTube Ads.sgmodule"))
        try Data("#!name=Combined\n[General]\n".utf8).write(to: root.appending(path: "Surge-Relay.sgmodule"))

        let candidates = try LocalModuleScanner.candidates(
            in: root.path,
            existingModules: [],
            publishedFilePaths: []
        )

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].relativePath, "Ads/YouTube Ads.sgmodule")
        XCTAssertEqual(candidates[0].id, "Ads/YouTube Ads.sgmodule")
        XCTAssertEqual(candidates[0].name, "YouTube")
        XCTAssertEqual(candidates[0].category, "Video")
        XCTAssertEqual(candidates[0].outputFolder, "Ads")
        XCTAssertEqual(candidates[0].outputFileName, "YouTube Ads.sgmodule")
    }

    func testLocalModuleScannerReportsSkippedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!name=Combined\n[General]\n".utf8).write(to: root.appending(path: "Surge-Relay.sgmodule"))
        try Data().write(to: root.appending(path: "Empty.sgmodule"))
        try Data("#!name=Managed\n[General]\n".utf8).write(to: root.appending(path: "Managed.sgmodule"))

        let report = try LocalModuleScanner.report(
            in: root.path,
            existingModules: [],
            publishedFilePaths: ["Managed.sgmodule"]
        )

        XCTAssertEqual(report.candidates.map(\.relativePath), ["Surge-Relay.sgmodule"])
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: report.skippedFiles.map { ($0.relativePath, $0.reason) }),
            [
                "Empty.sgmodule": "文件为空",
                "Managed.sgmodule": "发布路径已纳入管理"
            ]
        )
    }

    func testLocalModuleFolderScannerFindsNestedFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: "Ads/Video", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appending(path: "Tools", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(
            try LocalModuleFolderScanner.folders(in: root.path),
            ["Ads", "Ads/Video", "Tools"]
        )
    }

    func testLocalModuleFolderScannerExcludesInternalTreesAndKeepsDirectoryNamesWithExtensions() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = root.appending(path: "Surge Relay")
        let cache = root.appending(path: "Cache")
        let directories = [
            "Surge Relay/Backups/settings.json", "Surge Relay/Backups/modules.json",
            "Surge Relay/ModuleVersions/module/version", "Cache/Snapshots/module/Assets",
            "Surge Relay Modules", "Sgmodule (#0)", "User/settings.json", "User/modules.json",
            "User/Backups", "User/Cache", ".Hidden/Nested", "Bundle.app/Contents"
        ]
        for directory in directories {
            try FileManager.default.createDirectory(at: root.appending(path: directory), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: root.appending(path: "settings.json"))
        try Data("{}".utf8).write(to: root.appending(path: "modules.json"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Linked"), withDestinationURL: root.appending(path: "User"))

        let folders = try LocalModuleFolderScanner.folders(
            in: root.path,
            excluding: [configuration, cache],
            including: ["settings.json", "modules.json", "Linked", "Surge Relay/Backups/settings.json"]
        )

        XCTAssertEqual(Set(folders), Set([
            "Surge Relay Modules", "Sgmodule (#0)", "User", "User/settings.json", "User/modules.json",
            "User/Backups", "User/Cache"
        ]))
    }

    func testLocalModuleFolderScannerValidatesPlannedFoldersAndCanonicalExclusions() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appending(path: "Modules")
        let alias = base.appending(path: "Alias")
        let configuration = root.appending(path: "Configuration")
        try FileManager.default.createDirectory(at: configuration.appending(path: "Backups/modules.json"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "Tools"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appending(path: "settings.json"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "MissingLink"), withDestinationURL: base.appending(path: "Missing"))

        let folders = try LocalModuleFolderScanner.folders(
            in: alias.path,
            excluding: [alias.appending(path: "Configuration")],
            including: [
                "Future/Nested", "Tools/Next.json", "settings.json/Nested", "MissingLink/Nested",
                "Configuration/Future", ".Hidden/Future"
            ]
        )

        XCTAssertEqual(Set(folders), Set(["Tools", "Future/Nested", "Tools/Next.json"]))
        XCTAssertEqual(try LocalModuleFolderScanner.folders(in: root.path, excluding: [root]), [])
    }

    func testLocalModuleScannerDeduplicatesSubscriptionAndRepeatedScan() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let content = """
        #!name=Subscribed
        #SUBSCRIBED http://script.hub/file/_start_/https://example.com/original.sgmodule/_end_/Demo.sgmodule?type=surge-module&target=surge-module
        [General]
        """
        try Data(content.utf8).write(to: root.appending(path: "B.sgmodule"))
        try Data(content.utf8).write(to: root.appending(path: "A.sgmodule"))

        let report = try LocalModuleScanner.report(
            in: root.path,
            existingModules: [],
            publishedFilePaths: []
        )
        XCTAssertEqual(report.candidates.map(\.relativePath), ["A.sgmodule"])
        XCTAssertEqual(report.candidates.first?.sourceURL, "https://example.com/original.sgmodule")
        XCTAssertEqual(report.candidates.first?.rootDirectoryPath,
                       LocalSourcePathResolver.canonicalDirectoryURL(for: root.path)?.path)
        let plan = LocalModuleImportPlanner.plan(
            candidates: report.candidates,
            existingModules: []
        )
        let repeated = try LocalModuleScanner.report(
            in: root.path,
            existingModules: plan.entries.map(\.module),
            publishedFilePaths: []
        )
        XCTAssertTrue(repeated.candidates.isEmpty)
        XCTAssertEqual(repeated.skippedFiles.count, 2)
    }

    func testScanKeepsRegisteredGitHubModuleSourceReservedAfterSubscriptionAppears() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "Demo.sgmodule")
        let content = Data("""
        #!name=Demo
        #SUBSCRIBED http://script.hub/file/_start_/https://example.com/demo.conf/_end_/Demo.sgmodule?type=qx-rewrite&target=surge-module
        [General]
        """.utf8)
        try content.write(to: source)
        let registered = RelayModule(name: "Registered", sourceURL: source.absoluteString,
            outputFileName: "Published-Elsewhere.sgmodule", storageLocation: .gitHub)

        let report = try LocalModuleScanner.report(in: root.path,
            existingModules: [registered], publishedFilePaths: [])

        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertEqual(report.skippedFiles.map(\.relativePath), ["Demo.sgmodule"])
        XCTAssertEqual(try Data(contentsOf: source), content)
    }

    func testLocalModuleScannerResolvesRootAliasAndSkipsEscapingFile() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let root = base.appending(path: "Modules")
        let alias = base.appending(path: "Alias")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root.appending(path: "Tools"), withIntermediateDirectories: true)
        let source = root.appending(path: "Tools/My Module.sgmodule")
        try Data("#!name=Local\n[General]".utf8).write(to: source)
        let outside = base.appending(path: "Outside.sgmodule")
        try Data("#!name=Outside\n[General]".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Escape.sgmodule"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Duplicate.sgmodule"), withDestinationURL: source)

        let report = try LocalModuleScanner.report(
            in: alias.path,
            existingModules: [],
            publishedFilePaths: []
        )

        XCTAssertEqual(report.candidates.map(\.relativePath), ["Tools/My Module.sgmodule"])
        XCTAssertTrue(report.skippedFiles.contains { $0.reason == "无法解析相对路径" })
        XCTAssertTrue(report.skippedFiles.contains { $0.reason == "扫描中发现重复路径" })
        XCTAssertEqual(try LocalModuleFolderScanner.folders(in: alias.path), ["Tools"])
    }

    func testLocalMetadataReaderRecoversUniqueRenamedSiblingAndSubscription() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let root = base.appending(path: "Modules")
        let alias = base.appending(path: "Alias")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root.appending(path: "Tools"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let content = """
        #SUBSCRIBED http://script.hub/file/_start_/https://example.com/original.sgmodule/_end_/My-Module.sgmodule?type=surge-module&target=surge-module
        [General]
        """
        try Data(content.utf8).write(to: root.appending(path: "Tools/My Module.sgmodule"))
        let module = RelayModule(
            name: "Local",
            sourceURL: "https://example.com/original.sgmodule",
            outputFileName: "My-Module.sgmodule",
            storageTargets: [.local, .gitHub],
            localStorageRelativePath: "Tools/My-Module.sgmodule"
        )

        let snapshot = try XCTUnwrap(LocalModuleMetadataReader.snapshot(for: module, rootDirectoryPath: alias.path))
        XCTAssertEqual(snapshot.localStorageRelativePath, "Tools/My Module.sgmodule")
        XCTAssertEqual(snapshot.scriptHubSubscription?.originalURL, module.sourceURL)
        try Data(content.utf8).write(to: root.appending(path: "Tools/My  Module.sgmodule"))
        XCTAssertNil(LocalModuleMetadataReader.snapshot(for: module, rootDirectoryPath: alias.path))
    }

    func testLocalImportRejectsSourceSymlinkChangedAfterScan() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let root = base.appending(path: "Modules")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "Demo.sgmodule")
        try Data("#!name=Demo\n[General]".utf8).write(to: source)
        let candidates = try LocalModuleScanner.candidates(
            in: root.path, existingModules: [], publishedFilePaths: []
        )
        let outside = base.appending(path: "Outside.sgmodule")
        try Data("private content".utf8).write(to: outside)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)

        XCTAssertThrowsError(try LocalModuleScanner.snapshotForImport(candidates[0], rootDirectoryPath: root.path))

        let plan = LocalModuleImportPlanner.plan(
            candidates: candidates,
            existingModules: [],
            localModuleDirectory: root.path
        )

        XCTAssertTrue(plan.entries.isEmpty)
        XCTAssertEqual(plan.failures, ["Demo.sgmodule：本地来源路径已改变，请重新扫描"])
    }

    func testImportSnapshotRefreshesSubscriptionFromCurrentPhysicalContent() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "Demo.sgmodule")
        try Data("#!name=Demo\n[General]".utf8).write(to: source)
        let candidates = try LocalModuleScanner.candidates(
            in: root.path, existingModules: [], publishedFilePaths: []
        )
        let current = Data("""
        #!name=Demo
        #SUBSCRIBED http://script.hub/file/_start_/https://new.invalid/demo.plugin/_end_/Demo.sgmodule?type=loon-plugin&target=surge-module
        [Script]
        Local = type=http-request, pattern=^https://local.example
        """.utf8)
        try current.write(to: source)

        let snapshot = try LocalModuleScanner.snapshotForImport(candidates[0], rootDirectoryPath: root.path)

        XCTAssertEqual(snapshot.data, current)
        XCTAssertEqual(snapshot.candidate.sourceURL, "https://new.invalid/demo.plugin")
        XCTAssertEqual(snapshot.candidate.sourceFormat, .loon)
        XCTAssertNil(snapshot.candidate.sourceContentHash)
    }

    func testLocalModuleRootDiagnosticsReportsWritableDirectoryContents() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: "Ads/Video", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("#!name=Demo\n[General]\n".utf8).write(to: root.appending(path: "Ads/Video/Demo.sgmodule"))
        try Data("ignore".utf8).write(to: root.appending(path: "notes.txt"))

        let diagnostics = LocalModuleRootDiagnosticSnapshot.current(path: root.path)

        XCTAssertTrue(diagnostics.exists)
        XCTAssertTrue(diagnostics.isDirectory)
        XCTAssertTrue(diagnostics.isWritable)
        XCTAssertEqual(diagnostics.folderCount, 2)
        XCTAssertEqual(diagnostics.moduleFileCount, 1)
        XCTAssertEqual(diagnostics.status, "目录可用")
        XCTAssertNil(diagnostics.error)
    }
}
