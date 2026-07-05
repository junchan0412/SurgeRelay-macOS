import Foundation
import XCTest
@testable import SurgeRelay

final class ConfigurationMigrationTests: XCTestCase {
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
}
