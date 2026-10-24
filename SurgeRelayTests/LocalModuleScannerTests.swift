import Foundation
import XCTest
@testable import SurgeRelay

final class LocalModuleScannerTests: XCTestCase {
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
