import Foundation
import XCTest
@testable import SurgeRelay

final class LocalFileStoreTests: XCTestCase {
    func testConfigurationMigrationCopiesOverridesWithoutRemovingDestinationFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Source", directoryHint: .isDirectory)
        let destination = root.appending(path: "Destination", directoryHint: .isDirectory)
        let sourceOverride = source.appending(path: "Overrides/nested/module.cache")
        let existingOverride = destination.appending(path: "Overrides/keep.cache")
        try FileManager.default.createDirectory(
            at: sourceOverride.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: existingOverride.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("edited module".utf8).write(to: sourceOverride)
        try Data("keep me".utf8).write(to: existingOverride)

        try PersistenceStore.migrateOverrides(from: source, to: destination)

        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Overrides/nested/module.cache"), encoding: .utf8),
            "edited module"
        )
        XCTAssertEqual(try String(contentsOf: existingOverride, encoding: .utf8), "keep me")
    }

    func testConfigurationMigrationCopiesRegistryHistoryBackupsAndOverrides() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Source", directoryHint: .isDirectory)
        let destination = root.appending(path: "Destination", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(
            at: source.appending(path: "Backups/modules.json", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: source.appending(path: "Overrides/nested", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination.appending(path: "Backups/settings.json", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination.appending(path: "Overrides", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        try Data("[{\"name\":\"source\"}]".utf8).write(to: source.appending(path: "modules.json"))
        try Data("{\"storageMode\":\"local\"}".utf8).write(to: source.appending(path: "settings.json"))
        try Data("{\"revision\":\"abc\"}".utf8).write(to: source.appending(path: "script-hub-state.json"))
        try Data("[{\"message\":\"history\"}]".utf8).write(to: source.appending(path: "update-history.json"))
        try Data("root backup".utf8).write(to: source.appending(path: "Backups/modules.json/root.backup"))
        try Data("override".utf8).write(to: source.appending(path: "Overrides/nested/module.cache"))
        try Data("old modules".utf8).write(to: destination.appending(path: "modules.json"))
        try Data("keep backup".utf8).write(to: destination.appending(path: "Backups/settings.json/keep.backup"))
        try Data("keep override".utf8).write(to: destination.appending(path: "Overrides/keep.cache"))

        try PersistenceStore.migrateConfigurationFiles(from: source, to: destination)

        XCTAssertEqual(try String(contentsOf: destination.appending(path: "modules.json"), encoding: .utf8), "[{\"name\":\"source\"}]")
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "settings.json"), encoding: .utf8), "{\"storageMode\":\"local\"}")
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "script-hub-state.json"), encoding: .utf8), "{\"revision\":\"abc\"}")
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "update-history.json"), encoding: .utf8), "[{\"message\":\"history\"}]")
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Backups/modules.json/root.backup"), encoding: .utf8),
            "root backup"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Backups/settings.json/keep.backup"), encoding: .utf8),
            "keep backup"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Overrides/nested/module.cache"), encoding: .utf8),
            "override"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Overrides/keep.cache"), encoding: .utf8),
            "keep override"
        )
        let overwrittenBackups = try FileManager.default.subpathsOfDirectory(
            atPath: destination.appending(path: "Backups/configuration-migration/modules.json").path
        )
        XCTAssertEqual(overwrittenBackups.count, 1)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appending(path: "Backups/configuration-migration/modules.json/\(overwrittenBackups[0])"),
                encoding: .utf8
            ),
            "old modules"
        )
    }

    func testConfigurationMigrationCleanupRemovesOnlySurgeRelayConfigurationFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Source", directoryHint: .isDirectory)
        let destination = source.appending(path: "Surge Relay", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: source.appending(path: "Backups/modules.json", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: source.appending(path: "Sgmodule", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("modules".utf8).write(to: source.appending(path: "modules.json"))
        try Data("settings".utf8).write(to: source.appending(path: "settings.json"))
        try Data("history".utf8).write(to: source.appending(path: "update-history.json"))
        try Data("state".utf8).write(to: source.appending(path: "script-hub-state.json"))
        try Data("backup".utf8).write(to: source.appending(path: "Backups/modules.json/root.backup"))
        try Data("module".utf8).write(to: source.appending(path: "Sgmodule/Original.sgmodule"))
        try Data("surge".utf8).write(to: source.appending(path: "Surge.conf"))

        try PersistenceStore.migrateConfigurationFiles(from: source, to: destination)
        try PersistenceStore.removeMigratedConfigurationFiles(from: source, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "modules.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "settings.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "script-hub-state.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "update-history.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: "Backups").path))
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "modules.json"), encoding: .utf8), "modules")
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Backups/modules.json/root.backup"), encoding: .utf8),
            "backup"
        )
        XCTAssertEqual(try String(contentsOf: source.appending(path: "Sgmodule/Original.sgmodule"), encoding: .utf8), "module")
        XCTAssertEqual(try String(contentsOf: source.appending(path: "Surge.conf"), encoding: .utf8), "surge")
    }

    func testLocalPublishedExportRemovesManifestStaleFilesOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore()
        _ = try await store.exportPublishedFiles([
            PublishFile(name: "Old.sgmodule", data: Data("old".utf8)),
            PublishFile(name: "Folder/Current.sgmodule", data: Data("current".utf8))
        ], toRootDirectory: root.path)
        try Data("manual".utf8).write(to: root.appending(path: "Manual.sgmodule"))

        let removed = try await store.exportPublishedFiles(
            [PublishFile(name: "New.sgmodule", data: Data("new".utf8))],
            toRootDirectory: root.path,
            removingObsoleteRelativePaths: ["Old.sgmodule", "Folder/Current.sgmodule"]
        )

        XCTAssertEqual(Set(removed), ["Old.sgmodule", "Folder/Current.sgmodule"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Old.sgmodule").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Folder").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "New.sgmodule").path))
        XCTAssertTrue(
            try String(contentsOf: root.appending(path: "New.sgmodule"), encoding: .utf8)
                .contains("# Surge Relay managed output")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "Manual.sgmodule").path))
    }

    func testLocalPublishedExportRefusesUnmanagedSameNameFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = root.appending(path: "Personal.sgmodule")
        try Data("#!name=Personal\n[Rule]\nFINAL,DIRECT\n".utf8).write(to: existing)

        let store = ModuleFileStore()
        do {
            _ = try await store.exportPublishedFiles(
                [PublishFile(name: "Personal.sgmodule", data: Data("#!name=Relay\n[Rule]\nFINAL,REJECT\n".utf8))],
                toRootDirectory: root.path
            )
            XCTFail("不应覆盖未被 Surge Relay 管理的同名文件")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("不属于 Surge Relay 管理"))
        }

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "#!name=Personal\n[Rule]\nFINAL,DIRECT\n")
    }

    func testLocalPublishedExportMigratesKnownLegacyManagedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appending(path: "Legacy.sgmodule")
        try Data("#!name=Legacy\n[Rule]\nFINAL,DIRECT\n".utf8).write(to: destination)

        let store = ModuleFileStore()
        _ = try await store.exportPublishedFiles(
            [PublishFile(name: "Legacy.sgmodule", data: Data("#!name=Legacy\n[Rule]\nFINAL,REJECT\n".utf8))],
            toRootDirectory: root.path,
            knownManagedRelativePaths: ["Legacy.sgmodule"]
        )

        let written = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(written.contains("# Surge Relay managed output"))
        XCTAssertTrue(written.contains("FINAL,REJECT"))
    }

    func testLocalPublishedExportPreservesSurgeMetadataHeader() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = ModuleFileStore()
        _ = try await store.exportPublishedFiles(
            [
                PublishFile(
                    name: "Header.sgmodule",
                    data: Data("""
                    #!name=Header
                    #!category=Ads
                    [Rule]
                    FINAL,REJECT

                    """.utf8)
                )
            ],
            toRootDirectory: root.path
        )

        let written = try String(contentsOf: root.appending(path: "Header.sgmodule"), encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("""
        #!name=Header
        #!category=Ads
        # Surge Relay managed output
        # surge-relay-relative-path: Header.sgmodule

        """))
    }

    func testLocalPublishedCleanupRefusesUnmanagedStaleFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stale = root.appending(path: "Manual.sgmodule")
        try Data("#!name=Manual\n[Rule]\nFINAL,DIRECT\n".utf8).write(to: stale)

        let store = ModuleFileStore()
        do {
            _ = try await store.exportPublishedFiles(
                [],
                toRootDirectory: root.path,
                removingObsoleteRelativePaths: ["Manual.sgmodule"]
            )
            XCTFail("不应自动清理未被 Surge Relay 管理的旧文件")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("不属于 Surge Relay 管理"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
    }

    func testLegacyPublishedCleanupRemovesOnlyExplicitPaths() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModuleFileStore()
        try FileManager.default.createDirectory(
            at: root.appending(path: "assets/custom", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("combined".utf8).write(to: root.appending(path: "Surge-Relay.sgmodule"))
        try Data("manual".utf8).write(to: root.appending(path: "Manual.sgmodule"))
        try Data("asset".utf8).write(to: root.appending(path: "assets/custom/file.js"))

        let removed = try await store.removeLegacyPublishedFiles(
            in: root.path,
            relativePaths: ["Surge-Relay.sgmodule"]
        )

        XCTAssertEqual(removed, ["Surge-Relay.sgmodule"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Surge-Relay.sgmodule").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "Manual.sgmodule").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "assets/custom/file.js").path))
    }

    func testLegacyOutputCleanupDirectoriesSkipActiveLocalModuleRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let localRoot = root.appending(path: "SurgeRoot", directoryHint: .isDirectory)
        let configuration = localRoot.appending(path: "Surge Relay", directoryHint: .isDirectory)

        let directories = AppModel.legacyOutputCleanupDirectories(
            outputDirectory: localRoot.path,
            configurationDirectory: configuration.path,
            localModuleDirectory: localRoot.path
        )

        XCTAssertEqual(directories, [configuration.standardizedFileURL.path])
    }

    func testGeneratedAssetFilesCanBeFilteredByModuleID() async throws {
        let includedID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let excludedID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let store = ModuleFileStore()
        defer {
            Task {
                try? await store.removeAssets(id: includedID)
                try? await store.removeAssets(id: excludedID)
            }
        }

        try await store.replaceAssets([
            GeneratedAsset(
                relativePath: "assets/\(includedID.uuidString.lowercased())/keep.js",
                data: Data("keep".utf8)
            )
        ], id: includedID)
        try await store.replaceAssets([
            GeneratedAsset(
                relativePath: "assets/\(excludedID.uuidString.lowercased())/drop.js",
                data: Data("drop".utf8)
            )
        ], id: excludedID)

        let files = try await store.generatedAssetFiles(for: [includedID])

        XCTAssertEqual(files.map(\.name), ["assets/\(includedID.uuidString.lowercased())/keep.js"])
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
            combinedFileName: "Surge Relay",
            existingModules: [],
            publishedFilePaths: []
        )

        XCTAssertEqual(candidates.count, 1)
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
            combinedFileName: "Surge Relay",
            existingModules: [],
            publishedFilePaths: ["Managed.sgmodule"]
        )

        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: report.skippedFiles.map { ($0.relativePath, $0.reason) }),
            [
                "Empty.sgmodule": "文件为空",
                "Managed.sgmodule": "发布路径已纳入管理",
                "Surge-Relay.sgmodule": "这是当前总模块文件"
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
